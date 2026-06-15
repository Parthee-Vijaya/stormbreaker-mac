import Foundation

/// Resolves the absolute path to Node tooling (node/npm/npx/pnpm/bun).
///
/// GUI apps launched from Finder inherit only a minimal launchd PATH, so tools
/// cannot be found by name. We probe the user's login-shell PATH (catches
/// nvm/volta/asdf/fnm shims) and a list of known install locations. Stateless
/// and `Sendable`; callers should cache the result because resolution shells
/// out (~100–300 ms).
public struct NodeResolver: Sendable {
    public enum Tool: String, Sendable, CaseIterable {
        case node, npm, npx, pnpm, bun
    }

    /// `UserDefaults` key holding a manual absolute path to `node` (optional).
    public static let overrideDefaultsKey = "ForgeNodePath"

    public static let shared = NodeResolver()
    public init() {}

    /// Resolve one tool to its absolute executable URL, or throw with the full
    /// list of paths searched (so the UI can tell the user exactly where Forge
    /// looked).
    public func resolve(_ tool: Tool) throws -> URL {
        if tool == .node,
           let override = UserDefaults.standard.string(forKey: Self.overrideDefaultsKey),
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let dirs = searchDirectories()
        for dir in dirs {
            let candidate = dir.appendingPathComponent(tool.rawValue)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw DevServerError.nodeRuntimeNotFound(
            searched: dirs.map { $0.appendingPathComponent(tool.rawValue).path }
        )
    }

    /// Directory containing `node`. Prepend this to a child process's PATH so
    /// npm/npx can re-spawn `node` by name.
    public func nodeBinDirectory() throws -> URL {
        try resolve(.node).deletingLastPathComponent()
    }

    /// Ordered, de-duplicated list of directories to search (login-shell PATH
    /// first, then known locations).
    public func searchDirectories() -> [URL] {
        var dirs: [String] = loginShellPATH()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        dirs += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.volta/bin",
            "\(home)/.bun/bin",
            "\(home)/.asdf/shims",
        ]
        if let nvm = newestNVMBin(home: home) { dirs.append(nvm) }
        dirs += ["/usr/bin", "/bin"]

        var seen = Set<String>()
        var result: [URL] = []
        for dir in dirs where !dir.isEmpty && seen.insert(dir).inserted {
            result.append(URL(fileURLWithPath: dir))
        }
        return result
    }

    // MARK: - Probes

    private func loginShellPATH() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -i interactive + -l login so .zprofile/.zshrc run and shims appear.
        process.arguments = ["-ilc", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            // A hanging shell init (.zshrc waiting on network, stuck nvm/starship)
            // would otherwise block readToEnd() forever — terminate after 5s so the
            // resolver falls back to the well-known candidate paths instead.
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            watchdog.cancel()
            let out = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return out.split(separator: ":").map(String.init)
        } catch {
            return []
        }
    }

    private func newestNVMBin(home: String) -> String? {
        let versionsDir = "\(home)/.nvm/versions/node"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: versionsDir),
              !entries.isEmpty else { return nil }
        let newest = entries.sorted { compareVersions($0, $1) == .orderedDescending }.first
        return newest.map { "\(versionsDir)/\($0)/bin" }
    }

    private func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.drop(while: { !$0.isNumber }).split(separator: ".").compactMap { Int($0) }
        let pb = b.drop(while: { !$0.isNumber }).split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let va = i < pa.count ? pa[i] : 0
            let vb = i < pb.count ? pb[i] : 0
            if va != vb { return va < vb ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
