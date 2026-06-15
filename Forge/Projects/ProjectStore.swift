import Foundation
import ForgeKit

/// Persists the project list (index.json) and each project's chat + code under
/// ~/Library/Application Support/Forge/projects/<folder>/.
/// Main-actor isolated: only AppModel (which is @MainActor) touches it, and the
/// `configuredRoot` flag is mutable shared state that Swift 6 requires isolating.
@MainActor
enum ProjectStore {
    /// Set from `Preferences.projectsRoot` at launch / onboarding finish.
    static var configuredRoot: URL?

    static var root: URL {
        let url: URL
        if let configured = configuredRoot {
            url = configured
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            url = base.appendingPathComponent("Forge/projects", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var indexURL: URL { root.appendingPathComponent("index.json") }

    static func loadProjects() -> [Project] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder.iso.decode([Project].self, from: data) else { return [] }
        return list.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func saveProjects(_ projects: [Project]) {
        guard let data = try? JSONEncoder.iso.encode(projects) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    static func dir(for project: Project) -> URL {
        let url = root.appendingPathComponent(project.folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Preview thumbnail (snapshot of the running app) for the project switcher.
    static func thumbnailURL(for project: Project) -> URL {
        root.appendingPathComponent(project.folder, isDirectory: true)
            .appendingPathComponent(".forge/thumb.png")
    }

    private static func chatURL(for project: Project) -> URL {
        dir(for: project).appendingPathComponent(".forge/chat.json")
    }

    static func loadChat(for project: Project) -> [AppModel.UIMessage] {
        guard let data = try? Data(contentsOf: chatURL(for: project)),
              let messages = try? JSONDecoder.iso.decode([AppModel.UIMessage].self, from: data) else { return [] }
        return messages
    }

    static func saveChat(_ messages: [AppModel.UIMessage], for project: Project) {
        let url = chatURL(for: project)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.iso.encode(messages) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func logsURL(for project: Project) -> URL {
        dir(for: project).appendingPathComponent(".forge/logs.json")
    }

    /// Dev-server console history, persisted so it survives a project switch
    /// (runtime JS errors aren't persisted — the live preview re-reports them on
    /// reload, so persisting would risk a stale "Fix it").
    static func loadLogs(for project: Project) -> [LogLine] {
        guard let data = try? Data(contentsOf: logsURL(for: project)),
              let lines = try? JSONDecoder.iso.decode([LogLine].self, from: data) else { return [] }
        return lines
    }

    static func saveLogs(_ lines: [LogLine], for project: Project) {
        let url = logsURL(for: project)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Cap what we persist so the file stays small.
        let trimmed = Array(lines.suffix(200))
        guard let data = try? JSONEncoder.iso.encode(trimmed) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func makeProject(name: String) -> Project {
        Project(name: name, folder: "p-" + UUID().uuidString.prefix(8).lowercased())
    }

    static func deleteDir(for project: Project) {
        try? FileManager.default.removeItem(at: dir(for: project))
    }

    /// Whether the project already has a generated app (so we can resume it).
    static func hasBuiltApp(_ project: Project) -> Bool {
        FileManager.default.fileExists(
            atPath: dir(for: project).appendingPathComponent("src/App.tsx").path)
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
}
