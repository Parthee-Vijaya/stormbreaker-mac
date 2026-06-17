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
    private var onboarding = false             // first-run welcome + theme picker
    private var onboardThemeIdx = 0
    private var pendingPermission: (PermissionRequest, CheckedContinuation<PermissionDecision, Never>)?
    private var turnTask: Task<Void, Never>?
    private var running = true
    private var needsRender = true
    private var lastRender = DispatchTime.now()
    private var channel: AsyncStream<AppEvent>.Continuation?
    private var winch: DispatchSourceSignal?

    private static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    init(size: Size, engine: Engine, modelName: String, framework: String, verbose: Bool,
         theme: ANSITheme = .midnight, resume: SessionFile? = nil, firstRun: Bool = false) {
        self.size = size
        self.engine = engine
        self.modelName = modelName
        self.framework = framework
        self.verbose = verbose
        self.theme = theme
        if firstRun {
            onboarding = true
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

    private var base: Style { theme.base }
    private static let logo = ["█▀▀ █▀█ █▀█ █▀▀ █▀▀", "█▀▀ █ █ █▀▄ █▄█ █▀▀", "▀   ▀▀▀ ▀ ▀ ▀▀▀ ▀▀▀"]

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
        buf.text("⬢ forge", x: r.x + 1, y: r.y, theme.accentBold)
        var right = modelName
        if sessionTokens > 0 { right += "  ·  \(fmtTok(sessionTokens)) tok" }
        buf.text(right, x: max(r.x + 10, r.maxX - TextWidth.width(right) - 1), y: r.y, theme.dimStyle, clip: r)
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
        let spin = isBusy ? Self.spinner[spinnerFrame % Self.spinner.count] + " " : "▍ "
        let st: Style = status.hasPrefix("✗") ? errStyle : (status.hasPrefix("✓") ? okStyle : (isBusy ? theme.accentStyle : theme.dimStyle))
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

    private func handleOnboardingKey(_ key: Key) {
        switch key {
        case .left:
            onboardThemeIdx = (onboardThemeIdx - 1 + ANSITheme.all.count) % ANSITheme.all.count
            theme = ANSITheme.all[onboardThemeIdx]; prev = nil; needsRender = true
        case .right:
            onboardThemeIdx = (onboardThemeIdx + 1) % ANSITheme.all.count
            theme = ANSITheme.all[onboardThemeIdx]; prev = nil; needsRender = true
        case .enter, .escape:
            finishOnboarding()
        default: break
        }
    }

    private func finishOnboarding() {
        onboarding = false
        var c = ForgeConfig.load(); c.onboarded = true; c.theme = theme.name; c.save()
        transcript.append(Line(role: .system, text: "Tema: \(theme.name). Skriv hvad du vil bygge og tryk Enter — / for kommandoer."))
        prev = nil; needsRender = true
    }

    private func drawOnboarding(_ buf: ScreenBuffer) {
        let r = Rect(x: 0, y: 0, w: size.cols, h: size.rows)
        func cx(_ s: String) -> Int { max(0, (size.cols - TextWidth.width(s)) / 2) }
        let greet = "Velkommen til forge"
        let modelLine = "Model:   \(modelName)   ·   skift med /model"
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
                out.append(("▌ forge", theme.on(theme.accent, dim: true)))
                for w in TextWidth.wrap(line.text.isEmpty ? "…" : line.text, width: bodyWidth) { out.append(("  " + w, base)) }
                out.append(("", base))
            case .system:
                for w in TextWidth.wrap(line.text, width: bodyWidth) { out.append(("  " + w, dimStyle)) }
            case .error:
                for w in TextWidth.wrap(line.text, width: bodyWidth) { out.append(("  " + w, errStyle)) }
                out.append(("", base))
            }
        }
        return out
    }
}
