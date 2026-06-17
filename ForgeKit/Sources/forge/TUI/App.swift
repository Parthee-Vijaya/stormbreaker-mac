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

    private let engine: Engine
    private let modelName: String
    private let verbose: Bool
    private var size: Size
    private var prev: ScreenBuffer?

    private var transcript: [Line] = []
    private var history: [ChatMessage] = []
    private var input = ""
    private var cursor = 0
    private var scroll = 0
    private var status = "Klar."
    private var sideTitle = "Info"
    private var isBusy = false
    private var pendingUser: String?
    private var currentAssistant: String?
    private var assistantLineIndex: Int?
    private var sessionTokens = 0
    private var spinnerFrame = 0
    private var turnSHAs: [String] = []        // pre-turn checkpoint SHAs (for /diff + /undo, P9/P11)
    private var pendingPermission: (PermissionRequest, CheckedContinuation<PermissionDecision, Never>)?
    private var turnTask: Task<Void, Never>?
    private var running = true
    private var needsRender = true
    private var lastRender = DispatchTime.now()
    private var channel: AsyncStream<AppEvent>.Continuation?
    private var winch: DispatchSourceSignal?

    private static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    init(size: Size, engine: Engine, modelName: String, verbose: Bool, theme: ANSITheme = .midnight) {
        self.size = size
        self.engine = engine
        self.modelName = modelName
        self.verbose = verbose
        self.theme = theme
        transcript.append(Line(role: .system,
            text: "forge — beskriv hvad du vil bygge og tryk Enter. Ctrl-C afbryder/afslutter."))
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
            case .turnSnapshot(let sha): turnSHAs.append(sha)
            case .turnEnded:            endTurn()
            }
            if !running { break }
            if needsRender { render() }
        }
    }

    // MARK: - Input

    private func handle(_ key: Key) {
        if pendingPermission != nil { handlePermissionKey(key); return }
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
        case .tab:   sideTitle = sideTitle == "Info" ? "Kode" : "Info"; needsRender = true
        case .enter: if !isBusy { submit() }
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
        if let user = pendingUser { history.append(ChatMessage(role: .user, content: user)) }
        if let a = currentAssistant, !a.isEmpty { history.append(ChatMessage(role: .assistant, content: a)) }
        pendingUser = nil; currentAssistant = nil; assistantLineIndex = nil
        isBusy = false
        if status.hasPrefix("Tænker") || status.hasPrefix("…") { status = "Klar." }
        turnTask = nil
        needsRender = true
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
        case .fileWritten(let path):
            transcript.append(Line(role: .system, text: "✎ \(path)"))
        case .previewReady(let url):
            transcript.append(Line(role: .system, text: "→ preview: \(url.absoluteString)"))
            status = "kører · \(url.absoluteString)"
        case .metrics(let m):
            sessionTokens += m.totalTokens
        case .reasoning, .fileWriting, .fileChunk, .usage:
            break                                            // .fileWriting/.fileChunk surface in phase 8
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
        if !layout.side.isEmpty {
            buf.box(layout.side, dimStyle, title: sideTitle)
            buf.text("(Tab skifter · diff/kode kommer)", x: layout.side.x + 2, y: layout.side.y + 2, dimStyle, clip: layout.side)
        }

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
        } else {
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
