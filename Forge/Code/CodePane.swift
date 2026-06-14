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
        textView.textColor = NSColor(white: 0.08, alpha: 1)
        textView.backgroundColor = .white
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
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
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        weak var textView: NSTextView?

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
