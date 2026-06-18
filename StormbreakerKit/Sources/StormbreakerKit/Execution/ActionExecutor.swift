import Foundation

/// Applies `ParserEvent`s to the project in order: writes files as they close
/// (write-as-you-go), coalesces `add-dependency` into a single install, runs
/// shell commands, and starts the dev server exactly once. Source edits never
/// restart the server — Vite HMR owns them — so a stray `start` while the
/// server is up is ignored.
public actor ActionExecutor {
    private let process: any ProcessLayer
    private let gate: (any PermissionGate)?
    private var pendingDeps: [String] = []
    private var pendingShell: [String] = []
    private var startRequested = false
    private var filesWritten: [String] = []
    private var deniedActions: [String] = []

    public init(process: any ProcessLayer, gate: (any PermissionGate)? = nil) {
        self.process = process
        self.gate = gate
    }

    /// Process one event in stream order.
    public func handle(_ event: ParserEvent) async throws {
        switch event {
        case .fileClose(let path, let contents):
            try await process.writeFile(path, contents: contents)
            filesWritten.append(path)
        case .lineReplaceClose(let path, let edits):
            let original = try await process.readFile(path)
            let updated = try Self.apply(edits, to: original, path: path)
            try await process.writeFile(path, contents: updated)
            filesWritten.append(path)
        case .inlineAction(.addDependency(let package)):
            pendingDeps.append(package)
        case .inlineAction(.shell(let command)):
            pendingShell.append(command)
        case .inlineAction(.start):
            startRequested = true
        case .artifactClose:
            try await flush()
        case .text, .artifactOpen, .fileOpen, .fileChunk, .lineReplaceOpen,
             .readRequest, .mcpRequest, .inlineAction(.file), .inlineAction(.lineReplace):
            break   // .mcpRequest is handled by the AgentLoop tool-round, not the executor
        }
    }

    /// Apply search/replace edits to a file's contents, in order. All-or-nothing:
    /// if any SEARCH block isn't found, throws WITHOUT a partial write so the file
    /// is never left half-edited (the loop surfaces the failure for a retry).
    static func apply(_ edits: [LineEdit], to original: String, path: String) throws -> String {
        var content = original
        var missing: [String] = []
        for edit in edits where !edit.search.isEmpty {
            if let range = content.range(of: edit.search) {
                content.replaceSubrange(range, with: edit.replace)
            } else {
                missing.append(edit.search)
            }
        }
        if !missing.isEmpty { throw LineReplaceFailure(path: path, missing: missing) }
        return content
    }

    /// Run queued commands and start the dev server if needed. Called at
    /// artifact close.
    public func flush() async throws {
        if !pendingDeps.isEmpty {
            if await approved(.addDependencies(pendingDeps)) {
                try await process.addDependencies(pendingDeps)
            } else {
                deniedActions.append(PermissionRequest.addDependencies(pendingDeps).label)
            }
            pendingDeps.removeAll()
        }
        for command in pendingShell {
            // Per-command triage: safe dev tooling runs without a prompt, catastrophic
            // patterns are refused outright, the rest fall through to the gate.
            switch ShellRules.classify(command) {
            case .allow:
                _ = try await process.runShell(command)
            case .deny:
                deniedActions.append("blokerede en potentielt farlig kommando: \(command)")
            case .ask:
                if await approved(.shell(command: command)) {
                    _ = try await process.runShell(command)
                } else {
                    deniedActions.append(PermissionRequest.shell(command: command).label)
                }
            }
        }
        pendingShell.removeAll()

        let running = await process.serverReadyURL != nil
        if !running {
            _ = try await process.startDevServerIfNeeded()
        }
        // Already running → do nothing: HMR applies file edits and Vite picks up
        // newly-installed deps on the next import/reload.
        startRequested = false
    }

    public var writtenFiles: [String] { filesWritten }

    /// Labels of actions the user declined this turn (fed back to the model so it
    /// adapts instead of retrying).
    public var denied: [String] { deniedActions }

    /// True unless a gate is present and returns `.deny`.
    private func approved(_ request: PermissionRequest) async -> Bool {
        guard let gate else { return true }
        return await gate.decide(request) != .deny
    }
}

/// Thrown when a line-replace edit's SEARCH block doesn't match the file, so the
/// turn fails cleanly (and legibly) instead of writing a corrupted file.
public struct LineReplaceFailure: Error, CustomStringConvertible {
    public let path: String
    public let missing: [String]
    public var description: String {
        "line-replace on \(path): \(missing.count) search block(s) not found. "
        + "Re-emit the file with a `file` action, or match the current contents exactly."
    }
}
