import SwiftUI
import ForgeKit

/// The launch screen (shown before a build starts): a left sidebar with the
/// secondary entry points (clone, tutorial, example, recent projects) and a
/// prompt-first main area with a personalized greeting. Once a build starts
/// (`hasStarted`), ContentView swaps to the chat + preview layout, so the
/// sidebar falls away — the build gets the full width.
struct StartScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showName = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            sidebar(model)
                .frame(width: 224)
                .background(Theme.sidebar)
            Divider().overlay(Theme.border)
            main(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.light)
        .onAppear { if model.shouldAskPreferredName { showName = true } }
        .sheet(isPresented: $showName) { NamePromptView() }
        .sheet(isPresented: $model.showCloneDialog) { CloneDialogView() }
        .sheet(isPresented: $model.showGlossary) { GlossaryView() }
    }

    // MARK: - Sidebar

    private func sidebar(_ model: AppModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Theme.accent).frame(width: 9, height: 9)
                Text("Forge").font(Theme.wordmark(18)).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 12)

            Button { model.newProject() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    Text("Nyt projekt").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusM))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)

            sectionLabel("KOM I GANG").padding(.top, 18)
            SidebarRow(title: "Klon fra Git", icon: "arrow.triangle.branch") { model.showCloneDialog = true }
            SidebarRow(title: "Start tutorial", icon: "graduationcap") { model.startTutorial() }
            SidebarRow(title: "Prøv et eksempel", icon: "sparkles") { model.tryExample() }

            sectionLabel("SENESTE").padding(.top, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(recentProjects(model)) { project in
                        SidebarRow(title: project.name.isEmpty ? "Untitled" : project.name,
                                   icon: "folder") { model.switchTo(project) }
                    }
                }
            }

            Spacer(minLength: 8)
            Divider().overlay(Theme.border)
            HStack { ModelPicker(model: model); Spacer(minLength: 0) }
                .padding(.horizontal, 10).padding(.vertical, 10)
        }
    }

    private func recentProjects(_ model: AppModel) -> [Project] {
        Array(model.projects.filter { $0.id != model.currentProject.id }.prefix(8))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkFaint)
            .padding(.horizontal, 14).padding(.bottom, 6)
    }

    // MARK: - Main

    private func main(_ model: AppModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if model.preferences.learningMode {
                    Button { model.showGlossary = true } label: { Image(systemName: "book") }
                        .buttonStyle(IconButtonStyle())
                        .help("Ordbog — forklaring af fagudtryk")
                }
            }
            .padding(14)
            Spacer()
            VStack(spacing: 20) {
                Text(model.startGreeting)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Composer(
                    text: Bindable(model).draft,
                    placeholder: model.chatMode == .plan
                        ? "Beskriv hvad jeg skal planlægge…"
                        : "Beskriv din app — eller klon et repo i sidebaren…",
                    isBusy: model.isBusy,
                    autofocus: true,
                    mode: Bindable(model).chatMode,
                    images: model.attachedImages,
                    onAttach: { model.attachImagesFromPicker() },
                    onRemoveImage: { model.removeAttachedImage(at: $0) },
                    onDropImages: { model.attachImages(at: $0) },
                    onSubmit: { model.submit() }
                )
                .frame(maxWidth: 560)
            }
            .padding(.horizontal, 28)
            Spacer()
            Spacer()
        }
    }
}

/// A hoverable sidebar action row.
private struct SidebarRow: View {
    let title: String
    let icon: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.inkSoft).frame(width: 18)
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(hovering ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
    }
}

/// First-run popup that asks how the user wants to be addressed.
private struct NamePromptView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hvad skal jeg kalde dig?")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Bruges når Forge hilser på dig — fx “Hvad vil du bygge, P?”. Du kan altid ændre det i Indstillinger.")
                    .font(.system(size: 13)).foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("fx P", text: $name)
                .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Theme.ink).tint(Theme.accent)
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusM).strokeBorder(Theme.border))
                .onSubmit(save)
            HStack {
                Button("Spring over") { model.skipPreferredNamePrompt(); dismiss() }
                    .buttonStyle(.plain).foregroundStyle(Theme.inkFaint)
                Spacer()
                Button(action: save) {
                    Text("Gem").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(width: 380)
        .preferredColorScheme(.light)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { model.skipPreferredNamePrompt() } else { model.setPreferredName(trimmed) }
        dismiss()
    }
}

/// Dialog for cloning a Git repository into a new project.
private struct CloneDialogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Klon fra Git")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Indsæt en repo-URL. Forge kloner den til et nyt projekt og starter den, hvis det er et Node/Vite-projekt.")
                    .font(.system(size: 13)).foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("https://github.com/bruger/repo", text: $model.cloneURL)
                .textFieldStyle(.plain).font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.ink).tint(Theme.accent)
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusM).strokeBorder(Theme.border))
                .onSubmit { model.cloneFromGit() }
            HStack {
                Button("Annuller") { dismiss() }
                    .buttonStyle(.plain).foregroundStyle(Theme.inkFaint)
                Spacer()
                Button { model.cloneFromGit() } label: {
                    Text("Klon").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.cloneURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .preferredColorScheme(.light)
    }
}
