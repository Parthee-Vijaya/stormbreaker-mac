import SwiftUI
import ForgeKit

struct ChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header(model)
            Divider().overlay(Theme.border)
            messageList
            if model.showConsole {
                Divider().overlay(Theme.border)
                LogConsoleView().frame(height: 150)
            }
            Divider().overlay(Theme.border)
            VStack(spacing: 8) {
                if model.hasFixableErrors {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(Theme.warning)
                        Text("Runtime error detected")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                        Button { model.fixErrors() } label: {
                            Text("Fix it")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(Theme.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusM))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusM).strokeBorder(Theme.warning.opacity(0.4), lineWidth: 1))
                }
                if let element = model.selectedElement {
                    HStack(spacing: 6) {
                        Image(systemName: "cursorarrow.rays").font(.system(size: 11)).foregroundStyle(Theme.accent)
                        Text(element.text.isEmpty ? element.tag : "\(element.tag) · \(element.text)")
                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.inkSoft)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        Button { model.clearSelection() } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.inkFaint)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.fill, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1))
                }
                Composer(
                    text: $model.draft,
                    placeholder: composerPlaceholder(model),
                    isBusy: model.isBusy,
                    mode: model.selectedElement == nil ? $model.chatMode : nil,
                    onSubmit: {
                        if model.selectedElement != nil { model.applyVisualEdit(model.draft) }
                        else { model.submit() }
                    },
                    onStop: { model.cancelGeneration() }
                )
            }
            .padding(12)
        }
        .background(Theme.sidebar)
    }

    private func header(_ model: AppModel) -> some View {
        HStack(spacing: 9) {
            Circle().fill(Theme.accent).frame(width: 9, height: 9)
            ProjectMenu(model: model)
            Spacer()
            ModelPicker(model: model)
            Button { model.showConsole.toggle() } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(IconButtonStyle())
            .help("Dev server console")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.sidebar)
    }

    private func composerPlaceholder(_ model: AppModel) -> String {
        if let element = model.selectedElement { return "Change the selected \(element.tag)…" }
        return model.chatMode == .plan ? "Describe what to plan…" : "Describe a change…"
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.messages) { MessageView(message: $0) }
                    if model.isBusy { StatusRow(text: model.statusText) }
                    if let last = model.messages.last, last.role == .assistant,
                       last.isPlan, !last.text.isEmpty, !model.isBusy {
                        BuildPlanButton { model.buildFromPlan() }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: model.messages.last?.text) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.isBusy) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

private struct MessageView: View {
    @Environment(AppModel.self) private var model
    let message: AppModel.UIMessage

    @State private var showRestoreConfirm = false
    @State private var diff: DiffPayload?

    private struct DiffPayload: Identifiable { let id = UUID(); let text: String }

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 36)
                Text(message.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.onAccent)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                if !message.reasoning.isEmpty {
                    ThinkingView(reasoning: message.reasoning, answerStarted: !message.text.isEmpty)
                }
                if !message.text.isEmpty {
                    Text(Self.render(message.text))
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if message.reasoning.isEmpty {
                    Text("Working…").font(.system(size: 13.5)).foregroundStyle(Theme.inkFaint)
                }
                if !message.questions.isEmpty {
                    QuestionChips(questions: message.questions, disabled: model.isBusy) { question, option in
                        model.answer(option, to: question)
                    }
                }
                if !message.files.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(message.files, id: \.self) { FileChip(path: $0) }
                    }
                }
                if message.checkpoint != nil, !message.files.isEmpty {
                    HStack(spacing: 14) {
                        Button { Task { diff = DiffPayload(text: await model.diffForTurn(message)) } } label: {
                            Label("View changes", systemImage: "plusminus.circle")
                        }
                        Button { showRestoreConfirm = true } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(model.isBusy)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkFaint)
                    .buttonStyle(.plain)
                }
            }
            .confirmationDialog("Roll back to before this change?",
                                isPresented: $showRestoreConfirm, titleVisibility: .visible) {
                Button("Restore", role: .destructive) { model.restoreCheckpoint(message) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Changes made after this point are discarded.")
            }
            .sheet(item: $diff) { DiffView(diff: $0.text) }
        }
    }

    static func render(_ text: String) -> AttributedString {
        let cleaned = text.replacingOccurrences(
            of: "(?m)^#{1,6}[ \\t]*", with: "", options: .regularExpression)
        if let attributed = try? AttributedString(
            markdown: cleaned,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(cleaned)
    }
}

/// The approve-and-build affordance shown under a finished plan.
private struct BuildPlanButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "hammer.fill").font(.system(size: 12))
                Text("Build this plan").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusM))
        }
        .buttonStyle(.plain)
    }
}

private struct StatusRow: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.inkSoft)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.fill, in: Capsule())
    }
}

/// Collapsible "thinking" disclosure for reasoning models. Auto-expanded while
/// the model is still thinking (no answer yet), auto-collapses once the answer
/// starts — until the user clicks, after which their choice sticks.
private struct ThinkingView: View {
    let reasoning: String
    let answerStarted: Bool
    @State private var override: Bool?

    private var expanded: Bool { override ?? !answerStarted }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { override = !expanded } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain").font(.system(size: 10))
                    Text(answerStarted ? "Thought process" : "Thinking…")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(Theme.inkSoft)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    Text(reasoning)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.inkFaint)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(10)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusM)
                        .strokeBorder(Theme.border, lineWidth: 1)
                        .overlay(Rectangle().fill(Theme.accent.opacity(0.35)).frame(width: 2), alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM))
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
