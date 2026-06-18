import Foundation
import StormbreakerKit
#if canImport(Darwin)
import Darwin
#endif

// ─────────────────────────────────────────────────────────────────────────────
// The TUI event loop (Part 3, phases 5–6). One @MainActor owner of all UI state,
// consuming a single merged stream of input + resize + tick + agent + permission
// events. Widgets are pure (state, Rect) → draws into a ScreenBuffer; one render
// pass per event, throttled to ~60fps. Phase 6 attaches the real AgentLoop and a
// non-blocking permission modal.
// ─────────────────────────────────────────────────────────────────────────────

enum AppEvent: Sendable {
    case key(Key)
    case resize(Size)
    case tick
    case agent(AgentEvent)
    case permission(PermissionRequest, CheckedContinuation<PermissionDecision, Never>)
    case turnSnapshot(String)
    case diffLoaded(String)
    case modelsLoaded([ModelConfig])
    case restored(Int, Bool)
    case reviewLoaded(ReviewReport)
    case gitStatusLoaded(GitStatus)
    case gitOpDone(GitService.OpResult, GitStatus)
    case turnEnded
}

/// One build task on the kø (queue). Stormbreaker drains the kø one task at a time —
/// sequential by design, since parallel builds in a single project dir would
/// fight over the same files (the safe "swarm-lite" for a beginner audience).
struct QueueItem: Identifiable {
    let id: Int
    let prompt: String
    var state: QState
}
enum QState { case queued, building, review, done, failed }

/// Read the current terminal size (Sendable free function — safe from the SIGWINCH
/// handler on any queue).
func currentTerminalSize() -> Size {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_row > 0, ws.ws_col > 0 {
        return Size(cols: Int(ws.ws_col), rows: Int(ws.ws_row))
    }
    return Size(cols: 80, rows: 24)
}

/// Suspends the agent loop until the user answers the modal — without blocking the
/// render loop. Sendable: it holds only the (Sendable) channel continuation.
struct TUIPermissionGate: PermissionGate {
    let channel: AsyncStream<AppEvent>.Continuation
    func decide(_ request: PermissionRequest) async -> PermissionDecision {
        await withCheckedContinuation { (cont: CheckedContinuation<PermissionDecision, Never>) in
            channel.yield(.permission(request, cont))
        }
    }
}

@MainActor
final class TUIApp {
    struct Line { enum Role { case user, assistant, system, error, warn }; var role: Role; var text: String }

    // Palette — sourced from the active theme (P7).
    private var theme: ANSITheme
    private var accent: Style { theme.accentStyle }
    private var accentBold: Style { theme.accentBold }
    private var dimStyle: Style { theme.dimStyle }
    private var errStyle: Style { theme.errorStyle }
    private var okStyle: Style { theme.okStyle }
    private var warnStyle: Style { theme.warnStyle }

    private var engine: Engine                 // var: /model reassigns engine.config
    private var modelName: String
    private let framework: String
    private let verbose: Bool
    private let skills: [Skill]                 // available presets (Kontekst sidebar)
    private var size: Size
    private var prev: ScreenBuffer?

    private var transcript: [Line] = []
    private var history: [ChatMessage] = []
    private var input = ""
    private var cursor = 0
    private var scroll = 0
    private var status = "Klar."
    private var statusIsQuote = false           // status is a rotating fun quote (vs a literal label)
    private var liveFile: String?              // file currently streaming (side pane)
    private var liveBuffer = ""                // its contents so far
    enum SidePane { case context, live, diff }
    private var sidePane: SidePane = .context  // Tab cycles context → live → diff; auto-→live while streaming
    private var diffText = ""                   // loaded by /diff
    private var isBusy = false
    private var pendingUser: String?
    private var currentAssistant: String?
    private var assistantLineIndex: Int?
    // Session metrics (verbose) — surfaced in the Kontekst sidebar.
    private var mCalls = 0, mPrompt = 0, mCompletion = 0
    private var mSeconds = 0.0
    private var mLastTTFT: Double?
    private var mCostUSD = 0.0
    private var sessionTokens: Int { mPrompt + mCompletion }
    private var tokPerSec: Double { mSeconds > 0 ? Double(mCompletion) / mSeconds : 0 }
    private var changedFiles: [String] = []     // files written this session
    private var spinnerFrame = 0
    private var lastSHA: String?               // most recent pre-turn snapshot (for /diff)
    private var sessionTurns: [SessionFile.Turn] = []   // completed turns (user+assistant pairs), persisted
    private var modelChoices: [ModelConfig]?   // non-nil while the /model picker is open
    private var onboarding = false             // first-run wizard: model → theme
    private var onboardThemeIdx = 0
    // First-run model picker (P): show detected local models + cloud providers.
    private enum OnboardStep { case model, cloud, theme }
    private var onboardStep: OnboardStep = .model
    private var onboardSel = 0                  // row in the combined model list
    private let discovered: [ModelConfig]       // local models found before launch
    private var cloudIdx = 0                    // chosen provider in cloudProviders
    private var cloudField = 0                  // 0 = model-id field, 1 = API-key field
    private var cloudModelText = ""
    private var cloudKeyText = ""
    private var chosenProvider: String?         // persisted to config on finish
    private var chosenAPIKey: String?
    private struct CloudProvider { let id: String; let label: String; let model: String }
    private static let cloudProviders: [CloudProvider] = [
        .init(id: "openai",     label: "OpenAI",          model: "gpt-4o"),
        .init(id: "anthropic",  label: "Anthropic (Claude)", model: "claude-sonnet-4-6"),
        .init(id: "gemini",     label: "Google Gemini",   model: "gemini-2.0-flash"),
        .init(id: "openrouter", label: "OpenRouter",      model: ""),
        .init(id: "nvidia",     label: "NVIDIA NIM",      model: ""),
    ]
    private let autoReview: Bool               // run a reviewer pass after each build
    private var reviewing = false
    private var lastRequest: String?           // the just-finished turn's prompt (for /review)
    private var lastReview: ReviewReport?      // last reviewer result (Kontekst sidebar)
    private var git: GitStatus = .none         // the project's REAL .git state (GIT sidebar section)
    private var gitChecked = false             // first status probe has completed
    private var gitBusy = false                // a git/gh operation is in flight
    private var queue: [QueueItem] = []        // the build kø (KØ sidebar section)
    private var queueSeq = 0                   // monotonic id source
    private var currentQueueID: Int?           // the kø item currently building (nil = a plain turn)
    private var todos: [TodoItem] = []         // the agent's live plan checklist (PLAN sidebar section)
    private var sawExplicitTodos = false       // a <forgeAction type="todo"> wins over prose detection
    private var pendingPermission: (PermissionRequest, CheckedContinuation<PermissionDecision, Never>)?
    private var turnTask: Task<Void, Never>?
    private var running = true
    private var needsRender = true
    private var lastRender = DispatchTime.now()
    private var channel: AsyncStream<AppEvent>.Continuation?
    private var winch: DispatchSourceSignal?

    private static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    init(size: Size, engine: Engine, modelName: String, framework: String, verbose: Bool,
         theme: ANSITheme = .midnight, resume: SessionFile? = nil, firstRun: Bool = false, autoReview: Bool = true,
         discovered: [ModelConfig] = []) {
        self.size = size
        self.engine = engine
        self.discovered = discovered
        self.modelName = modelName
        self.framework = framework
        self.verbose = verbose
        self.theme = theme
        self.autoReview = autoReview
        self.skills = SkillStore.load(projectRoot: engine.workspace.root)
        if firstRun {
            onboarding = true
            onboardStep = .model                 // pick a model first, then theme
            onboardThemeIdx = ANSITheme.all.firstIndex { $0.name == theme.name } ?? 0
        }
        if let resume {
            sessionTurns = resume.turns
            history = resume.chatHistory()
            lastSHA = resume.turns.last(where: { $0.role == "user" })?.checkpointSHA
            for t in resume.turns {
                transcript.append(Line(role: t.role == "user" ? .user : .assistant, text: t.content))
            }
            let n = resume.turns.filter { $0.role == "user" }.count
            transcript.append(Line(role: .system, text: "↺ genoptog \(n) tidligere tur(e) — byg videre eller /restore."))
        } else {
            transcript.append(Line(role: .system,
                text: "Stormbreaker — beskriv hvad du vil bygge og tryk Enter. Ctrl-C afbryder/afslutter."))
        }
    }

    func run() async {
        let (stream, cont) = AsyncStream.makeStream(of: AppEvent.self, bufferingPolicy: .bufferingNewest(512))
        channel = cont
        let keyTask = Task { for await k in StdinReader().keys() { cont.yield(.key(k)) } }
        let tickTask = Task {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)); cont.yield(.tick) }
        }
        signal(SIGWINCH, SIG_IGN)
        let ws = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        // The handler MUST be @Sendable so it does NOT inherit run()'s @MainActor
        // isolation: DispatchSource calls it on a background queue, and a main-actor
        // closure would hit a `dispatch_assert_queue` executor check and crash on the
        // first resize (Swift 6). Yielding to the (Sendable) continuation is safe off-main.
        let onResize: @Sendable () -> Void = { cont.yield(.resize(currentTerminalSize())) }
        ws.setEventHandler(handler: onResize)
        ws.resume()
        winch = ws
        defer {
            turnTask?.cancel()
            if let (_, c) = pendingPermission { pendingPermission = nil; c.resume(returning: .deny) }
            keyTask.cancel(); tickTask.cancel(); ws.cancel(); cont.finish()
        }

        render(force: true)
        refreshGit()                         // probe the project's git state once up front
        for await ev in stream {
            switch ev {
            case .key(let k):           handle(k)
            case .resize(let s):        size = s; prev = nil; needsRender = true
            case .tick:
                if isBusy || reviewing {
                    spinnerFrame += 1
                    // Rotate the fun quote only ~once a minute on long turns (the
                    // spinner already shows it's alive — no need to flash).
                    if isBusy, statusIsQuote, spinnerFrame > 0, spinnerFrame % 600 == 0 { status = StormQuotes.working.randomElement() ?? status }
                    needsRender = true
                }
            case .agent(let e):         applyAgent(e)
            case .permission(let r, let c): pendingPermission = (r, c); status = "Tilladelse kræves"; needsRender = true
            case .turnSnapshot(let sha): lastSHA = sha
            case .diffLoaded(let d):    diffText = d; sidePane = .diff; status = "Diff"; needsRender = true
            case .modelsLoaded(let ms): modelChoices = Array(ms.prefix(9)); status = "Vælg model (1–\(min(ms.count, 9))) · Esc"; needsRender = true
            case .restored(let n, let ok): applyRestore(n, ok)
            case .reviewLoaded(let r):  applyReview(r)
            case .gitStatusLoaded(let s): git = s; gitChecked = true; needsRender = true
            case .gitOpDone(let r, let s): applyGitOp(r, s)
            case .turnEnded:            endTurn()
            }
            if !running { break }
            if needsRender { render() }
        }
    }

    // MARK: - Input

    private func handle(_ key: Key) {
        if onboarding { handleOnboardingKey(key); return }
        if pendingPermission != nil { handlePermissionKey(key); return }
        if modelChoices != nil { handleModelKey(key); return }
        switch key {
        case .ctrl("c"):
            if isBusy { cancelTurn() } else { running = false }
        case .escape:
            if isBusy { cancelTurn() } else if !input.isEmpty { input = ""; cursor = 0; needsRender = true }
        case .char(let c):
            input.insert(c, at: input.index(input.startIndex, offsetBy: cursor)); cursor += 1; needsRender = true
        case .backspace:
            if cursor > 0 { input.remove(at: input.index(input.startIndex, offsetBy: cursor - 1)); cursor -= 1; needsRender = true }
        case .delete:
            if cursor < input.count { input.remove(at: input.index(input.startIndex, offsetBy: cursor)); needsRender = true }
        case .left:  if cursor > 0 { cursor -= 1; needsRender = true }
        case .right: if cursor < input.count { cursor += 1; needsRender = true }
        case .home:  cursor = 0; needsRender = true
        case .end:   cursor = input.count; needsRender = true
        case .up:    scroll += 1; needsRender = true
        case .down:  scroll = max(0, scroll - 1); needsRender = true
        case .pageUp:   scroll += max(1, size.rows - 4); needsRender = true
        case .pageDown: scroll = max(0, scroll - max(1, size.rows - 4)); needsRender = true
        case .tab:
            if input.hasPrefix("/") {                 // complete to the first matching command
                if let m = Self.slashCommands.first(where: { $0.0.hasPrefix(input.lowercased()) }) { input = m.0 + " "; cursor = input.count }
            } else {
                sidePane = (sidePane == .context) ? .live : (sidePane == .live ? .diff : .context)
            }
            needsRender = true
        case .enter:
            let line = input.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("/") {                  // slash commands work even mid-turn (read-only)
                input = ""; cursor = 0; handleCommand(line); needsRender = true
            } else if !isBusy {
                submit()
            }
        default: break
        }
    }

    private func handlePermissionKey(_ key: Key) {
        guard let (_, cont) = pendingPermission else { return }
        let decision: PermissionDecision?
        switch key {
        case .char("j"), .char("J"), .enter:  decision = .allow
        case .char("a"), .char("A"):          decision = .allowForSession
        case .char("n"), .char("N"), .escape: decision = .deny
        default:                              decision = nil
        }
        if let d = decision {
            pendingPermission = nil
            cont.resume(returning: d)
            status = d == .deny ? "Afvist — fortsætter uden." : "Tilladt."
            needsRender = true
        }
    }

    // MARK: - Turn lifecycle

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        input = ""; cursor = 0
        startTurn(text)
    }

    /// Run one build turn for `text` (used by submit + the reviewer's /fix).
    private func startTurn(_ text: String) {
        guard !isBusy, let cont = channel else { return }
        scroll = 0
        transcript.append(Line(role: .user, text: text))
        pendingUser = text
        liveFile = nil; liveBuffer = ""; todos = []; sawExplicitTodos = false   // fresh checklist per turn
        isBusy = true; status = StormQuotes.working.randomElement() ?? "Tænker…"; statusIsQuote = true; spinnerFrame = 0
        let engine = self.engine
        turnTask = Task {
            // Snapshot the pre-turn state first, so /diff + /undo (P9/P11) can compare.
            if let sha = await engine.checkpoints.snapshot(label: text) { cont.yield(.turnSnapshot(sha)) }
            // Auto-compact a long history so a small local context window doesn't overflow.
            await self.compactHistoryIfNeeded()
            // Fetch any URLs in the prompt so the model reads REAL content instead of
            // guessing from the URL's words. The model sees the augmented prompt; the
            // transcript keeps showing the user's original line.
            let prompt = await self.augmentWithURLs(text)
            let gate = TUIPermissionGate(channel: cont)
            let loop = AgentLoop(makeDeps(engine, mode: .build, gate: gate))
            for await ev in loop.run(userPrompt: prompt, history: self.history, mode: .build) { cont.yield(.agent(ev)) }
            cont.yield(.turnEnded)
        }
        needsRender = true
    }

    /// Fetch any URLs in the prompt and fold their real content into the prompt the
    /// MODEL sees (the transcript still shows the user's original line). On a fetch
    /// failure the model is told to admit it — so it can't fabricate repo contents.
    private func augmentWithURLs(_ text: String) async -> String {
        let urls = WebContent.extractURLs(text)
        guard !urls.isEmpty else { return text }
        var blocks: [String] = []
        var failed: [String] = []
        for u in urls.prefix(3) {
            transcript.append(Line(role: .system, text: "📄 henter \(u)…")); needsRender = true
            if let content = await WebContent.fetch(u) {
                blocks.append("KILDE — \(u):\n\(content)")
            } else {
                failed.append(u)
                transcript.append(Line(role: .system, text: "  ⚠ kunne ikke hente \(u)")); needsRender = true
            }
        }
        var prompt = text
        if !blocks.isEmpty {
            prompt += "\n\n--- HENTET WEB-INDHOLD (svar KUN ud fra dette — find ikke på) ---\n"
                + blocks.joined(separator: "\n\n")
        }
        if !failed.isEmpty {
            prompt += "\n\n(Kunne IKKE hente: \(failed.joined(separator: ", ")). Sig ærligt at du ikke kunne læse dem — gæt ikke indholdet.)"
        }
        return prompt
    }

    /// Auto-compaction: if the chat history has grown past the budget, summarize the
    /// older turns so a small local context window doesn't overflow. Runs inside the
    /// turn task, before the model call.
    private func compactHistoryIfNeeded() async {
        let compactor = ConversationCompactor()
        guard compactor.needsCompaction(history) else { return }
        await runCompaction(compactor)
    }

    /// `/compact`: summarize the conversation now, on demand.
    private func compactNow() {
        guard !isBusy else {
            transcript.append(Line(role: .system, text: "vent til build er færdigt")); needsRender = true; return
        }
        guard history.count > 2 else {
            transcript.append(Line(role: .system, text: "ingen historik at komprimere endnu")); needsRender = true; return
        }
        isBusy = true; status = "Komprimerer…"; statusIsQuote = false; spinnerFrame = 0; needsRender = true
        turnTask = Task {
            await runCompaction(ConversationCompactor(maxTokens: 0))   // force, even if under the auto threshold
            isBusy = false; status = "✓ Klar."
            needsRender = true
        }
    }

    /// Shared compaction body: shows progress, summarizes the old turns via the model,
    /// and swaps in the compacted history.
    private func runCompaction(_ compactor: ConversationCompactor) async {
        let before = history.count
        transcript.append(Line(role: .system, text: "🗜 komprimerer samtalehistorik…")); needsRender = true
        let engine = self.engine
        let compacted = await compactor.compact(history) { convo in
            await Self.summarizeConversation(convo, engine: engine)
        }
        if compacted.count < before {
            history = compacted
            transcript.append(Line(role: .system, text: "✓ historik komprimeret (\(before) → \(compacted.count) beskeder)"))
        } else {
            transcript.append(Line(role: .system, text: "  (intet at komprimere)"))
        }
        needsRender = true
    }

    /// One-shot model call that summarizes a conversation transcript (reasoning stripped).
    /// nonisolated so it runs off the main actor — keeps the UI responsive during the call.
    nonisolated private static func summarizeConversation(_ convo: String, engine: Engine) async -> String? {
        let provider = ModelRouter.provider(for: engine.config)
        let messages = [
            ChatMessage(role: .system, content: SystemPrompt.compactSummary),
            ChatMessage(role: .user, content: convo),
        ]
        let splitter = ReasoningSplitter()
        var out = ""
        do {
            for try await ev in provider.stream(messages: messages, options: ModelRouter.options(for: engine.config)) {
                if case .token(let t) = ev {
                    for piece in splitter.consume(t) { if case .text(let x) = piece { out += x } }
                }
            }
        } catch { return nil }
        for piece in splitter.finish() { if case .text(let x) = piece { out += x } }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func cancelTurn() {
        turnTask?.cancel(); turnTask = nil
        if let (_, c) = pendingPermission { pendingPermission = nil; c.resume(returning: .deny) }
        isBusy = false; status = "Afbrudt."; statusIsQuote = false
        pendingUser = nil; currentAssistant = nil; assistantLineIndex = nil
        // A deliberate stop pauses the kø: mark the current task failed and DON'T
        // auto-drain — the rest stay queued, resumable with /kø.
        if currentQueueID != nil { setQueueState(currentQueueID, .failed); currentQueueID = nil }
        needsRender = true
    }

    private func endTurn() {
        if let user = pendingUser {
            let a = currentAssistant ?? ""
            history.append(ChatMessage(role: .user, content: user))
            history.append(ChatMessage(role: .assistant, content: a))
            sessionTurns.append(SessionFile.Turn(role: "user", content: user, checkpointSHA: lastSHA))
            sessionTurns.append(SessionFile.Turn(role: "assistant", content: a, checkpointSHA: nil))
            saveSession()
        }
        let req = pendingUser
        if let req { lastRequest = req }                 // so /review works even with auto-review off
        pendingUser = nil; currentAssistant = nil; assistantLineIndex = nil
        isBusy = false
        if sidePane == .live { sidePane = .context }     // back to context after the build
        turnTask = nil
        let failed = status.hasPrefix("✗")
        if failed {
            // Pause the kø on a failure: queued tasks usually build on the previous
            // one's result, so barreling on after a broken build just cascades
            // failures. Mark it failed, stop, and let the user inspect — /kø resumes.
            setQueueState(currentQueueID, .failed); currentQueueID = nil
            if queue.contains(where: { $0.state == .queued }) {
                transcript.append(Line(role: .system, text: "kø sat på pause efter en fejl — /kø fortsætter"))
            }
            if status.hasPrefix("Tænker") || status.hasPrefix("…") { status = "Klar." }
        } else if autoReview, let req, let sha = lastSHA {
            // Reviewer pass (advisory, non-blocking). The kø task stays open through
            // its review; the next one only starts after (applyReview drains), so
            // tasks never overlap.
            lastRequest = req; reviewing = true; status = "Gennemgår…"
            setQueueState(currentQueueID, .review)
            runReview(request: req, sha: sha)
        } else {
            setQueueState(currentQueueID, .done); currentQueueID = nil
            if status.hasPrefix("Tænker") || status.hasPrefix("…") { status = "Klar." }
            drainQueue()                      // no review → start the next kø task now
        }
        refreshGit()                          // a build changes the dirty count / branch
        needsRender = true
    }

    private func runReview(request: String, sha: String) {
        guard let cont = channel else { return }
        let engine = self.engine
        Task {
            let diff = await engine.checkpoints.diff(from: sha)
            let report = await ReviewAgent().review(
                request: request, diff: diff,
                provider: ModelRouter.provider(for: engine.config),
                options: ModelRouter.options(for: engine.config))
            cont.yield(.reviewLoaded(report))
        }
    }

    /// /review — spin up one specialised agent per lens IN PARALLEL (korrekthed,
    /// sikkerhed, frontend, backend), then merge into one report.
    private func runReviewPanel(request: String, sha: String) {
        guard let cont = channel else { return }
        let engine = self.engine
        Task {
            let diff = await engine.checkpoints.diff(from: sha)
            let report = await ReviewAgent().reviewPanel(
                request: request, diff: diff,
                provider: ModelRouter.provider(for: engine.config),
                options: ModelRouter.options(for: engine.config))
            cont.yield(.reviewLoaded(report))
        }
    }

    private func applyReview(_ r: ReviewReport) {
        reviewing = false
        lastReview = r
        if r.findings.isEmpty {
            transcript.append(Line(role: .system, text: "✓ Review: \(r.summary.isEmpty ? "ser godt ud" : r.summary)"))
        } else {
            let head = r.summary.isEmpty ? "\(r.actionable.count) fund" : r.summary
            transcript.append(Line(role: .system, text: "Review — \(head)\(r.actionable.isEmpty ? "" : "  (/fix retter dem)")"))
            for f in r.findings {
                let role: Line.Role = f.severity == .critical ? .error : (f.severity == .warn ? .warn : .system)
                let icon = f.severity == .critical ? "✗" : (f.severity == .warn ? "⚠" : "·")
                transcript.append(Line(role: role, text: "  \(icon) [\(f.category)] \(f.file.map { $0 + ": " } ?? "")\(f.message)"))
            }
        }
        if status.hasPrefix("Gennemgår") { status = "Klar." }
        if currentQueueID != nil { setQueueState(currentQueueID, .done); currentQueueID = nil }
        drainQueue()                          // kø task fully done (build + review) → next
        scroll = 0; needsRender = true
    }

    private func reviewNow() {
        guard let req = lastRequest, let sha = lastSHA else {
            transcript.append(Line(role: .system, text: "intet build at gennemgå endnu")); needsRender = true; return
        }
        let lenses = ReviewLens.allCases
        transcript.append(Line(role: .system,
            text: "Spinner \(lenses.count) review-agenter op: " + lenses.map { $0.label }.joined(separator: " · ")))
        reviewing = true; status = "Gennemgår med \(lenses.count) agenter…"; needsRender = true
        runReviewPanel(request: req, sha: sha)
    }

    private func applyFix() {
        guard let r = lastReview, !r.actionable.isEmpty else {
            transcript.append(Line(role: .system, text: "ingen review-fund at rette")); needsRender = true; return
        }
        guard !isBusy else { return }
        startTurn(ReviewAgent.fixPrompt(for: r))
    }

    /// Persist the session (no apiKey) beside the checkpoints.
    private func saveSession() {
        let ref = SessionFile.ModelRef(provider: SessionFile.providerName(for: engine.config.source),
                                       model: engine.config.modelID,
                                       baseURL: engine.config.baseURL.absoluteString)
        let file = SessionFile(project: engine.workspace.root.path, framework: framework,
                               model: ref, turns: sessionTurns)
        file.save(projectDir: engine.workspace.root)
    }

    private func applyAgent(_ ev: AgentEvent) {
        switch ev {
        case .state(let s):
            if StormQuotes.isWorking(s) {
                // Keep ONE quote stable across plan→build→install (don't flash a new
                // one per transition); it only rotates on the ~60s timer below.
                if !statusIsQuote { status = StormQuotes.working.randomElement() ?? status; statusIsQuote = true }
            } else {
                status = Self.label(for: s); statusIsQuote = false
            }
            if case .failed(let why) = s {
                // Show the headline as an error, then the real detail (npm/vite output)
                // as dim lines, then an actionable hint — instead of one truncated blob.
                let lines = why.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                transcript.append(Line(role: .error, text: "✗ \((lines.first ?? "").prefix(160))"))
                for extra in lines.dropFirst().prefix(8) where !extra.trimmingCharacters(in: .whitespaces).isEmpty {
                    transcript.append(Line(role: .system, text: "  \(extra.prefix(160))"))
                }
                if let hint = Self.failureHint(why) { transcript.append(Line(role: .system, text: "  → \(hint)")) }
            }
        case .assistantText(let t):
            if assistantLineIndex == nil {
                transcript.append(Line(role: .assistant, text: ""))
                assistantLineIndex = transcript.count - 1
                currentAssistant = ""
            }
            currentAssistant = (currentAssistant ?? "") + t
            if let i = assistantLineIndex, transcript.indices.contains(i) { transcript[i].text = currentAssistant ?? "" }
            // Fallback: surface a markdown checklist the model wrote as prose (unless it
            // used the explicit todo action, which takes precedence).
            if !sawExplicitTodos, let parsed = TodoItem.fromProse(currentAssistant ?? "") { todos = parsed }
        case .fileWriting(let path):
            liveFile = path; liveBuffer = ""; sidePane = .live   // watch the code as it streams
        case .fileChunk(let path, let text):
            if path == liveFile { liveBuffer += text }
        case .fileWritten(let path):
            if liveFile != path { liveFile = path }          // line-replace edits may not stream chunks
            if !changedFiles.contains(path) { changedFiles.append(path) }
            transcript.append(Line(role: .system, text: "✎ \(path)"))
        case .previewReady(let url):
            transcript.append(Line(role: .system, text: "→ preview: \(url.absoluteString)"))
            status = "kører · \(url.absoluteString)"
        case .metrics(let m):
            mCalls += 1
            mPrompt += m.promptTokens
            mCompletion += m.completionTokens
            mSeconds += m.totalSeconds
            if let t = m.timeToFirstTokenSeconds { mLastTTFT = t }
            if let c = engine.config.cost(promptTokens: m.promptTokens, completionTokens: m.completionTokens) { mCostUSD += c }
        case .todos(let items):
            todos = items; sawExplicitTodos = true            // explicit tag wins over prose detection
        case .reasoning, .usage:
            break
        }
        scroll = 0                                            // stick to the bottom while streaming
        needsRender = true
    }

    static func label(for state: AgentState) -> String {
        switch state {
        case .idle:                   return "Klar."
        case .planning:               return "Planlægger…"
        case .building:               return "Skriver kode…"
        case .applying:               return "Installerer + starter…"
        case .awaitingHMR:            return "Lader det sætte sig…"
        case .collectingErrors:       return "Tjekker for fejl…"
        case .repairing(let attempt): return "Retter fejl (forsøg \(attempt))…"
        case .clean:                  return "✓ Klar."
        case .planReady:              return "✓ Plan klar."
        case .failed(let why):        return "✗ \(why.prefix(60))"
        }
    }

    private var bodyHeight: Int { max(1, size.rows - 3) }

    // MARK: - Rendering

    private var base: Style { theme.base }
    private static let logo = ["█▀▀ ▀█▀ █▀█ █▀█ █▄█", "▀▀█  █  █ █ █▀▄ █ █", "▀▀▀  ▀  ▀▀▀ ▀ ▀ ▀ ▀"]   // STORM

    private func render(force: Bool = false) {
        let now = DispatchTime.now()
        if !force {
            let ms = Double(now.uptimeNanoseconds &- lastRender.uptimeNanoseconds) / 1_000_000
            if ms < 16 { needsRender = true; return }
        }
        lastRender = now
        needsRender = false

        let layout = StormbreakerLayout.compute(size)
        let buf = ScreenBuffer(size: size)
        buf.clear(base)                                          // themed full-screen background

        if onboarding {
            drawOnboarding(buf)
            TUIOutput.emit(TUIRenderer.renderDiff(old: prev, new: buf, cursor: nil))
            prev = buf
            return
        }

        drawHeader(buf, layout.header)
        if transcript.count <= 1, history.isEmpty, !isBusy {
            drawWelcome(buf, layout.transcript)                  // logo + hints before anything happens
        } else {
            drawTranscript(buf, layout.transcript)
        }
        if !layout.side.isEmpty { renderSide(buf, layout.side) }
        drawStatusBar(buf, layout.status)

        var cursorPt = drawInputBox(buf, layout.input, active: pendingPermission == nil && modelChoices == nil)

        // Overlays, drawn last
        if let (req, _) = pendingPermission { drawPermissionModal(buf, request: req); cursorPt = nil }
        else if modelChoices != nil { drawModelModal(buf); cursorPt = nil }
        else if input.hasPrefix("/") { drawSlashMenu(buf, anchor: layout.slashAnchor) }

        TUIOutput.emit(TUIRenderer.renderDiff(old: prev, new: buf, cursor: cursorPt))
        prev = buf
    }

    private func drawHeader(_ buf: ScreenBuffer, _ r: Rect) {
        buf.fill(r, " ", base)
        buf.text("⬢ storm", x: r.x + 1, y: r.y, theme.accentBold)
        // Right side: model name (dim) + ALWAYS-on token usage in a brighter style
        // so it's the glanceable figure next to the model · cost once a call lands.
        let model = modelName
        let sep = "  ·  "
        var usage = "\(fmtTok(sessionTokens)) tok"
        if mCalls > 0 { usage += "  ·  " + fmtCost() }
        let total = TextWidth.width(model) + TextWidth.width(sep) + TextWidth.width(usage)
        let x0 = max(r.x + 10, r.maxX - total - 1)
        buf.text(model, x: x0, y: r.y, theme.dimStyle, clip: r)
        buf.text(sep, x: x0 + TextWidth.width(model), y: r.y, theme.dimStyle, clip: r)
        buf.text(usage, x: x0 + TextWidth.width(model) + TextWidth.width(sep), y: r.y, base, clip: r)
    }

    private func drawWelcome(_ buf: ScreenBuffer, _ r: Rect) {
        let tagline = "byg web-apps fra terminalen — med en lokal AI"
        let hints = ["↵    skriv hvad du vil bygge", "/    kommandoer", "⇥    skift panel          ^C  afslut"]
        let block = Self.logo.count + 2 + hints.count
        var y = r.y + max(0, (r.h - block) / 2)
        func cx(_ s: String) -> Int { r.x + max(0, (r.w - TextWidth.width(s)) / 2) }
        for line in Self.logo { buf.text(line, x: cx(line), y: y, theme.accentBold, clip: r); y += 1 }
        y += 1
        buf.text(tagline, x: cx(tagline), y: y, base, clip: r); y += 2
        for h in hints where y < r.maxY { buf.text(h, x: cx(hints[2]), y: y, theme.dimStyle, clip: r); y += 1 }
    }

    private func drawTranscript(_ buf: ScreenBuffer, _ r: Rect) {
        let vis = transcriptVisualLines(width: max(1, r.w - 1))
        let maxScroll = max(0, vis.count - r.h)
        if scroll > maxScroll { scroll = maxScroll }
        let start = max(0, vis.count - r.h - scroll)
        for i in 0..<min(r.h, max(0, vis.count - start)) {
            let (txt, st) = vis[start + i]
            buf.text(txt, x: r.x, y: r.y + i, st, clip: r)
        }
    }

    private func drawStatusBar(_ buf: ScreenBuffer, _ r: Rect) {
        buf.fill(r, " ", base)
        let spin = (isBusy || reviewing) ? Self.spinner[spinnerFrame % Self.spinner.count] + " " : "▍ "
        let st: Style = status.hasPrefix("✗") ? errStyle : (status.hasPrefix("✓") ? okStyle : ((isBusy || reviewing) ? theme.accentStyle : theme.dimStyle))
        buf.text(spin + status, x: r.x + 1, y: r.y, st, clip: r)
        let hint = "/ kommandoer   ⇥ panel   ^C \(isBusy ? "afbryd" : "afslut")"
        buf.text(hint, x: max(r.x + 1, r.maxX - TextWidth.width(hint) - 1), y: r.y, theme.dimStyle, clip: r)
    }

    /// The bordered input box; returns the caret position (nil when a modal owns input).
    private func drawInputBox(_ buf: ScreenBuffer, _ r: Rect, active: Bool) -> Point? {
        buf.box(r, active ? theme.accentStyle : theme.dimStyle)
        let inner = r.inset(1)
        guard inner.h > 0 else { return nil }
        let prompt = "› "
        if input.isEmpty {
            buf.text(prompt + "skriv en ændring…  (/ for kommandoer)", x: inner.x + 1, y: inner.y, theme.dimStyle, clip: inner)
        } else {
            buf.text(prompt, x: inner.x + 1, y: inner.y, theme.accentStyle, clip: inner)
            buf.text(input, x: inner.x + 1 + TextWidth.width(prompt), y: inner.y, base, clip: inner)
        }
        guard active else { return nil }
        let before = String(input.prefix(cursor))
        let cx = min(inner.x + 1 + TextWidth.width(prompt) + TextWidth.width(before), inner.maxX - 1)
        return Point(x: cx, y: inner.y)
    }

    private func fmtTok(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }

    // MARK: - Onboarding (first run)

    private var onboardRowCount: Int { discovered.count + Self.cloudProviders.count }

    private func handleOnboardingKey(_ key: Key) {
        switch onboardStep {
        case .model: handleOnboardModelKey(key)
        case .cloud: handleOnboardCloudKey(key)
        case .theme: handleOnboardThemeKey(key)
        }
    }

    private func handleOnboardModelKey(_ key: Key) {
        switch key {
        case .up:   onboardSel = (onboardSel - 1 + onboardRowCount) % onboardRowCount; needsRender = true
        case .down: onboardSel = (onboardSel + 1) % onboardRowCount; needsRender = true
        case .enter:
            if onboardSel < discovered.count {                       // a detected local model
                let m = discovered[onboardSel]
                engine.config = m; modelName = m.displayName
                chosenProvider = m.source.rawValue; chosenAPIKey = nil
                onboardStep = .theme
            } else {                                                  // a cloud provider → enter key
                cloudIdx = onboardSel - discovered.count
                cloudModelText = Self.cloudProviders[cloudIdx].model
                cloudKeyText = ""; cloudField = cloudModelText.isEmpty ? 0 : 1
                onboardStep = .cloud
            }
            needsRender = true
        case .escape: onboardStep = .theme; needsRender = true       // skip → keep current default
        default: break
        }
    }

    private func handleOnboardCloudKey(_ key: Key) {
        let p = Self.cloudProviders[cloudIdx]
        switch key {
        case .escape: onboardStep = .model; needsRender = true
        case .tab:    cloudField = 1 - cloudField; needsRender = true
        case .backspace:
            if cloudField == 0 { if !cloudModelText.isEmpty { cloudModelText.removeLast() } }
            else if !cloudKeyText.isEmpty { cloudKeyText.removeLast() }
            needsRender = true
        case .char(let c):
            if cloudField == 0 { cloudModelText.append(c) } else { cloudKeyText.append(c) }
            needsRender = true
        case .enter:
            if cloudField == 0 { cloudField = 1; needsRender = true; return }
            let model = cloudModelText.trimmingCharacters(in: .whitespaces)
            let keyStr = cloudKeyText.trimmingCharacters(in: .whitespaces)
            guard !model.isEmpty, !keyStr.isEmpty else { needsRender = true; return }  // both required
            engine.config = Self.cloudConfig(provider: p.id, model: model, key: keyStr)
            modelName = engine.config.displayName
            chosenProvider = p.id; chosenAPIKey = keyStr
            onboardStep = .theme; needsRender = true
        default: break
        }
    }

    private func handleOnboardThemeKey(_ key: Key) {
        switch key {
        case .left:  onboardThemeIdx = (onboardThemeIdx - 1 + ANSITheme.all.count) % ANSITheme.all.count
                     theme = ANSITheme.all[onboardThemeIdx]; prev = nil; needsRender = true
        case .right: onboardThemeIdx = (onboardThemeIdx + 1) % ANSITheme.all.count
                     theme = ANSITheme.all[onboardThemeIdx]; prev = nil; needsRender = true
        case .enter, .escape: finishOnboarding()
        default: break
        }
    }

    private static func cloudConfig(provider: String, model: String, key: String) -> ModelConfig {
        switch provider {
        case "anthropic":  return .anthropic(key: key, model: model)
        case "gemini":     return .gemini(key: key, model: model)
        case "openrouter": return .openRouter(key: key, model: model)
        case "nvidia":     return .nvidiaNIM(key: key, model: model)
        default:           return .openAI(key: key, model: model)
        }
    }

    /// A friendlier, actionable hint for the common model-connection failures a
    /// beginner hits — instead of leaving them with a raw NSURLError dump.
    private static func failureHint(_ why: String) -> String? {
        let w = why.lowercased()
        if w.contains("could not connect") || w.contains("connection refused") || w.contains("-1004") {
            return "Kan ikke nå modellen — kører Ollama / LM Studio? Vælg en anden med /model."
        }
        if w.contains("more system memory") || w.contains("out of memory") {
            return "Modellen er for stor til din maskines RAM — vælg en mindre model med /model."
        }
        if w.contains("model not found") || w.contains("no models loaded") || w.contains("failed to load")
            || w.contains("model_not_found") || w.contains("404") {
            return "Modellen er ikke indlæst — åbn den i LM Studio (slå 'JIT model loading' til) eller kør `ollama pull`, og vælg evt. en anden med /model."
        }
        if w.contains("timed out") || w.contains("-1001") {
            return "Modellen svarede ikke i tide — prøv en mindre/hurtigere model med /model."
        }
        if w.contains("401") || w.contains("unauthorized") || w.contains("api key") || w.contains("invalid_api_key") {
            return "API-nøglen blev afvist — tjek den (kør /model for at vælge model igen)."
        }
        // npm / install / node failures (the real npm output is now in the message)
        if w.contains("eresolve") || w.contains("peer dep") {
            return "Afhængigheds-konflikt (peer deps) — prøv igen, eller bed om en anden pakke."
        }
        if w.contains("enotfound") || w.contains("etimedout") || w.contains("getaddrinfo") || w.contains("network") || w.contains("registry") {
            return "Netværksfejl under install — tjek din internetforbindelse og prøv igen."
        }
        if w.contains("node runtime not found") || (w.contains("not found") && w.contains("node")) {
            return "Node mangler — installér Node (nodejs.org eller `brew install node`) og prøv igen."
        }
        if w.contains("install failed") || w.contains("npm err") {
            return "Pakke-installation fejlede — se fejlen ovenfor; ofte node-version eller en pakke der ikke findes."
        }
        return nil
    }

    private func finishOnboarding() {
        onboarding = false
        var c = StormbreakerConfig.load()
        c.onboarded = true; c.theme = theme.name
        if let p = chosenProvider {                                  // persist the picked model
            c.provider = p; c.model = engine.config.modelID
            if p == "ollama" || p == "lmStudio" { c.baseURL = engine.config.baseURL.absoluteString }
            if let k = chosenAPIKey { c.apiKey = k }                 // CLI config (chmod 600 on save)
        }
        c.save()
        transcript.append(Line(role: .system,
            text: "Model: \(modelName) · tema: \(theme.name). Beskriv hvad du vil bygge og tryk Enter — / for kommandoer."))
        prev = nil; needsRender = true
    }

    private func onboardSourceLabel(_ s: ModelConfig.Source) -> String {
        switch s { case .ollama: return "Ollama"; case .lmStudio: return "LM Studio"; case .cloud: return "Cloud" }
    }

    private func drawOnboarding(_ buf: ScreenBuffer) {
        switch onboardStep {
        case .model: drawOnboardModel(buf)
        case .cloud: drawOnboardCloud(buf)
        case .theme: drawOnboardTheme(buf)
        }
    }

    private func drawOnboardModel(_ buf: ScreenBuffer) {
        let r = Rect(x: 0, y: 0, w: size.cols, h: size.rows)
        func cx(_ s: String) -> Int { max(0, (size.cols - TextWidth.width(s)) / 2) }
        let block = Self.logo.count + 5 + onboardRowCount
        var y = max(1, (size.rows - block) / 2)
        for line in Self.logo { buf.text(line, x: cx(line), y: y, theme.accentBold, clip: r); y += 1 }
        y += 1
        let greet = "Velkommen til Stormbreaker"
        buf.text(greet, x: cx(greet), y: y, base, clip: r); y += 1
        let sub = discovered.isEmpty
            ? "Ingen lokale modeller fundet — vælg en cloud-udbyder:"
            : "Vælg en model (fundet lokalt + cloud):"
        buf.text(sub, x: cx(sub), y: y, theme.dimStyle, clip: r); y += 2
        let listW = 50
        let lx = max(2, (size.cols - listW) / 2)
        for i in 0..<onboardRowCount {
            let sel = i == onboardSel
            let name: String, tag: String
            if i < discovered.count {
                name = discovered[i].displayName; tag = onboardSourceLabel(discovered[i].source)
            } else {
                name = Self.cloudProviders[i - discovered.count].label; tag = "cloud · API-nøgle"
            }
            let left = (sel ? "› " : "  ") + TextWidth.truncate(name, toWidth: 30)
            let padded = left + String(repeating: " ", count: max(1, listW - 14 - TextWidth.width(left)))
            buf.text(TextWidth.truncate(padded + tag, toWidth: listW), x: lx, y: y,
                     sel ? theme.accentBold : base, clip: r)
            y += 1
        }
        y += 1
        let hint = "↑ ↓  vælg     ↵  videre     Esc  spring over"
        buf.text(hint, x: cx(hint), y: y, theme.dimStyle, clip: r)
    }

    private func drawOnboardCloud(_ buf: ScreenBuffer) {
        let r = Rect(x: 0, y: 0, w: size.cols, h: size.rows)
        func cx(_ s: String) -> Int { max(0, (size.cols - TextWidth.width(s)) / 2) }
        let p = Self.cloudProviders[cloudIdx]
        var y = max(2, size.rows / 2 - 4)
        let title = "\(p.label) — opsætning"
        buf.text(title, x: cx(title), y: y, theme.accentBold, clip: r); y += 2
        let fx = max(2, (size.cols - 52) / 2)
        drawOnboardField(buf, x: fx, y: y, label: "Model-id:", value: cloudModelText, active: cloudField == 0, masked: false); y += 2
        drawOnboardField(buf, x: fx, y: y, label: "API-nøgle:", value: cloudKeyText, active: cloudField == 1, masked: true); y += 2
        let hint = "↵ næste felt / færdig    ⇥ skift felt    Esc tilbage"
        buf.text(hint, x: cx(hint), y: y, theme.dimStyle, clip: r)
    }

    private func drawOnboardField(_ buf: ScreenBuffer, x: Int, y: Int, label: String, value: String, active: Bool, masked: Bool) {
        let r = Rect(x: 0, y: 0, w: size.cols, h: size.rows)
        buf.text(label, x: x, y: y, active ? theme.accentBold : theme.dimStyle, clip: r)
        let shown = masked ? String(repeating: "•", count: value.count) : value
        let inner = TextWidth.truncate(shown, toWidth: 36)
        let box = "[ " + inner + (active ? "▍" : "") + String(repeating: " ", count: max(0, 36 - TextWidth.width(inner))) + " ]"
        buf.text(box, x: x + 12, y: y, active ? base : theme.dimStyle, clip: r)
    }

    private func drawOnboardTheme(_ buf: ScreenBuffer) {
        let r = Rect(x: 0, y: 0, w: size.cols, h: size.rows)
        func cx(_ s: String) -> Int { max(0, (size.cols - TextWidth.width(s)) / 2) }
        let greet = "Velkommen til Stormbreaker"
        let modelLine = "Model:   \(modelName)"
        let combo = "Tema:    ‹ \(theme.name) ›"
        let hint = "← →  vælg tema       ↵  begynd"
        let block = Self.logo.count + 6
        var y = max(1, (size.rows - block) / 2)
        for line in Self.logo { buf.text(line, x: cx(line), y: y, theme.accentBold, clip: r); y += 1 }
        y += 1
        buf.text(greet, x: cx(greet), y: y, base, clip: r); y += 2
        buf.text(modelLine, x: cx(modelLine), y: y, theme.dimStyle, clip: r); y += 1
        let comboX = cx(combo)
        buf.text("Tema:    ‹ ", x: comboX, y: y, theme.dimStyle, clip: r)
        let nameX = comboX + TextWidth.width("Tema:    ‹ ")
        buf.text(theme.name, x: nameX, y: y, theme.accentBold, clip: r)
        buf.text(" ›", x: nameX + TextWidth.width(theme.name), y: y, theme.dimStyle, clip: r)
        y += 2
        buf.text(hint, x: cx(hint), y: y, theme.dimStyle, clip: r)
    }

    private func drawPermissionModal(_ buf: ScreenBuffer, request: PermissionRequest) {
        let label = request.label
        let w = min(size.cols - 4, max(40, TextWidth.width(label) + 6))
        let h = 6
        let x = (size.cols - w) / 2
        let y = (size.rows - h) / 2
        let rect = Rect(x: x, y: y, w: w, h: h)
        buf.fill(rect, " ", base)
        buf.box(rect, warnStyle, title: "Tilladelse")
        buf.text(TextWidth.truncate(label, toWidth: w - 4), x: x + 2, y: y + 2, base, clip: rect)
        buf.text("[J]a   [A]ltid i session   [N]ej", x: x + 2, y: y + 4, accent, clip: rect)
    }

    private func drawModelModal(_ buf: ScreenBuffer) {
        guard let choices = modelChoices else { return }
        let w = min(size.cols - 4, 66)
        let h = min(size.rows - 2, choices.count + 4)
        let x = (size.cols - w) / 2, y = (size.rows - h) / 2
        let rect = Rect(x: x, y: y, w: w, h: h)
        buf.fill(rect, " ", base)
        buf.box(rect, accentBold, title: "Vælg model")
        for (i, m) in choices.enumerated() where y + 1 + i < y + h - 1 {
            let src = m.source == .cloud ? "cloud" : (m.source == .ollama ? "ollama" : "lm studio")
            let cost = m.source == .cloud ? "" : " · gratis"
            let cur = m.id == engine.config.id ? " ✓" : ""
            let line = "\(i + 1))  \(m.displayName)  ·  \(src)\(cost)\(cur)"
            buf.text(TextWidth.truncate(line, toWidth: w - 4), x: x + 2, y: y + 1 + i, base, clip: rect)
        }
        buf.text("tal vælger · Esc annullerer", x: x + 2, y: y + h - 1, dimStyle, clip: rect)
    }

    /// The side pane: the live-streaming file (syntax-highlighted, with a gutter), or
    /// an info card. Tab toggles which one is shown while a file is streaming.
    private func renderSide(_ buf: ScreenBuffer, _ rect: Rect) {
        // A live plan checklist (when present) gets a small panel at the TOP of the
        // column, ABOVE whichever pane is active — so it stays visible even while the
        // live-file view shows code streaming in during the build.
        var rect = rect
        if !todos.isEmpty, rect.h >= 8 {
            let h = min(todos.count + 2, max(4, rect.h / 2))
            renderPlan(buf, Rect(x: rect.x, y: rect.y, w: rect.w, h: h))
            rect = Rect(x: rect.x, y: rect.y + h, w: rect.w, h: rect.h - h)
        }
        switch sidePane {
        case .diff:
            buf.box(rect, dimStyle, title: "Diff")
            let inner = rect.inset(1); guard inner.h > 0 else { return }
            let lines: [(String, Style)] = diffText.isEmpty
                ? [("(intet endnu — /diff efter et build)", dimStyle)]
                : DiffRenderer.lines(diffText, theme: theme)
            for (i, pair) in lines.prefix(inner.h).enumerated() {
                buf.text(TextWidth.truncate(pair.0, toWidth: inner.w), x: inner.x, y: inner.y + i, pair.1, clip: inner)
            }
        case .live where liveFile != nil:
            buf.box(rect, dimStyle, title: shortName(liveFile!))
            let inner = rect.inset(1); guard inner.h > 0, inner.w > 6 else { return }
            let lines = liveBuffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let show = Array(lines.suffix(inner.h))               // newest lines = watch it being written
            let firstNo = max(1, lines.count - show.count + 1)
            for (i, line) in show.enumerated() {
                let no = firstNo + i
                let gutter = String(repeating: " ", count: max(0, 3 - String(no).count)) + "\(no) "
                buf.text(gutter, x: inner.x, y: inner.y + i, dimStyle, clip: inner)
                var x = inner.x + 4
                for (seg, st) in ANSIColorizer.spans(line, theme: theme) {
                    if x >= inner.maxX { break }
                    x = buf.text(seg, x: x, y: inner.y + i, st, clip: inner)
                }
            }
        case .context, .live:                                    // .live with no file yet → context
            renderContext(buf, rect)
        }
    }

    /// Compact, always-visible plan checklist (todowrite-style) at the top of the side
    /// column during a build: ✓ done · spinner active · ○ to-do.
    private func renderPlan(_ buf: ScreenBuffer, _ rect: Rect) {
        let done = todos.filter { $0.status == .done }.count
        buf.box(rect, dimStyle, title: "Plan \(done)/\(todos.count)")
        let inner = rect.inset(1)
        guard inner.h > 0, inner.w > 4 else { return }
        let overflow = todos.count > inner.h
        let shown = overflow ? max(0, inner.h - 1) : todos.count
        for (i, t) in todos.prefix(shown).enumerated() {
            let icon: String, st: Style
            switch t.status {
            case .done:    icon = "✓"; st = theme.on(theme.ok)
            case .active:  icon = Self.spinner[spinnerFrame % Self.spinner.count]; st = theme.accentStyle
            case .pending: icon = "○"; st = dimStyle
            }
            buf.text(TextWidth.truncate("\(icon) \(t.text)", toWidth: inner.w), x: inner.x, y: inner.y + i, st, clip: inner)
        }
        if overflow {
            buf.text("+\(todos.count - shown) flere", x: inner.x, y: inner.y + shown, dimStyle, clip: inner)
        }
    }

    /// The persistent context sidebar (opencode-style): what's being worked on right
    /// now — project, token usage, changed files, skills, and active connectors.
    private func renderContext(_ buf: ScreenBuffer, _ rect: Rect) {
        buf.box(rect, dimStyle, title: "Kontekst")
        let inner = rect.inset(1)
        guard inner.h > 0, inner.w > 10 else { return }
        var y = inner.y
        let x = inner.x + 1
        let w = inner.w - 2
        func head(_ s: String) { guard y < inner.maxY else { return }; buf.text(s, x: x, y: y, theme.accentBold, clip: inner); y += 1 }
        func line(_ s: String, _ st: Style? = nil) { guard y < inner.maxY else { return }; buf.text(TextWidth.truncate(s, toWidth: w), x: x, y: y, st ?? base, clip: inner); y += 1 }
        func gap() { if y < inner.maxY { y += 1 } }

        head("PROJEKT")
        line("\(shortName(engine.workspace.root.path)) · \(framework)")
        line(prettyPath(engine.workspace.root.path), dimStyle)
        gap()

        head("GIT")
        if !gitChecked {
            line("tjekker…", dimStyle)
        } else if !git.isRepo {
            line("ikke et git-repo", dimStyle)
            line("/github udgiver til GitHub", theme.accentStyle)
        } else {
            line("\(git.repoName ?? shortName(engine.workspace.root.path)) · \(git.branch)")
            if git.hasRemote {
                if git.hasUpstream {
                    var parts: [String] = []
                    if git.ahead > 0  { parts.append("↑\(git.ahead)") }
                    if git.behind > 0 { parts.append("↓\(git.behind)") }
                    let synced = parts.isEmpty && git.dirty == 0
                    let dirtyTxt = git.dirty > 0 ? "\(git.dirty) ændr." : ""
                    let label = parts.isEmpty
                        ? (dirtyTxt.isEmpty ? "synkroniseret ✓" : dirtyTxt + " · /push")
                        : (parts.joined(separator: " ") + (dirtyTxt.isEmpty ? "" : " · " + dirtyTxt))
                    line(label, synced ? theme.on(theme.ok) : theme.on(theme.warn))
                } else {
                    line(git.dirty > 0 ? "\(git.dirty) ændr. · /push" : "ikke pushet · /push", theme.on(theme.warn))
                }
                line(prettyRemote(git.remoteURL), dimStyle)
            } else {
                line(git.dirty > 0 ? "\(git.dirty) ændringer · /commit" : "rent træ", dimStyle)
                line("ingen remote · /github", theme.accentStyle)
            }
            if let pr = git.openPR { line("PR " + pr, theme.accentStyle) }
            if gitBusy { line("arbejder…", theme.accentStyle) }
        }
        gap()

        head("FORBRUG")
        if mCalls == 0 {
            line("ingen kald endnu", dimStyle)
        } else {
            line("\(fmtTok(sessionTokens)) tok · \(mCalls) kald")
            line("\(fmtTok(mPrompt))→\(fmtTok(mCompletion)) · \(Int(tokPerSec)) tok/s", dimStyle)
            line("TTFT \(fmtTTFT(mLastTTFT)) · \(fmtCost())", dimStyle)
        }
        gap()

        head("FILER ÆNDRET (\(changedFiles.count))")
        if changedFiles.isEmpty { line("ingen endnu", dimStyle) }
        else {
            let shown = changedFiles.suffix(6)
            for f in shown { line(relativePath(f), theme.on(theme.ok)) }
            if changedFiles.count > shown.count { line("+\(changedFiles.count - shown.count) flere", dimStyle) }
        }
        gap()

        head("REVIEW")
        if reviewing { line("gennemgår…", theme.accentStyle) }
        else if let r = lastReview {
            if r.isClean { line("✓ " + (r.summary.isEmpty ? "ser godt ud" : r.summary), theme.on(theme.ok)) }
            else { line("\(r.actionable.count) ting · /fix", theme.on(theme.warn)) }
        } else { line(autoReview ? "kører efter build" : "fra · /review", dimStyle) }
        gap()

        let qActive = queue.filter { $0.state == .queued || $0.state == .building || $0.state == .review }.count
        head("KØ" + (qActive > 0 ? " (\(qActive))" : ""))
        if queue.isEmpty {
            line("tom · /kø <opgave>", dimStyle)
        } else {
            for item in queue.suffix(6) {
                let st: Style
                switch item.state {
                case .building, .review: st = theme.accentStyle
                case .done:    st = theme.on(theme.ok)
                case .failed:  st = theme.on(theme.error)
                case .queued:  st = base
                }
                let icon = item.state == .building
                    ? Self.spinner[spinnerFrame % Self.spinner.count]
                    : Self.qIcon(item.state)
                line("\(icon) \(item.prompt)", st)
            }
            if queue.count > 6 { line("+\(queue.count - 6) flere", dimStyle) }
        }
        gap()

        head("SKILLS (\(skills.count))")
        line(skills.isEmpty ? "ingen" : skills.prefix(5).map { $0.id }.joined(separator: " · "), dimStyle)
        gap()

        let tools = engine.mcp.availableTools
        head("CONNECTORS")
        if tools.isEmpty { line("ingen aktive (MCP)", dimStyle) }
        else {
            let servers = Array(Set(tools.map { $0.server })).sorted()
            line("\(tools.count) værktøj · \(servers.count) server", dimStyle)
            for s in servers.prefix(3) { line("· \(s)", dimStyle) }
        }
    }

    // MARK: - Sidebar formatting helpers

    private func prettyPath(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let s = p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
        return s.count <= 30 ? s : "…" + s.suffix(29)
    }
    private func relativePath(_ p: String) -> String {
        let root = engine.workspace.root.path
        return p.hasPrefix(root) ? String(p.dropFirst(root.count).drop(while: { $0 == "/" })) : shortName(p)
    }
    /// "github.com/owner/repo" from any remote URL (SSH or HTTPS), else the raw URL.
    private func prettyRemote(_ url: String?) -> String {
        guard let url else { return "" }
        if let (o, r) = GitService.ownerRepo(url) { return "github.com/\(o)/\(r)" }
        return url
    }
    private func fmtTTFT(_ s: Double?) -> String { s.map { String(format: "%.2fs", $0) } ?? "—" }
    private func fmtCost() -> String {
        if engine.config.source != .cloud { return "lokal" }            // Ollama / LM Studio
        if mCostUSD > 0 { return String(format: "≈ $%.3f", mCostUSD) }
        if engine.config.modelID.hasSuffix(":free") { return "gratis" } // OpenRouter free tier
        return "—"                                                       // cloud, price unknown
    }

    // MARK: - Slash commands (minimal; the full menu lands in P12)

    private func handleCommand(_ line: String) {
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = (parts.first ?? "").lowercased()
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "diff":       loadDiff(arg)
        case "model":      loadModels()
        case "undo":       restoreToTurn("")
        case "restore":    restoreToTurn(arg)
        case "checkpoints", "cp": listCheckpoints()
        case "review":     reviewNow()
        case "fix":        applyFix()
        case "theme":      switchTheme(arg)
        case "init":       writeAgentsFile()
        case "github", "publish": gitPublish(arg)
        case "commit":     gitCommit(arg)
        case "push":       gitPushPull(push: true)
        case "pull":       gitPushPull(push: false)
        case "pr":         gitPR(arg)
        case "git":        refreshGit(manual: true)
        case "kø", "ko", "queue", "swarm": queueCommand(arg)
        case "compact", "komprimer", "komprimér": compactNow()
        case "copy", "kopier", "yank": copyLast()
        case "quit", "q":  running = false
        case "help":       transcript.append(Line(role: .system, text: Self.slashCommands.map { "\($0.0) — \($0.1)" }.joined(separator: "\n")))
        default:           transcript.append(Line(role: .system, text: "ukendt kommando: /\(cmd) — prøv /help"))
        }
    }

    /// /model — discover local models (LM Studio + Ollama) and open the picker. The
    /// current model is kept selectable so you can confirm/keep it.
    private func loadModels() {
        guard let cont = channel else { return }
        status = "Finder modeller…"
        let current = engine.config
        Task {
            var models = await ModelDiscovery.discoverLocal()
            if !models.contains(where: { $0.id == current.id }) { models.insert(current, at: 0) }
            cont.yield(.modelsLoaded(models))
        }
    }

    /// Persist a /model switch so it survives the next launch. Only local models —
    /// /model lists discovered local models + the current one, so it never introduces
    /// a new cloud provider; a configured cloud stays as set in onboarding.
    private func persistModel(_ m: ModelConfig) {
        guard m.source != .cloud else { return }
        var c = StormbreakerConfig.load()
        c.provider = m.source.rawValue        // "ollama" | "lmStudio"
        c.model = m.modelID
        c.baseURL = m.baseURL.absoluteString
        c.save()
    }

    private func handleModelKey(_ key: Key) {
        guard let choices = modelChoices else { return }
        switch key {
        case .escape:
            modelChoices = nil; status = "Klar."; needsRender = true
        case .char(let c) where c.isNumber:
            let n = (Int(String(c)) ?? 0) - 1
            if n >= 0, n < choices.count {
                engine.config = choices[n]                  // next turn's makeDeps reads the new model
                modelName = choices[n].displayName
                persistModel(choices[n])                    // remember the switch across launches
                modelChoices = nil
                status = "Model: \(modelName)"
                needsRender = true
            }
        default: break
        }
    }

    private var userTurns: [SessionFile.Turn] { sessionTurns.filter { $0.role == "user" } }

    /// /diff [n] — what turn n changed vs the next checkpoint (or the working tree),
    /// via the pre-turn snapshots. No arg = the latest snapshot vs the working tree.
    private func loadDiff(_ arg: String) {
        guard let cont = channel else { return }
        let users = userTurns
        let from: String?, to: String?
        if let n = Int(arg) {
            guard n >= 1, n <= users.count else {
                transcript.append(Line(role: .system, text: "ugyldigt tur-nummer (1–\(users.count))")); return
            }
            from = users[n - 1].checkpointSHA
            to = n < users.count ? users[n].checkpointSHA : nil
        } else {
            from = lastSHA; to = nil
        }
        guard let f = from else {
            transcript.append(Line(role: .system, text: "ingen checkpoints endnu — kør et build først")); return
        }
        let engine = self.engine
        status = "Henter diff…"
        Task {
            let d = await engine.checkpoints.diff(from: f, to: to)
            cont.yield(.diffLoaded(d.isEmpty ? "(ingen ændringer)" : d))
        }
    }

    /// /restore [n] (or /undo) — revert the working tree to before turn n (default: the
    /// last turn) via its pre-turn checkpoint, then drop that turn from history.
    private func restoreToTurn(_ arg: String) {
        guard let cont = channel else { return }
        let users = userTurns
        guard !users.isEmpty else { transcript.append(Line(role: .system, text: "ingen checkpoints at gendanne")); return }
        let n = Int(arg) ?? users.count
        guard n >= 1, n <= users.count, let sha = users[n - 1].checkpointSHA else {
            transcript.append(Line(role: .system, text: "ugyldigt tur-nummer (1–\(users.count))")); return
        }
        let engine = self.engine
        status = "Gendanner…"
        Task {
            let ok = await engine.checkpoints.restore(to: sha)
            cont.yield(.restored(n, ok))
        }
    }

    private func applyRestore(_ n: Int, _ ok: Bool) {
        if ok {
            let keep = (n - 1) * 2                                 // each completed turn = 2 session entries
            if keep <= sessionTurns.count { sessionTurns = Array(sessionTurns.prefix(keep)) }
            history = sessionTurns.compactMap {
                $0.role == "user" ? ChatMessage(role: .user, content: $0.content)
                    : $0.role == "assistant" ? ChatMessage(role: .assistant, content: $0.content) : nil
            }
            lastSHA = userTurns.last?.checkpointSHA
            saveSession()
            transcript.append(Line(role: .system, text: "↩ gendannet til før tur \(n) — filer rullet tilbage."))
            status = "Gendannet."
        } else {
            transcript.append(Line(role: .error, text: "kunne ikke gendanne (ugyldig checkpoint)"))
            status = "Klar."
        }
        needsRender = true
    }

    private func listCheckpoints() {
        let users = userTurns
        guard !users.isEmpty else { transcript.append(Line(role: .system, text: "ingen checkpoints endnu")); return }
        transcript.append(Line(role: .system, text: "checkpoints:"))
        for (i, t) in users.enumerated() {
            transcript.append(Line(role: .system, text: "  \(i + 1)) \(t.checkpointSHA?.prefix(7) ?? "—") · \(t.content.prefix(50))"))
        }
    }

    static let slashCommands: [(String, String)] = [
        ("/diff", "vis ændringer fra sidste tur"),
        ("/model", "skift AI-model"),
        ("/undo", "fortryd sidste tur"),
        ("/restore", "gendan til tur n"),
        ("/checkpoints", "liste over ture"),
        ("/review", "gennemgå med 4 parallelle agenter"),
        ("/fix", "ret reviewer-fund"),
        ("/theme", "skift farvetema"),
        ("/init", "skriv AGENTS.md"),
        ("/github", "udgiv projektet til GitHub"),
        ("/commit", "gem ændringer (commit)"),
        ("/push", "send commits til GitHub"),
        ("/pull", "hent ændringer fra GitHub"),
        ("/pr", "opret et pull request"),
        ("/kø", "stil byggeopgaver i kø (kører én ad gangen)"),
        ("/compact", "komprimér samtalehistorik (spar kontekst)"),
        ("/copy", "kopiér sidste svar til udklipsholderen"),
        ("/help", "vis kommandoer"),
        ("/quit", "afslut"),
    ]

    private func switchTheme(_ arg: String) {
        if arg.isEmpty {
            let names = ANSITheme.all.map { $0.name.lowercased() }.joined(separator: " · ")
            transcript.append(Line(role: .system, text: "temaer: \(names)  (nu: \(theme.name.lowercased()))"))
        } else if let t = ANSITheme.named(arg) {
            theme = t; prev = nil                                   // force a full repaint in the new colors
            var c = StormbreakerConfig.load(); c.theme = t.name; c.save()  // remember the choice
            transcript.append(Line(role: .system, text: "tema: \(t.name)"))
        } else {
            transcript.append(Line(role: .system, text: "ukendt tema — prøv: " + ANSITheme.all.map { $0.name.lowercased() }.joined(separator: ", ")))
        }
    }

    private func writeAgentsFile() {
        let url = engine.workspace.root.appendingPathComponent("AGENTS.md")
        if FileManager.default.fileExists(atPath: url.path) {
            transcript.append(Line(role: .system, text: "AGENTS.md findes allerede — redigér den i editoren.")); return
        }
        do {
            try AgentsTemplate.render(project: shortName(engine.workspace.root.path), framework: framework)
                .write(to: url, atomically: true, encoding: .utf8)
            transcript.append(Line(role: .system, text: "oprettede AGENTS.md — reglerne læses automatisk hver tur."))
        } catch {
            transcript.append(Line(role: .error, text: "kunne ikke skrive AGENTS.md"))
        }
    }

    /// /copy — copy the last assistant reply to the macOS clipboard. A full-screen
    /// TUI makes mouse-selection grab the whole layout (borders + sidebar), so this
    /// gives a clean way to grab just the answer.
    private func copyLast() {
        let text = history.last(where: { $0.role == .assistant })?.content ?? currentAssistant
        guard let text, !text.isEmpty else {
            transcript.append(Line(role: .system, text: "intet svar at kopiere endnu")); needsRender = true; return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe(); p.standardInput = pipe
        do {
            try p.run()
            pipe.fileHandleForWriting.write(Data(text.utf8))
            try? pipe.fileHandleForWriting.close()
            p.waitUntilExit()
            transcript.append(Line(role: .system, text: "📋 kopierede sidste svar (\(text.count) tegn) til udklipsholderen"))
        } catch {
            transcript.append(Line(role: .system, text: "kunne ikke kopiere (pbcopy utilgængelig)"))
        }
        needsRender = true
    }

    // MARK: - GitHub (the project's REAL .git + gh)

    /// Probe the project's git state and refresh the GIT sidebar section. Runs off
    /// the main loop; the result returns via `.gitStatusLoaded`.
    private func refreshGit(manual: Bool = false) {
        guard let cont = channel else { return }
        let svc = GitService(root: engine.workspace.root)
        if manual { status = "Tjekker git…"; needsRender = true }
        Task { cont.yield(.gitStatusLoaded(await svc.status())) }
    }

    /// Run a git/gh operation, then re-probe status so the sidebar reflects the
    /// new state. The op + the refresh both run off the cooperative pool.
    private func runGitOp(_ label: String, _ op: @escaping @Sendable (GitService) async -> GitService.OpResult) {
        guard let cont = channel else { return }
        guard !gitBusy else { return }                    // one git op at a time
        let svc = GitService(root: engine.workspace.root)
        gitBusy = true; status = label; needsRender = true
        Task {
            let r = await op(svc)
            let st = await svc.status()
            cont.yield(.gitOpDone(r, st))
        }
    }

    private func applyGitOp(_ r: GitService.OpResult, _ st: GitStatus) {
        gitBusy = false; git = st; gitChecked = true
        transcript.append(Line(role: r.ok ? .system : .error,
                               text: (r.ok ? "✓ " : "✗ ") + r.message))
        if let url = r.url { transcript.append(Line(role: .system, text: "  " + url)) }
        status = "Klar."; scroll = 0; needsRender = true
    }

    /// /github [navn] [public] — create a GitHub repo from this project and push.
    /// Defaults to a PRIVATE repo (the privacy-preserving choice); add `public`
    /// to publish openly.
    private func gitPublish(_ arg: String) {
        let tokens = arg.split(separator: " ").map(String.init)
        let isPublic = tokens.contains(where: { $0 == "public" || $0 == "offentlig" })
        let name = tokens.first(where: { $0 != "public" && $0 != "offentlig" })
            ?? shortName(engine.workspace.root.path)
        transcript.append(Line(role: .system,
            text: "Udgiver “\(name)” som \(isPublic ? "offentligt" : "privat") GitHub-repo…"))
        runGitOp("Udgiver til GitHub…") { await $0.publish(name: name, isPrivate: !isPublic) }
    }

    /// /commit [besked] — stage everything and commit.
    private func gitCommit(_ arg: String) {
        runGitOp("Committer…") { await $0.commitAll(message: arg) }
    }

    /// /push and /pull — sync with the remote. Both need a published repo.
    private func gitPushPull(push: Bool) {
        guard git.isRepo else {
            transcript.append(Line(role: .system, text: "ikke et git-repo endnu — kør /github")); needsRender = true; return
        }
        if push { runGitOp("Pusher…") { await $0.push() } }
        else    { runGitOp("Puller…") { await $0.pull() } }
    }

    /// /pr [titel] — open a draft PR (carves off a feature branch if on main).
    private func gitPR(_ arg: String) {
        guard git.hasRemote else {
            transcript.append(Line(role: .system, text: "udgiv først med /github")); needsRender = true; return
        }
        let title = arg.isEmpty ? (lastRequest ?? "Stormbreaker-ændringer") : arg
        runGitOp("Opretter PR…") { await $0.openPR(title: title) }
    }

    // MARK: - Kø (sequential task queue / swarm-lite)

    /// /kø <opgave> queues a build · /kø lists + resumes draining · /kø ryd clears
    /// the pending (not-yet-started) items.
    private func queueCommand(_ arg: String) {
        let a = arg.trimmingCharacters(in: .whitespaces)
        if a.isEmpty {
            if queue.isEmpty {
                transcript.append(Line(role: .system, text: "køen er tom — /kø <opgave> tilføjer en byggeopgave"))
            } else {
                transcript.append(Line(role: .system, text: "kø (\(queue.count)):"))
                for item in queue {
                    transcript.append(Line(role: .system, text: "  \(Self.qIcon(item.state)) \(item.prompt.prefix(60))"))
                }
                drainQueue()                              // resume if idle (e.g. after a cancel)
            }
            needsRender = true; return
        }
        if a.lowercased() == "ryd" || a.lowercased() == "clear" {
            queue.removeAll { $0.state == .queued }
            transcript.append(Line(role: .system, text: "ryddede ventende kø-opgaver"))
            needsRender = true; return
        }
        queueSeq += 1
        queue.append(QueueItem(id: queueSeq, prompt: a, state: .queued))
        transcript.append(Line(role: .system, text: "+ kø: \(a.prefix(60))  (\(queue.filter { $0.state == .queued }.count) venter)"))
        drainQueue()                                      // starts immediately if idle
        needsRender = true
    }

    /// Start the next queued task if the engine is idle. Sequential by design —
    /// each task builds on the previous one's result, so they never overlap.
    private func drainQueue() {
        guard !isBusy, currentQueueID == nil else { return }
        guard let idx = queue.firstIndex(where: { $0.state == .queued }) else { return }
        queue[idx].state = .building
        currentQueueID = queue[idx].id
        startTurn(queue[idx].prompt)
    }

    private func setQueueState(_ id: Int?, _ s: QState) {
        guard let id, let i = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[i].state = s
    }

    static func qIcon(_ s: QState) -> String {
        switch s {
        case .queued:   return "⋯"
        case .building: return "⟳"
        case .review:   return "◎"
        case .done:     return "✓"
        case .failed:   return "✗"
        }
    }

    /// Discovery popover above the input while typing a / command.
    private func drawSlashMenu(_ buf: ScreenBuffer, anchor: Rect) {
        let matches = Self.slashCommands.filter { $0.0.hasPrefix(input.lowercased()) }
        guard !matches.isEmpty, anchor.h >= 3 else { return }
        let h = min(anchor.h, matches.count + 2), w = min(anchor.w, 46)
        let rect = Rect(x: anchor.x, y: anchor.maxY - h, w: w, h: h)
        buf.fill(rect, " ", base)
        buf.box(rect, accent, title: "kommandoer")
        for (i, c) in matches.prefix(h - 2).enumerated() {
            buf.text(TextWidth.truncate("\(c.0)  \(c.1)", toWidth: w - 4),
                     x: rect.x + 2, y: rect.y + 1 + i, i == 0 ? accentBold : dimStyle, clip: rect)
        }
    }

    private func shortName(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }

    private func transcriptVisualLines(width: Int) -> [(String, Style)] {
        var out: [(String, Style)] = []
        let bodyWidth = max(1, width - 2)
        for line in transcript {
            switch line.role {
            case .user:
                out.append(("▌ Dig", accentBold))
                for w in TextWidth.wrap(line.text, width: bodyWidth) { out.append(("  " + w, base)) }
                out.append(("", base))
            case .assistant:
                out.append(("▌ storm", theme.on(theme.accent, dim: true)))
                for w in TextWidth.wrap(line.text.isEmpty ? "…" : line.text, width: bodyWidth) { out.append(("  " + w, base)) }
                out.append(("", base))
            case .system:
                for w in TextWidth.wrap(line.text, width: bodyWidth) { out.append(("  " + w, dimStyle)) }
            case .error:
                for w in TextWidth.wrap(line.text, width: bodyWidth) { out.append(("  " + w, errStyle)) }
            case .warn:
                for w in TextWidth.wrap(line.text, width: bodyWidth) { out.append(("  " + w, warnStyle)) }
            }
        }
        return out
    }
}
