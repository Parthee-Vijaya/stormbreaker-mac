import Foundation
import ForgeKit
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
    case turnEnded
}

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
    struct Line { enum Role { case user, assistant, system, error }; var role: Role; var text: String }

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
    private var size: Size
    private var prev: ScreenBuffer?

    private var transcript: [Line] = []
    private var history: [ChatMessage] = []
    private var input = ""
    private var cursor = 0
    private var scroll = 0
    private var status = "Klar."
    private var liveFile: String?              // file currently streaming (side pane)
    private var liveBuffer = ""                // its contents so far
    enum SidePane { case live, info, diff }
    private var sidePane: SidePane = .live     // Tab cycles live → info → diff; /diff jumps here
    private var diffText = ""                   // loaded by /diff
    private var isBusy = false
    private var pendingUser: String?
    private var currentAssistant: String?
    private var assistantLineIndex: Int?
    private var sessionTokens = 0
    private var spinnerFrame = 0
    private var lastSHA: String?               // most recent pre-turn snapshot (for /diff)
    private var sessionTurns: [SessionFile.Turn] = []   // completed turns (user+assistant pairs), persisted
    private var modelChoices: [ModelConfig]?   // non-nil while the /model picker is open
    private var pendingPermission: (PermissionRequest, CheckedContinuation<PermissionDecision, Never>)?
    private var turnTask: Task<Void, Never>?
    private var running = true
    private var needsRender = true
    private var lastRender = DispatchTime.now()
    private var channel: AsyncStream<AppEvent>.Continuation?
    private var winch: DispatchSourceSignal?

    private static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    init(size: Size, engine: Engine, modelName: String, framework: String, verbose: Bool,
         theme: ANSITheme = .midnight, resume: SessionFile? = nil) {
        self.size = size
        self.engine = engine
        self.modelName = modelName
        self.framework = framework
        self.verbose = verbose
        self.theme = theme
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
                text: "forge — beskriv hvad du vil bygge og tryk Enter. Ctrl-C afbryder/afslutter."))
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
        ws.setEventHandler { cont.yield(.resize(currentTerminalSize())) }
        ws.resume()
        winch = ws
        defer {
            turnTask?.cancel()
            if let (_, c) = pendingPermission { pendingPermission = nil; c.resume(returning: .deny) }
            keyTask.cancel(); tickTask.cancel(); ws.cancel(); cont.finish()
        }

        render(force: true)
        for await ev in stream {
            switch ev {
            case .key(let k):           handle(k)
            case .resize(let s):        size = s; prev = nil; needsRender = true
            case .tick:                 if isBusy { spinnerFrame += 1; needsRender = true }
            case .agent(let e):         applyAgent(e)
            case .permission(let r, let c): pendingPermission = (r, c); status = "Tilladelse kræves"; needsRender = true
            case .turnSnapshot(let sha): lastSHA = sha
            case .diffLoaded(let d):    diffText = d; sidePane = .diff; status = "Diff"; needsRender = true
            case .modelsLoaded(let ms): modelChoices = Array(ms.prefix(9)); status = "Vælg model (1–\(min(ms.count, 9))) · Esc"; needsRender = true
            case .restored(let n, let ok): applyRestore(n, ok)
            case .turnEnded:            endTurn()
            }
            if !running { break }
            if needsRender { render() }
        }
    }

    // MARK: - Input

    private func handle(_ key: Key) {
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
                sidePane = (sidePane == .live) ? .info : (sidePane == .info ? .diff : .live)
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
        guard !text.isEmpty, !isBusy, let cont = channel else { return }
        input = ""; cursor = 0; scroll = 0
        transcript.append(Line(role: .user, text: text))
        pendingUser = text
        liveFile = nil; liveBuffer = ""
        isBusy = true; status = "Tænker…"; spinnerFrame = 0
        let engine = self.engine
        let prior = history
        turnTask = Task {
            // Snapshot the pre-turn state first, so /diff + /undo (P9/P11) can compare.
            if let sha = await engine.checkpoints.snapshot(label: text) { cont.yield(.turnSnapshot(sha)) }
            let gate = TUIPermissionGate(channel: cont)
            let loop = AgentLoop(makeDeps(engine, mode: .build, gate: gate))
            for await ev in loop.run(userPrompt: text, history: prior, mode: .build) { cont.yield(.agent(ev)) }
            cont.yield(.turnEnded)
        }
        needsRender = true
    }

    private func cancelTurn() {
        turnTask?.cancel(); turnTask = nil
        if let (_, c) = pendingPermission { pendingPermission = nil; c.resume(returning: .deny) }
        isBusy = false; status = "Afbrudt."
        pendingUser = nil; currentAssistant = nil; assistantLineIndex = nil
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
        pendingUser = nil; currentAssistant = nil; assistantLineIndex = nil
        isBusy = false
        if status.hasPrefix("Tænker") || status.hasPrefix("…") { status = "Klar." }
        turnTask = nil
        needsRender = true
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
            status = Self.label(for: s)
            if case .failed(let why) = s { transcript.append(Line(role: .error, text: "✗ \(why.prefix(200))")) }
        case .assistantText(let t):
            if assistantLineIndex == nil {
                transcript.append(Line(role: .assistant, text: ""))
                assistantLineIndex = transcript.count - 1
                currentAssistant = ""
            }
            currentAssistant = (currentAssistant ?? "") + t
            if let i = assistantLineIndex, transcript.indices.contains(i) { transcript[i].text = currentAssistant ?? "" }
        case .fileWriting(let path):
            liveFile = path; liveBuffer = ""                 // start streaming into the side pane
        case .fileChunk(let path, let text):
            if path == liveFile { liveBuffer += text }
        case .fileWritten(let path):
            if liveFile != path { liveFile = path }          // line-replace edits may not stream chunks
            transcript.append(Line(role: .system, text: "✎ \(path)"))
        case .previewReady(let url):
            transcript.append(Line(role: .system, text: "→ preview: \(url.absoluteString)"))
            status = "kører · \(url.absoluteString)"
        case .metrics(let m):
            sessionTokens += m.totalTokens
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

    private func render(force: Bool = false) {
        let now = DispatchTime.now()
        if !force {
            let ms = Double(now.uptimeNanoseconds &- lastRender.uptimeNanoseconds) / 1_000_000
            if ms < 16 { needsRender = true; return }
        }
        lastRender = now
        needsRender = false

        let layout = ForgeLayout.compute(size)
        let buf = ScreenBuffer(size: size)

        // Header
        buf.fill(layout.header, " ", dimStyle)
        var hx = buf.text("⬢ forge", x: layout.header.x, y: layout.header.y, accentBold)
        hx = buf.text("  ·  \(modelName)", x: hx, y: layout.header.y, dimStyle, clip: layout.header)

        // Transcript
        let vis = transcriptVisualLines(width: max(1, layout.transcript.w))
        let h = layout.transcript.h
        let maxScroll = max(0, vis.count - h)
        if scroll > maxScroll { scroll = maxScroll }
        let start = max(0, vis.count - h - scroll)
        for i in 0..<min(h, max(0, vis.count - start)) {
            let (txt, st) = vis[start + i]
            buf.text(txt, x: layout.transcript.x, y: layout.transcript.y + i, st, clip: layout.transcript)
        }

        // Side pane
        if !layout.side.isEmpty { renderSide(buf, layout.side) }

        // Status bar
        buf.fill(layout.status, " ", dimStyle)
        let spin = isBusy ? Self.spinner[spinnerFrame % Self.spinner.count] + " " : ""
        let statusStyle: Style = status.hasPrefix("✗") ? errStyle : (status.hasPrefix("✓") ? okStyle : dimStyle)
        buf.text(spin + status, x: layout.status.x, y: layout.status.y, statusStyle, clip: layout.status)
        var hint = "^C \(isBusy ? "afbryd" : "afslut") · Tab panel · ↑↓ scroll"
        if verbose, sessionTokens > 0 { hint = "\(sessionTokens) tok · " + hint }
        let hintX = max(layout.status.x, layout.status.maxX - TextWidth.width(hint))
        buf.text(hint, x: hintX, y: layout.status.y, dimStyle, clip: layout.status)

        // Input line
        let prompt = "› "
        buf.text(prompt, x: layout.input.x, y: layout.input.y, accent)
        buf.text(input, x: layout.input.x + TextWidth.width(prompt), y: layout.input.y, .default, clip: layout.input)

        // Permission modal (overlay, drawn last)
        var cursorPt: Point? = nil
        if let (req, _) = pendingPermission {
            drawPermissionModal(buf, request: req)
        } else if modelChoices != nil {
            drawModelModal(buf)
        } else {
            if input.hasPrefix("/") { drawSlashMenu(buf, anchor: layout.slashAnchor) }   // discovery popover
            let before = String(input.prefix(cursor))
            let curX = min(layout.input.x + TextWidth.width(prompt) + TextWidth.width(before), layout.input.maxX - 1)
            cursorPt = Point(x: curX, y: layout.input.y)
        }

        TUIOutput.emit(TUIRenderer.renderDiff(old: prev, new: buf, cursor: cursorPt))
        prev = buf
    }

    private func drawPermissionModal(_ buf: ScreenBuffer, request: PermissionRequest) {
        let label = request.label
        let w = min(size.cols - 4, max(40, TextWidth.width(label) + 6))
        let h = 6
        let x = (size.cols - w) / 2
        let y = (size.rows - h) / 2
        let rect = Rect(x: x, y: y, w: w, h: h)
        buf.fill(rect, " ", .default)
        buf.box(rect, warnStyle, title: "Tilladelse")
        buf.text(TextWidth.truncate(label, toWidth: w - 4), x: x + 2, y: y + 2, .default, clip: rect)
        buf.text("[J]a   [A]ltid i session   [N]ej", x: x + 2, y: y + 4, accent, clip: rect)
    }

    private func drawModelModal(_ buf: ScreenBuffer) {
        guard let choices = modelChoices else { return }
        let w = min(size.cols - 4, 66)
        let h = min(size.rows - 2, choices.count + 4)
        let x = (size.cols - w) / 2, y = (size.rows - h) / 2
        let rect = Rect(x: x, y: y, w: w, h: h)
        buf.fill(rect, " ", .default)
        buf.box(rect, accentBold, title: "Vælg model")
        for (i, m) in choices.enumerated() where y + 1 + i < y + h - 1 {
            let src = m.source == .cloud ? "cloud" : (m.source == .ollama ? "ollama" : "lm studio")
            let cost = m.source == .cloud ? "" : " · gratis"
            let cur = m.id == engine.config.id ? " ✓" : ""
            let line = "\(i + 1))  \(m.displayName)  ·  \(src)\(cost)\(cur)"
            buf.text(TextWidth.truncate(line, toWidth: w - 4), x: x + 2, y: y + 1 + i, .default, clip: rect)
        }
        buf.text("tal vælger · Esc annullerer", x: x + 2, y: y + h - 1, dimStyle, clip: rect)
    }

    /// The side pane: the live-streaming file (syntax-highlighted, with a gutter), or
    /// an info card. Tab toggles which one is shown while a file is streaming.
    private func renderSide(_ buf: ScreenBuffer, _ rect: Rect) {
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
        default:
            buf.box(rect, dimStyle, title: "Info")
            let inner = rect.inset(1); guard inner.h > 0 else { return }
            buf.text("model: \(modelName)", x: inner.x + 1, y: inner.y, dimStyle, clip: inner)
            buf.text("Tab skifter panel", x: inner.x + 1, y: inner.y + 2, dimStyle, clip: inner)
            buf.text("/diff efter et build", x: inner.x + 1, y: inner.y + 3, dimStyle, clip: inner)
            if !userTurns.isEmpty { buf.text("\(userTurns.count) checkpoint(s)", x: inner.x + 1, y: inner.y + 4, dimStyle, clip: inner) }
        }
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
        case "theme":      switchTheme(arg)
        case "init":       writeAgentsFile()
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
        ("/theme", "skift farvetema"),
        ("/init", "skriv AGENTS.md"),
        ("/help", "vis kommandoer"),
        ("/quit", "afslut"),
    ]

    private func switchTheme(_ arg: String) {
        if arg.isEmpty {
            let names = ANSITheme.all.map { $0.name.lowercased() }.joined(separator: " · ")
            transcript.append(Line(role: .system, text: "temaer: \(names)  (nu: \(theme.name.lowercased()))"))
        } else if let t = ANSITheme.named(arg) {
            theme = t; prev = nil                                   // force a full repaint in the new colors
            var c = ForgeConfig.load(); c.theme = t.name; c.save()  // remember the choice
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

    /// Discovery popover above the input while typing a / command.
    private func drawSlashMenu(_ buf: ScreenBuffer, anchor: Rect) {
        let matches = Self.slashCommands.filter { $0.0.hasPrefix(input.lowercased()) }
        guard !matches.isEmpty, anchor.h >= 3 else { return }
        let h = min(anchor.h, matches.count + 2), w = min(anchor.w, 46)
        let rect = Rect(x: anchor.x, y: anchor.maxY - h, w: w, h: h)
        buf.fill(rect, " ", .default)
        buf.box(rect, accent, title: "kommandoer")
        for (i, c) in matches.prefix(h - 2).enumerated() {
            buf.text(TextWidth.truncate("\(c.0)  \(c.1)", toWidth: w - 4),
                     x: rect.x + 2, y: rect.y + 1 + i, i == 0 ? accentBold : dimStyle, clip: rect)
        }
    }

    private func shortName(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }

    private func transcriptVisualLines(width: Int) -> [(String, Style)] {
        var out: [(String, Style)] = []
        for line in transcript {
            let style: Style
            let prefix: String
            switch line.role {
            case .user:      style = accentBold; prefix = "› "
            case .assistant: style = .default;   prefix = ""
            case .system:    style = dimStyle;   prefix = "· "
            case .error:     style = errStyle;   prefix = ""
            }
            let body = line.text.isEmpty && line.role == .assistant ? "…" : line.text
            for w in TextWidth.wrap(prefix + body, width: width) { out.append((w, style)) }
            if line.role == .assistant || line.role == .error { out.append(("", .default)) }
        }
        return out
    }
}
