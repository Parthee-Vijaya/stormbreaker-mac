import SwiftUI
import ForgeKit

/// The prompt input — used both on the empty-state hero and in the chat panel.
/// Enter sends, Shift+Enter inserts a newline. Text is explicitly inked so it's
/// always visible.
struct Composer: View {
    @Binding var text: String
    var placeholder: String
    var isBusy: Bool
    var autofocus: Bool = false
    var mode: Binding<AgentLoop.Mode>? = nil
    var onSubmit: () -> Void
    var onStop: (() -> Void)? = nil

    @FocusState private var focused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let mode { ModeToggle(mode: mode) }
            inputRow
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusL))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusL)
                .strokeBorder(focused ? Theme.borderStrong : Theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        .onAppear { if autofocus { focused = true } }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .tint(Theme.accent)
                .lineLimit(1...8)
                .focused($focused)
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    if canSend { onSubmit() }
                    return .handled
                }

            if isBusy, let onStop {
                Button(action: onStop) {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 30, height: 30)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Stop generation")
            } else {
                Button(action: onSubmit) {
                    Group {
                        if isBusy {
                            ProgressView().controlSize(.small).tint(Theme.onAccent)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.onAccent)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .background(canSend || isBusy ? Theme.accent : Theme.borderStrong, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
            }
        }
    }
}

/// Plan / Build segmented toggle for the composer. Plan mode makes the agent
/// propose a plan + ask questions instead of writing code.
struct ModeToggle: View {
    @Binding var mode: AgentLoop.Mode

    var body: some View {
        HStack(spacing: 2) {
            segment("Build", .build, icon: "hammer")
            segment("Plan", .plan, icon: "list.bullet.clipboard")
        }
        .padding(2)
        .background(Theme.fill, in: Capsule())
    }

    private func segment(_ title: String, _ value: AgentLoop.Mode, icon: String) -> some View {
        let selected = mode == value
        return Button { mode = value } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? Theme.onAccent : Theme.inkSoft)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(selected ? Theme.accent : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Clarifying questions from plan mode, rendered as tappable option chips.
struct QuestionChips: View {
    let questions: [PlanQuestion]
    var disabled: Bool
    var onAnswer: (PlanQuestion, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 5) {
                        Image(systemName: "questionmark.circle").font(.system(size: 11))
                        Text(question.question).font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.ink)
                    FlowLayout(spacing: 6) {
                        ForEach(question.options, id: \.self) { option in
                            Button { onAnswer(question, option) } label: {
                                Text(option)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .background(Theme.fill, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(disabled)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Compact model selector, grouped by source (Ollama / LM Studio / Cloud) with
/// a colored dot per source and a Refresh action.
struct ModelPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            sourceSection(.ollama, "Ollama")
            sourceSection(.lmStudio, "LM Studio")
            sourceSection(.cloud, "Cloud")
            Divider()
            Button { Task { await model.refreshModels() } } label: {
                Label("Refresh models", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(Self.dotColor(model.selectedModel.source)).frame(width: 6, height: 6)
                Text(model.selectedModel.displayName)
                    .font(.system(size: 12)).foregroundStyle(Theme.inkSoft)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 170)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.inkFaint)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.fill, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    @ViewBuilder
    private func sourceSection(_ source: ModelConfig.Source, _ title: String) -> some View {
        let items = model.availableModels.filter { $0.source == source }
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { config in
                    Button { model.selectedModelID = config.id } label: {
                        if config.id == model.selectedModelID {
                            Label(config.displayName, systemImage: "checkmark")
                        } else {
                            Text(config.displayName)
                        }
                    }
                }
            }
        }
    }

    static func dotColor(_ source: ModelConfig.Source) -> Color {
        switch source {
        case .ollama: Theme.positive
        case .lmStudio: Color.purple
        case .cloud: Color.blue
        }
    }
}

/// Small monospace file pill shown under an assistant message.
struct FileChip: View {
    let path: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text").font(.system(size: 10))
            Text(path).font(.system(size: 11, design: .monospaced))
        }
        .foregroundStyle(Theme.inkSoft)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Project switcher: lists projects, switch, new, delete current.
struct ProjectMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.projects) { project in
                Button { model.switchTo(project) } label: {
                    if project.id == model.currentProject.id {
                        Label(displayName(project), systemImage: "checkmark")
                    } else {
                        Text(displayName(project))
                    }
                }
            }
            Divider()
            Button { model.newProject() } label: { Label("New project", systemImage: "plus") }
            if model.hasStarted {
                Button { model.openInEditor() } label: {
                    Label("Open in editor", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button { model.revealInFinder() } label: { Label("Reveal in Finder", systemImage: "folder") }
                Button { model.exportZip() } label: { Label("Export as Zip…", systemImage: "archivebox") }
            }
            if model.projects.count > 1 {
                Divider()
                Button(role: .destructive) {
                    model.deleteProject(model.currentProject)
                } label: {
                    Label("Delete “\(displayName(model.currentProject))”", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(displayName(model.currentProject))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 170)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.inkFaint)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.fill, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(model.isBusy)
    }

    private func displayName(_ project: Project) -> String {
        project.name.isEmpty ? "Untitled" : project.name
    }
}
