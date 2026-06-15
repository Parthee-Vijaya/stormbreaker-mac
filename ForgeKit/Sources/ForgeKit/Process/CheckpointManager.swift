import Foundation

/// Per-project checkpoint history backed by an ISOLATED shadow git repo at
/// `<root>/.forge/checkpoints.git`. Every command passes `--git-dir`/`--work-tree`
/// so it never touches the project's own `.git` (which the deploy flow owns) —
/// and `.forge` is already in the template `.gitignore`, so checkpoints are never
/// pushed. Source only: `node_modules`/`dist`/`.forge`/`.git` are excluded, so
/// snapshots are tiny and fast.
public actor CheckpointManager {
    private let root: URL
    private let gitDir: URL
    private static let gitPath = "/usr/bin/git"   // Apple shim; present with CLT/Xcode

    public init(root: URL) {
        self.root = root.standardizedFileURL
        self.gitDir = self.root.appendingPathComponent(".forge/checkpoints.git", isDirectory: true)
    }

    /// Initialize the shadow repo + exclude file once.
    public func ensureRepo() {
        guard !FileManager.default.fileExists(atPath: gitDir.path) else { return }
        try? FileManager.default.createDirectory(
            at: gitDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = runGit(["init", "-q"])
        _ = runGit(["config", "user.email", "forge@local"])
        _ = runGit(["config", "user.name", "Forge"])
        _ = runGit(["config", "commit.gpgsign", "false"])
        let exclude = gitDir.appendingPathComponent("info/exclude")
        try? "node_modules\ndist\n.forge\n.git\n*.local\n".write(to: exclude, atomically: true, encoding: .utf8)
    }

    /// Commit the current working tree and return the new HEAD sha.
    /// `--allow-empty` so every turn gets a stable checkpoint id.
    @discardableResult
    public func snapshot(label: String) -> String? {
        ensureRepo()
        _ = runGit(["add", "-A"])
        _ = runGit(["commit", "--allow-empty", "-q", "-m", label.isEmpty ? "checkpoint" : label])
        let head = runGit(["rev-parse", "HEAD"])
        guard head.status == 0 else { return nil }
        let sha = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Revert the working tree to a snapshot. Untracked source is removed;
    /// ignored paths (`node_modules`) survive. Returns false (without touching the
    /// tree) if the reset fails — otherwise `clean -fd` would still wipe untracked
    /// files even on an invalid sha (data loss).
    @discardableResult
    public func restore(to sha: String) -> Bool {
        ensureRepo()
        guard runGit(["reset", "--hard", sha]).status == 0 else { return false }
        _ = runGit(["clean", "-fd"])
        return true
    }

    /// Unified diff from `from` to `to` (another sha), or to the working tree
    /// when `to` is nil.
    public func diff(from: String, to: String? = nil) -> String {
        ensureRepo()
        let args = to.map { ["diff", from, $0, "--", "."] } ?? ["diff", from, "--", "."]
        return runGit(args).output
    }

    // MARK: - git runner

    private func runGit(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.gitPath)
        process.arguments = ["--git-dir", gitDir.path, "--work-tree", root.path] + args
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"   // never block on credential prompts
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
