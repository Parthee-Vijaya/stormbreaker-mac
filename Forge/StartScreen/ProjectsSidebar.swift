import SwiftUI
import AppKit
import ForgeKit

/// Toggleable projects sidebar for the working view. Lists every project so the
/// user can switch, rename, or delete them — including a multi-select mode to
/// delete several old projects at once — without leaving the current build.
struct ProjectsSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var pendingDelete: [Project] = []
    @State private var showConfirm = false

    private var sortedProjects: [Project] {
        model.projects.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(sortedProjects) { project in
                        ProjectSidebarRow(
                            project: project,
                            isCurrent: project.id == model.currentProject.id,
                            selecting: selecting,
                            isSelected: selected.contains(project.id),
                            onTap: { tapped(project) },
                            onRename: { model.beginRename(project) },
                            onDelete: { confirm([project]) })
                    }
                }
                .padding(.vertical, 6)
            }

            if selecting && !selected.isEmpty {
                Divider().overlay(Theme.border)
                Button(role: .destructive) {
                    confirm(model.projects.filter { selected.contains($0.id) })
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash").font(.system(size: 12, weight: .semibold))
                        Text("Slet valgte (\(selected.count))").font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                }
                .buttonStyle(.plain)
                .padding(10)
            }
        }
        .frame(width: 248)
        .background(Theme.sidebar)
        .confirmationDialog(confirmTitle, isPresented: $showConfirm, titleVisibility: .visible) {
            Button(pendingDelete.count == 1 ? "Slet projekt" : "Slet \(pendingDelete.count) projekter",
                   role: .destructive) {
                model.deleteProjects(pendingDelete)
                selected.removeAll()
                selecting = false
            }
            Button("Annuller", role: .cancel) {}
        } message: {
            Text("Projektets kode, chat og historik slettes permanent. Dette kan ikke fortrydes.")
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Projekter").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                if model.projects.count > 1 {
                    Button(selecting ? "Færdig" : "Vælg") {
                        selecting.toggle()
                        if !selecting { selected.removeAll() }
                    }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                }
                Button { model.showProjectSidebar = false } label: {
                    Image(systemName: "sidebar.leading")
                }
                .buttonStyle(IconButtonStyle())
                .help("Skjul projekter")
                .accessibilityLabel("Skjul projekter")
            }
            Button { model.newProject() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    Text("Nyt projekt").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusM))
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 10)
    }

    private func tapped(_ project: Project) {
        if selecting {
            if selected.contains(project.id) { selected.remove(project.id) }
            else { selected.insert(project.id) }
        } else {
            model.switchTo(project)
        }
    }

    private func confirm(_ projects: [Project]) {
        guard !projects.isEmpty else { return }
        pendingDelete = projects
        showConfirm = true
    }

    private var confirmTitle: String {
        pendingDelete.count == 1
            ? "Slet “\(model.displayName(pendingDelete[0]))”?"
            : "Slet \(pendingDelete.count) projekter?"
    }
}

/// One row in the projects sidebar: thumbnail, name, current-marker, optional
/// selection checkbox, and a right-click menu for rename / delete.
private struct ProjectSidebarRow: View {
    let project: Project
    let isCurrent: Bool
    let selecting: Bool
    let isSelected: Bool
    var onTap: () -> Void
    var onRename: () -> Void
    var onDelete: () -> Void
    @State private var hovering = false
    @State private var thumb: NSImage?

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                if selecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14)).foregroundStyle(isSelected ? Theme.accent : Theme.inkFaint)
                }
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
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if isCurrent && !selecting {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(hovering || isSelected ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
        .contextMenu {
            Button { onRename() } label: { Label("Omdøb…", systemImage: "pencil") }
            Button(role: .destructive) { onDelete() } label: { Label("Slet", systemImage: "trash") }
        }
        .task(id: project.id) { thumb = NSImage(contentsOf: ProjectStore.thumbnailURL(for: project)) }
    }
}
