import Foundation

/// Tracks the dev-server PID in `<project>/.forge/devserver.pid` so a process
/// left behind (if Stormbreaker and its watchdog both died) can be reclaimed on the
/// next launch. `Sendable` value type.
public struct ProcessSupervisor: Sendable {
    public let pidFileURL: URL
    public let projectRoot: URL

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot.standardizedFileURL
        self.pidFileURL = projectRoot.appendingPathComponent(".forge/devserver.pid")
    }

    public func record(pid: Int32) {
        try? FileManager.default.createDirectory(
            at: pidFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(pid)".write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// If a stale PID file points at a live process that looks like our dev
    /// server, terminate it. Verified via `ps` before signalling so we don't
    /// kill an unrelated process that reused the PID.
    public func reclaimOrphan() {
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        defer { clear() }
        guard kill(pid, 0) == 0 else { return }          // not alive
        guard processLooksLikeOurs(pid) else { return }   // not ours — leave it
        kill(pid, SIGTERM)
        usleep(500_000)
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// Global orphan sweep: terminate dev-server processes left behind by a
    /// previous Stormbreaker session, across ALL projects under `projectsRoot`. Meant
    /// for app launch, when no Stormbreaker dev server is running yet — so every match
    /// is a leftover (from a crash, or a watchdog that didn't fire) still holding
    /// a port. To stay safe it matches ONLY processes whose full command line
    /// references the Stormbreaker projects directory AND looks like a dev server (a
    /// `vite` process or the `storm-run.sh` wrapper) — an editor that merely has
    /// a project open is never touched. SIGTERM first (so the wrapper's trap can
    /// reap its child subtree), then SIGKILL any straggler.
    public static func reclaimAllOrphans(under projectsRoot: URL) {
        let needle = projectsRoot.standardizedFileURL.path
        guard needle.count > 1 else { return }   // never sweep on "/" or empty
        let pids = devServerPIDs(referencing: needle)
        guard !pids.isEmpty else { return }
        let me = getpid()
        for pid in pids where pid != me { kill(pid, SIGTERM) }
        usleep(700_000)
        for pid in pids where pid != me {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    /// PIDs of running processes whose full command line contains `needle` (the
    /// Stormbreaker projects path) plus a dev-server marker. `ps -axww` gives full argv.
    private static func devServerPIDs(referencing needle: String) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,command="]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)

        var pids: [Int32] = []
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let sep = line.firstIndex(of: " "),
                  let pid = Int32(line[..<sep]) else { continue }
            let command = String(line[line.index(after: sep)...])
            guard command.contains(needle) else { continue }
            let lower = command.lowercased()
            guard lower.contains("vite") || lower.contains("storm-run.sh") else { continue }
            pids.append(pid)
        }
        return pids
    }

    private func processLooksLikeOurs(_ pid: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "command=", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            let command = String(decoding: data, as: UTF8.self)
            // Require a dev-server marker OR this project's path. A bare "node"
            // match was too broad — after PID reuse it could kill an unrelated
            // node process that inherited the recorded PID.
            return command.contains("vite")
                || command.contains("storm-run.sh")
                || command.contains(projectRoot.path)
        } catch {
            return false
        }
    }
}
