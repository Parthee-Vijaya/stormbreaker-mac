import SwiftUI
import AppKit
import ForgeKit

/// The launch screen (shown before a build starts): a left sidebar with the
/// secondary entry points (clone, tutorial, example, recent projects) and a
/// prompt-first main area with a personalized greeting. Once a build starts
/// (`hasStarted`), ContentView swaps to the chat + preview layout, so the
/// sidebar falls away — the build gets the full width.
struct StartScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showName = false
    @State private var showDashboard = false   // C11: project dashboard grid

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
        .preferredColorScheme(model.colorScheme)
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if model.tourActive {
                    TourOverlay(resolved: anchors.mapValues { proxy[$0] }, size: proxy.size)
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: model.tourActive)
        .onAppear { if model.shouldAskPreferredName { showName = true } }
        .sheet(isPresented: $showName) { NamePromptView() }
        .sheet(isPresented: $model.showCloneDialog) { CloneDialogView() }
        .sheet(isPresented: $model.showLinkDialog) { LinkDialogView() }
        .sheet(isPresented: $model.showGlossary) { GlossaryView() }
    }

    // MARK: - Sidebar

    private func sidebar(_ model: AppModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ForgeBadge(size: 22)
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
            SidebarRow(title: "Importér bundle", icon: "square.and.arrow.down") { model.importBundle() }
            SidebarRow(title: "Kopiér design fra link", icon: "link") { model.showLinkDialog = true }
            SidebarRow(title: "Start tutorial", icon: "graduationcap") { model.startTutorial() }
            SidebarRow(title: "Prøv et eksempel", icon: "sparkles") { model.tryExample() }
            SidebarRow(title: "Alle projekter", icon: "square.grid.2x2") { showDashboard = true }

            sectionLabel("SENESTE").padding(.top, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(recentProjects(model)) { project in
                        RecentProjectRow(project: project) { model.switchTo(project) }
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
        // Only worked-on projects (a project is renamed off "Untitled" on its
        // first prompt), so unused empty canvases don't clutter the list.
        Array(model.projects
            .filter { $0.id != model.currentProject.id && !$0.name.isEmpty && $0.name != "Untitled" }
            .prefix(8))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkFaint)
            .padding(.horizontal, 14).padding(.bottom, 6)
    }

    // MARK: - Main

    @ViewBuilder
    private func main(_ model: AppModel) -> some View {
        if showDashboard { dashboard(model) } else { launchMain(model) }
    }

    private func launchMain(_ model: AppModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if model.preferences.learningMode {
                    Button { model.showGlossary = true } label: { Image(systemName: "book") }
                        .buttonStyle(IconButtonStyle())
                        .help("Ordbog — forklaring af fagudtryk")
                        .accessibilityLabel("Ordbog")
                        .tourAnchor(.glossary)
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
                    onAttachLink: { model.showLinkDialog = true },
                    isCapturing: model.isCapturing,
                    isEnhancing: model.isEnhancing,
                    onEnhance: { model.enhancePrompt() },
                    onSubmit: { model.submit() }
                )
                .frame(maxWidth: 560)
                .tourAnchor(.composer)

                HStack(spacing: 8) {
                    Text("Framework").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkFaint)
                    Picker("", selection: Bindable(model).selectedFramework) {
                        Text("React").tag("react")
                        Text("Svelte").tag("svelte")
                        Text("Vue").tag("vue")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
                }
                .tourAnchor(.framework)

                templateGallery(model)
                    .tourAnchor(.templates)
            }
            .padding(.horizontal, 28)
            Spacer()
        }
    }

    // MARK: - Template gallery (B6)

    private func templateGallery(_ model: AppModel) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Rectangle().fill(Theme.border).frame(height: 1)
                Text("ELLER START FRA EN SKABELON")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.inkFaint)
                    .fixedSize()
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(StarterTemplates.all) { template in
                    TemplateCard(template: template) { model.startFromTemplate(template) }
                        .disabled(model.isBusy)
                }
            }
        }
        .frame(maxWidth: 600)
        .padding(.top, 8)
    }

    // MARK: - Project dashboard (C11)

    private func dashboard(_ model: AppModel) -> some View {
        let projects = model.projects.filter { !$0.name.isEmpty && $0.name != "Untitled" }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { showDashboard = false } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Tilbage").font(.system(size: 13))
                    }.foregroundStyle(Theme.inkSoft)
                }.buttonStyle(.plain)
                Spacer()
                Text("Dine projekter").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button { showDashboard = false; model.newProject() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("Nyt").font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Theme.accent, in: Capsule())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Divider().overlay(Theme.border)
            if projects.isEmpty {
                Spacer()
                Text("Ingen projekter endnu — byg dit første fra forsiden.")
                    .font(.system(size: 13)).foregroundStyle(Theme.inkFaint)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16)], spacing: 16) {
                        ForEach(projects) { project in
                            DashboardCard(project: project) { showDashboard = false; model.switchTo(project) }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    /// Localised "for 2 timer siden" etc. for the dashboard cards.
    static func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "da")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// A starter-template card on the launch screen: icon, title, one-line subtitle.
/// Clicking it seeds the template's brief and starts a build.
private struct TemplateCard: View {
    let template: StarterTemplate
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: template.icon)
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.accent)
                Text(template.title)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(template.subtitle)
                    .font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .padding(12)
            .background(hovering ? Theme.fillHover : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.radiusM))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusM)
                .strokeBorder(hovering ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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

/// A recent-project row showing a preview thumbnail (falls back to a folder icon
/// before the project's first build is snapshotted).
private struct RecentProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    var action: () -> Void
    @State private var hovering = false
    @State private var thumb: NSImage?
    @State private var confirmDelete = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if let thumb {
                        Image(nsImage: thumb).resizable().scaledToFill()
                    } else {
                        Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Theme.inkSoft)
                    }
                }
                .frame(width: 36, height: 24)
                .background(Theme.fill)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1))
                Text(project.name.isEmpty ? "Untitled" : project.name)
                    .font(.system(size: 13)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(hovering ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
        .task(id: project.id) { thumb = NSImage(contentsOf: ProjectStore.thumbnailURL(for: project)) }
        .contextMenu {
            Button { model.beginRename(project) } label: { Label("Omdøb…", systemImage: "pencil") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Slet", systemImage: "trash") }
        }
        .confirmationDialog("Slet “\(project.name.isEmpty ? "Untitled" : project.name)”?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Slet projekt", role: .destructive) { model.deleteProject(project) }
            Button("Annuller", role: .cancel) {}
        } message: {
            Text("Projektets kode, chat og historik slettes permanent. Dette kan ikke fortrydes.")
        }
    }
}

/// C11: a project dashboard card — larger thumbnail + name + last-edited, with a
/// rename/delete context menu. Opens the project on click.
private struct DashboardCard: View {
    @Environment(AppModel.self) private var model
    let project: Project
    var action: () -> Void
    @State private var hovering = false
    @State private var thumb: NSImage?
    @State private var confirmDelete = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let thumb {
                        Image(nsImage: thumb).resizable().scaledToFill()
                    } else {
                        Image(systemName: "folder").font(.system(size: 22))
                            .foregroundStyle(Theme.inkFaint).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 120).frame(maxWidth: .infinity).clipped().background(Theme.fill)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name.isEmpty ? "Untitled" : project.name)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text("Redigeret \(StartScreen.relativeDate(project.updatedAt))")
                        .font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusM)
                .strokeBorder(hovering ? Theme.borderStrong : Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task(id: project.id) { thumb = NSImage(contentsOf: ProjectStore.thumbnailURL(for: project)) }
        .contextMenu {
            Button { model.beginRename(project) } label: { Label("Omdøb…", systemImage: "pencil") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Slet", systemImage: "trash") }
        }
        .confirmationDialog("Slet “\(project.name.isEmpty ? "Untitled" : project.name)”?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Slet projekt", role: .destructive) { model.deleteProject(project) }
            Button("Annuller", role: .cancel) {}
        } message: {
            Text("Projektets kode, chat og historik slettes permanent. Dette kan ikke fortrydes.")
        }
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
        .preferredColorScheme(model.colorScheme)
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
        .preferredColorScheme(model.colorScheme)
    }
}
