import SwiftUI
import AppKit

/// Code view: a file tree + an editable monospace editor. Edits auto-save and
/// Vite HMR refreshes the preview.
struct CodePane: View {
    var body: some View {
        HSplitView {
            FileTreeView().frame(minWidth: 170, idealWidth: 220, maxWidth: 300)
            CodeEditorView().frame(minWidth: 300)
        }
        .background(Theme.canvas)
    }
}

fileprivate func fileIcon(_ path: String) -> String {
    if path.hasSuffix(".tsx") || path.hasSuffix(".ts") { "curlybraces" }
    else if path.hasSuffix(".css") { "paintbrush" }
    else if path.hasSuffix(".json") { "doc.badge.gearshape" }
    else if path.hasSuffix(".html") { "chevron.left.forwardslash.chevron.right" }
    else { "doc" }
}

/// Editor tab strip — one tab per open file, click to switch, × to close.
private struct EditorTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(model.openTabs, id: \.self) { tab($0) }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 32)
        .background(Theme.sidebar)
    }

    private func tab(_ path: String) -> some View {
        let active = model.selectedFile == path
        return HStack(spacing: 6) {
            Image(systemName: fileIcon(path)).font(.system(size: 10))
                .foregroundStyle(active ? Theme.accent : Theme.inkFaint)
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(active ? Theme.ink : Theme.inkSoft).lineLimit(1)
            Button { model.closeTab(path) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.inkFaint).frame(width: 14, height: 14)
            }
            .buttonStyle(.plain).help("Luk fane")
        }
        .padding(.leading, 9).padding(.trailing, 4).padding(.vertical, 6)
        .background(active ? Theme.canvas : .clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(active ? Theme.accent : .clear).frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { if !active { Task { await model.openFile(path) } } }
    }
}

private struct FileTreeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                // B17: quick access to the project's .env editor (creates it if missing).
                Button { Task { await model.openEnvEditor() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "key").font(.system(size: 11)).foregroundStyle(Theme.accent)
                            .frame(width: 14)
                        Text("Miljøvariabler")
                            .font(.system(size: 12)).foregroundStyle(Theme.inkSoft)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Rediger .env (miljøvariabler) for appen")
                Divider().overlay(Theme.border).padding(.vertical, 3)
                ForEach(model.projectFiles, id: \.self) { path in
                    Button { Task { await model.openFile(path) } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: fileIcon(path))
                                .font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                                .frame(width: 14)
                            Text(path)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(model.selectedFile == path ? Theme.ink : Theme.inkSoft)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(model.selectedFile == path ? Theme.fill : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .background(Theme.sidebar)
        // A15: arrow-key file navigation when the tree has keyboard focus. (When
        // the editor is focused, these don't fire, so editor arrows are untouched.)
        .focusable()
        .onKeyPress(.upArrow) { model.selectAdjacentFile(-1); return .handled }
        .onKeyPress(.downArrow) { model.selectAdjacentFile(1); return .handled }
        .accessibilityLabel("Fil-træ — pil op/ned skifter fil")
    }
}

private struct CodeEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if !model.openTabs.isEmpty {
                EditorTabBar()
                Divider().overlay(Theme.border)
            }
            HStack(spacing: 8) {
                Text(model.selectedFile ?? "No file selected")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.inkSoft)
                if model.isStreamingFile {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("writing…").font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                } else if model.editorDirty {
                    Circle().fill(Theme.inkFaint).frame(width: 6, height: 6)
                }
                Spacer()
                Button { copyCode() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                        Text(copied ? "Kopieret" : "Kopiér").font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.plain).foregroundStyle(copied ? Theme.positive : Theme.inkSoft)
                .disabled(model.selectedFile == nil)
                Button { Task { await model.saveNow() } } label: {
                    Text("Save").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.inkSoft)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.selectedFile == nil || model.isStreamingFile)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.sidebar)
            Divider().overlay(Theme.border)

            if model.selectedFile == nil {
                VStack { Spacer(); Text("Select a file to edit").foregroundStyle(Theme.inkFaint); Spacer() }
                    .frame(maxWidth: .infinity)
            } else {
                CodeTextView(text: $model.editorText, autoScroll: model.isStreamingFile,
                             diagnosticLines: model.diagnosticLines(for: model.selectedFile))
                    .background(Theme.canvas)
                    .onChange(of: model.editorText) { model.onEditorChange() }
            }
        }
        .background(Theme.canvas)
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.editorText, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.3)); copied = false }
    }
}

/// An NSTextView-backed editor: monospace, with smart quotes/dashes/autocorrect
/// DISABLED so typed code stays valid (SwiftUI's TextEditor smart-quotes input,
/// which corrupts JSX). Undo enabled.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var autoScroll: Bool = false
    var diagnosticLines: Set<Int> = []   // Fase 2a: 1-based lines with build/type errors

    func makeNSView(context: Context) -> NSView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let editorBG = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: 0x0F1117) : .white }
        let editorFG = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: 0xE6E8EE) : NSColor(hex: 0x14151A) }
        textView.textColor = editorFG
        textView.insertionPointColor = NSColor(hex: 0x7C6CFF)
        textView.backgroundColor = editorBG
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = text
        SyntaxHighlighter.apply(to: textView)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = editorBG
        context.coordinator.textView = textView

        // Line-number gutter (+ active-line) — redrawn on scroll, edit, and caret move.
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.ruler = ruler
        ruler.errorLines = diagnosticLines
        Self.applyDiagnostics(diagnosticLines, to: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        let nc = NotificationCenter.default
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.refreshRuler),
                       name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.refreshRuler),
                       name: NSTextView.didChangeSelectionNotification, object: textView)

        // Minimap pinned to the right of the editor (VS Code-style overview).
        let minimap = MinimapView(textView: textView)
        context.coordinator.minimap = minimap
        return EditorContainer(scroll: scrollView, minimap: minimap)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            if autoScroll {
                // Live-typing: keep the caret + viewport at the end as code streams in.
                let end = NSRange(location: (text as NSString).length, length: 0)
                textView.setSelectedRange(end)
                textView.scrollRangeToVisible(end)
            }
            context.coordinator.scheduleHighlight()
            context.coordinator.minimap?.needsDisplay = true
        }
        // Re-apply diagnostics (errors may have changed even when text didn't).
        Self.applyDiagnostics(diagnosticLines, to: textView)
        if context.coordinator.ruler?.errorLines != diagnosticLines {
            context.coordinator.ruler?.errorLines = diagnosticLines
        }
    }

    /// Fase 2a: red dotted underline (display-only temporary attributes) under each
    /// line that has a build/type error. Independent of the syntax-highlight layer.
    static func applyDiagnostics(_ lines: Set<Int>, to textView: NSTextView) {
        guard let lm = textView.layoutManager else { return }
        let ns = textView.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        guard !lines.isEmpty, ns.length > 0 else { return }
        var lineNo = 1, idx = 0
        while idx < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: idx, length: 0))
            if lines.contains(lineNo) {
                var r = lineRange   // drop trailing newline so the underline hugs the code
                if r.length > 0, ns.character(at: r.location + r.length - 1) == 0x0A { r.length -= 1 }
                if r.length > 0 {
                    lm.addTemporaryAttributes(
                        [.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                         .underlineColor: NSColor.systemRed],
                        forCharacterRange: r)
                }
            }
            lineNo += 1
            idx = lineRange.location + lineRange.length
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        weak var textView: NSTextView?
        weak var ruler: LineNumberRulerView?
        weak var minimap: MinimapView?
        private var highlightWork: DispatchWorkItem?

        init(text: Binding<String>) { self.text = text }

        @objc func refreshRuler() { ruler?.refresh() }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            scheduleHighlight()
            ruler?.refresh()
        }

        /// Debounced re-highlight (coalesces rapid edits + streamed chunks).
        func scheduleHighlight() {
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let tv = self?.textView else { return }
                SyntaxHighlighter.apply(to: tv)
            }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }
}

/// A lightweight regex syntax highlighter for the code editor. Applies only
/// foreground colors to the NSTextView's textStorage (never edits the text, so
/// the caret/undo are untouched). Tuned for TS/JSX; dark + light palettes.
enum SyntaxHighlighter {
    private static func dyn(_ light: Int, _ dark: Int) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light) }
    }
    private static let fg      = dyn(0x14151A, 0xE6E8EE)
    private static let keyword = dyn(0x7C3AED, 0xC792EA)
    private static let typeC   = dyn(0x2563EB, 0x82AAFF)
    private static let number  = dyn(0xC2410C, 0xF78C6C)
    private static let string  = dyn(0x16A34A, 0xC3E88D)
    private static let comment = dyn(0x9AA0AE, 0x6B7180)

    private static let keywordRE = try! NSRegularExpression(pattern:
        "\\b(const|let|var|function|return|if|else|for|while|do|import|export|from|default|class|extends|new|async|await|try|catch|finally|throw|switch|case|break|continue|type|interface|enum|public|private|protected|readonly|static|void|null|undefined|true|false|this|super|in|of|as|typeof|instanceof|yield|get|set)\\b")
    private static let typeRE = try! NSRegularExpression(pattern: "\\b[A-Z][A-Za-z0-9_]*\\b")
    private static let numberRE = try! NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b")
    private static let stringRE = try! NSRegularExpression(pattern: "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|`(?:\\\\.|[^`\\\\])*`")
    private static let commentRE = try! NSRegularExpression(pattern: "//[^\\n]*|/\\*[\\s\\S]*?\\*/")

    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard ns.length < 200_000 else { return }   // skip very large files
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: full)
        storage.addAttribute(.foregroundColor, value: fg, range: full)
        colorize(typeRE, ns, full, storage, typeC)
        colorize(keywordRE, ns, full, storage, keyword)
        colorize(numberRE, ns, full, storage, number)
        colorize(stringRE, ns, full, storage, string)     // override matches inside strings
        colorize(commentRE, ns, full, storage, comment)   // comments win last
        storage.endEditing()
    }

    private static func colorize(_ re: NSRegularExpression, _ ns: NSString,
                                 _ full: NSRange, _ storage: NSTextStorage, _ color: NSColor) {
        re.enumerateMatches(in: ns as String, range: full) { match, _, _ in
            if let r = match?.range { storage.addAttribute(.foregroundColor, value: color, range: r) }
        }
    }
}

/// Left gutter that draws line numbers aligned with the editor's lines. Only the
/// first fragment of each logical line is numbered (wrapped lines don't renumber),
/// and the caret's line is highlighted in the accent colour.
final class LineNumberRulerView: NSRulerView {
    weak var codeView: NSTextView?
    var errorLines: Set<Int> = [] { didSet { if errorLines != oldValue { needsDisplay = true } } }   // Fase 2a

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.codeView = textView
        clientView = textView
        ruleThickness = 44
    }
    required init(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func refresh() { needsDisplay = true }

    private static func dyn(_ light: Int, _ dark: Int) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light) }
    }
    private let gutterBG = dyn(0xF4F4F7, 0x0C0E14)
    private let numColor = dyn(0x9A9AA4, 0x6B7180)
    private let activeColor = NSColor(hex: 0x7C6CFF)
    private let errorColor = NSColor.systemRed

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = codeView, let lm = textView.layoutManager,
              let tc = textView.textContainer, let clip = scrollView?.contentView else { return }
        gutterBG.setFill()
        bounds.fill()

        let content = textView.string as NSString
        let inset = textView.textContainerInset.height
        let visibleRect = clip.bounds
        let glyphRange = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
        let firstChar = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location

        var lineNumber = 1 + countNewlines(content, upTo: firstChar)
        let caret = textView.selectedRange().location
        let activeLine = 1 + countNewlines(content, upTo: min(caret, content.length))

        let base = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)

        lm.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
            let charStart = lm.characterRange(forGlyphRange: fragGlyphRange, actualGlyphRange: nil).location
            let isParaStart = charStart == 0 || content.character(at: charStart - 1) == 0x0A
            guard isParaStart else { return }
            let active = lineNumber == activeLine
            let isError = self.errorLines.contains(lineNumber)
            let label = "\(lineNumber)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: (active || isError) ? bold : base,
                .foregroundColor: isError ? self.errorColor : (active ? self.activeColor : self.numColor),
            ]
            let size = label.size(withAttributes: attrs)
            let y = fragRect.minY + inset - visibleRect.minY + (fragRect.height - size.height) / 2
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 8, y: y), withAttributes: attrs)
            lineNumber += 1
        }
    }

    private func countNewlines(_ s: NSString, upTo idx: Int) -> Int {
        var count = 0, i = 0
        let end = min(idx, s.length)
        while i < end { if s.character(at: i) == 0x0A { count += 1 }; i += 1 }
        return count
    }
}

/// A condensed overview of the file: one faint bar per line (width ∝ content
/// length, x ∝ indentation) plus a translucent viewport indicator. Click/drag to
/// jump. Approximates VS Code's minimap without rendering glyphs, so it's cheap;
/// skipped for very large files.
final class MinimapView: NSView {
    weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(redraw), name: NSText.didChangeNotification, object: textView)
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            nc.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override var isFlipped: Bool { true }   // y grows downward → line index maps straight to y
    @objc private func redraw() { needsDisplay = true }

    private static func dyn(_ light: Int, _ dark: Int) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light) }
    }
    private let bgColor = dyn(0xF4F4F7, 0x0C0E14)
    private let barColor = dyn(0xC4C4CE, 0x3A4150)
    private let viewportColor = NSColor(hex: 0x7C6CFF).withAlphaComponent(0.16)

    override func draw(_ dirtyRect: NSRect) {
        bgColor.setFill(); bounds.fill()
        guard let tv = textView else { return }
        let s = tv.string as NSString
        guard s.length > 0, s.length < 400_000 else { return }

        let lines = Self.scanLines(s)
        let count = max(lines.count, 1)
        let rowH = max(0.8, min(3.0, bounds.height / CGFloat(count)))
        let charW = max(0.7, (bounds.width - 6) / 90.0)

        for (i, line) in lines.enumerated() where line.len > 0 {
            let x = 3 + CGFloat(line.indent) * charW
            let w = min(bounds.width - x - 2, CGFloat(line.len) * charW)
            guard w > 0 else { continue }
            barColor.setFill()
            NSRect(x: x, y: CGFloat(i) * rowH, width: w, height: max(0.8, rowH - 0.6)).fill()
        }

        if let clip = tv.enclosingScrollView?.contentView, let lm = tv.layoutManager, let tc = tv.textContainer {
            let totalH = lm.usedRect(for: tc).height
            guard totalH > 0 else { return }
            let lineH = totalH / CGFloat(count)
            guard lineH > 0 else { return }
            let visible = clip.bounds
            let first = max(0, visible.minY / lineH)
            let last = min(CGFloat(count), visible.maxY / lineH)
            viewportColor.setFill()
            NSRect(x: 0, y: first * rowH, width: bounds.width, height: max(rowH, (last - first) * rowH)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) { jump(event) }
    override func mouseDragged(with event: NSEvent) { jump(event) }

    private func jump(_ event: NSEvent) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer,
              let clip = tv.enclosingScrollView?.contentView else { return }
        let s = tv.string as NSString
        let count = max(Self.scanLines(s).count, 1)
        let rowH = max(0.8, min(3.0, bounds.height / CGFloat(count)))
        let line = max(0, min(count - 1, Int(convert(event.locationInWindow, from: nil).y / rowH)))
        let lineH = lm.usedRect(for: tc).height / CGFloat(count)
        let clipH = clip.bounds.height
        tv.scrollToVisible(NSRect(x: 0, y: max(0, CGFloat(line) * lineH - clipH / 2), width: 1, height: clipH))
        needsDisplay = true
    }

    /// One (indent, content-length) pair per line — a single linear pass.
    private static func scanLines(_ s: NSString) -> [(indent: Int, len: Int)] {
        var result: [(indent: Int, len: Int)] = []
        var indent = 0, contentLen = 0, seenNonSpace = false
        var i = 0
        while i < s.length {
            let c = s.character(at: i)
            if c == 0x0A {
                result.append((indent, contentLen))
                indent = 0; contentLen = 0; seenNonSpace = false
            } else if !seenNonSpace, c == 0x20 || c == 0x09 {
                indent += (c == 0x09 ? 2 : 1)
            } else {
                seenNonSpace = true; contentLen += 1
            }
            i += 1
        }
        result.append((indent, contentLen))
        return result
    }
}

/// Lays out the editor scroll view with the minimap pinned to the right.
final class EditorContainer: NSView {
    private let scroll: NSScrollView
    private let minimap: MinimapView
    private let minimapWidth: CGFloat = 74

    init(scroll: NSScrollView, minimap: MinimapView) {
        self.scroll = scroll; self.minimap = minimap
        super.init(frame: .zero)
        addSubview(scroll); addSubview(minimap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        let w = max(0, bounds.width - minimapWidth)
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
        minimap.frame = NSRect(x: w, y: 0, width: minimapWidth, height: bounds.height)
    }
}
