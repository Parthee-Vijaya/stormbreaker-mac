import Foundation

/// Loads/saves `Preferences` to ~/Library/Application Support/Forge/preferences.json.
enum PreferencesStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("preferences.json")
    }

    static func load() -> Preferences {
        guard let data = try? Data(contentsOf: fileURL),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        return prefs
    }

    static func save(_ preferences: Preferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
