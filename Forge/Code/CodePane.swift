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

private struct FileTreeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(model.projectFiles, id: \.self) { path in
                    Button { Task { await model.openFile(path) } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: Self.icon(path))
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
    }

    static func icon(_ path: String) -> String {
        if path.hasSuffix(".tsx") || path.hasSuffix(".ts") { "curlybraces" }
        else if path.hasSuffix(".css") { "paintbrush" }
        else if path.hasSuffix(".json") { "doc.badge.gearshape" }
        else if path.hasSuffix(".html") { "chevron.left.forwardslash.chevron.right" }
        else { "doc" }
    }
}

private struct CodeEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
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
                CodeTextView(text: $model.editorText, autoScroll: model.isStreamingFile)
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

    func makeNSView(context: Context) -> NSScrollView {
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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            if autoScroll {
                // Live-typing: keep the caret + viewport at the end as code streams in.
                let end = NSRange(location: (text as NSString).length, length: 0)
                textView.setSelectedRange(end)
                textView.scrollRangeToVisible(end)
            }
            context.coordinator.scheduleHighlight()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        weak var textView: NSTextView?
        private var highlightWork: DispatchWorkItem?

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            scheduleHighlight()
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
