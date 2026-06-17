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
                if let lesson = model.currentLesson {
                    LessonCard(lesson: lesson) { withAnimation { model.dismissLesson() } }
                }
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
                    SelectionQuickBar(element: element)   // C4: quick style controls for the selection
                }
                if model.canCopyPass {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Button { model.runCopyPass() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "character.bubble").font(.system(size: 10))
                                Text("Dansk copy").font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Theme.fill, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Omskriv al brugervendt tekst til dansk med copy-modellen")
                    }
                }
                Composer(
                    text: $model.draft,
                    placeholder: composerPlaceholder(model),
                    isBusy: model.isBusy,
                    mode: model.selectedElement == nil ? $model.chatMode : nil,
                    images: model.attachedImages,
                    onAttach: { model.attachImagesFromPicker() },
                    onRemoveImage: { model.removeAttachedImage(at: $0) },
                    onDropImages: { model.attachImages(at: $0) },
                    onAttachLink: { model.showLinkDialog = true },
                    isCapturing: model.isCapturing,
                    isEnhancing: model.isEnhancing,
                    onEnhance: model.selectedElement == nil ? { model.enhancePrompt() } : nil,
                    isDictating: model.isDictating,
                    onMic: { model.toggleDictation() },
                    skills: model.loadedSkills,
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
        .sheet(isPresented: $model.showGlossary) { GlossaryView() }
        .sheet(isPresented: $model.showLinkDialog) { LinkDialogView() }
        .sheet(isPresented: $model.showRenameDialog) { RenameDialogView() }
        .sheet(isPresented: $model.showDependencies) { DependenciesView() }
        .sheet(isPresented: $model.showSupabaseDialog) { SupabaseDialogView() }
    }

    private func header(_ model: AppModel) -> some View {
        HStack(spacing: 9) {
            Button { model.showProjectSidebar.toggle() } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(IconButtonStyle())
            .help("Vis/skjul projekter")
            .accessibilityLabel("Vis eller skjul projekter")
            ProjectMenu(model: model)
            Spacer()
            if model.projectTokens > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "number").font(.system(size: 9, weight: .semibold))
                    Text(AppModel.formatTokens(model.projectTokens))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.inkSoft)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Theme.fill, in: Capsule())
                .help(model.tokenTooltip)
            }
            ModelPicker(model: model)
            Button { model.askMode.toggle() } label: {   // B10: read-only "ask about the code"
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 12))
                    .foregroundStyle(model.askMode ? Theme.onAccent : Theme.inkSoft)
                    .frame(width: 30, height: 28)
                    .background(model.askMode ? Theme.accent : Theme.fill,
                                in: RoundedRectangle(cornerRadius: Theme.radiusS))
            }
            .buttonStyle(.plain)
            .help("Spørg om koden (read-only)")
            .accessibilityLabel("Spørg om koden")
            if model.preferences.learningMode {
                Button { model.showGlossary = true } label: {
                    Image(systemName: "book")
                }
                .buttonStyle(IconButtonStyle())
                .help("Ordbog — forklaring af fagudtryk")
                .accessibilityLabel("Ordbog")
            }
            Button { model.showConsole.toggle() } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(IconButtonStyle())
            .help("Dev server console")
            .accessibilityLabel("Dev server-konsol")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.sidebar)
    }

    private func composerPlaceholder(_ model: AppModel) -> String {
        if model.askMode { return "Spørg om koden (read-only)…" }
        if let element = model.selectedElement { return "Change the selected \(element.tag)…" }
        return model.chatMode == .plan ? "Describe what to plan — or type / for commands…"
                                       : "Describe a change — or type / for commands…"
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.messages) { MessageView(message: $0)
                        // C17: new messages fade + rise in (keyed on count, so live
                        // streaming text — same count — never re-triggers it).
                        .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                    if model.isBusy {
                        BuildTimeline(phase: model.phase, serverPhase: model.serverPhase,
                                      hasPreview: model.previewURL != nil)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                    }
                    if let last = model.messages.last, last.role == .assistant,
                       last.isPlan, !last.text.isEmpty, !model.isBusy {
                        BuildPlanButton { model.buildFromPlan() }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
                .animation(Theme.Motion.gentle, value: model.messages.count)   // C17: animate new messages
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

    /// Subtle per-message metrics line: tokens · throughput · TTFT (· kald if >1).
    private static func metricsText(_ m: AppModel.MessageMetrics) -> String {
        var parts = ["\(AppModel.formatTokens(m.totalTokens)) tok"]
        if m.tokensPerSecond > 0 { parts.append(String(format: "%.0f tok/s", m.tokensPerSecond)) }
        if let t = m.firstTTFT { parts.append(String(format: "TTFT %.2fs", t)) }
        if m.calls > 1 { parts.append("\(m.calls) kald") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 36)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.imageDataURLs.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(message.imageDataURLs.enumerated()), id: \.offset) { _, dataURL in
                                if let image = Composer.nsImage(fromDataURL: dataURL) {
                                    Image(nsImage: image)
                                        .resizable().scaledToFill()
                                        .frame(width: 130, height: 96)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10)
                                            .strokeBorder(Theme.border, lineWidth: 1))
                                }
                            }
                        }
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.onAccent)
                            .textSelection(.enabled)
                            .padding(.horizontal, 13).padding(.vertical, 9)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                if !message.reasoning.isEmpty {
                    ThinkingView(reasoning: message.reasoning, answerStarted: !message.text.isEmpty)
                }
                if !message.text.isEmpty {
                    MarkdownView(text: message.text)
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
                if let mm = message.metrics, mm.calls > 0 {
                    Text(Self.metricsText(mm))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.inkFaint)
                        .textSelection(.enabled)
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

}

/// C4: a floating quick-edit toolbar for the visually-selected element. One-tap
/// style controls + a colour picker, all routed through the persistent
/// `applyVisualEdit` path (live DOM edits wouldn't survive an HMR reload).
private struct SelectionQuickBar: View {
    @Environment(AppModel.self) private var model
    let element: AppModel.SelectedElement
    @State private var color = Color.accentColor

    private let quickEdits: [(label: String, icon: String, instruction: String)] = [
        ("Større", "textformat.size.larger", "Gør det valgte element lidt større (skriftstørrelse/padding)."),
        ("Mindre", "textformat.size.smaller", "Gør det valgte element lidt mindre."),
        ("Fed", "bold", "Gør teksten i det valgte element fed."),
        ("Centrér", "text.aligncenter", "Centrér det valgte element."),
        ("Skjul", "eye.slash", "Fjern det valgte element fra siden."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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
            HStack(spacing: 6) {
                ForEach(quickEdits, id: \.label) { item in
                    Button { model.applyVisualEdit(item.instruction) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: item.icon).font(.system(size: 9))
                            Text(item.label).font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(Theme.inkSoft)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain).disabled(model.isBusy)
                    .help("\(item.label) — anvendes via en målrettet redigering")
                }
                ColorPicker("", selection: $color, supportsOpacity: false)
                    .labelsHidden().frame(width: 28, height: 22)
                    .disabled(model.isBusy)
                    .help("Skift farve på det valgte element")
                    .onChange(of: color) { _, newColor in
                        model.applyVisualEdit("Skift farven på det valgte element til \(newColor.hexString).")
                    }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.radiusM))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusM).strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1))
    }
}

private extension Color {
    /// `#RRGGBB` for feeding a concrete colour into a visual-edit instruction.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X",
                      Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
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
