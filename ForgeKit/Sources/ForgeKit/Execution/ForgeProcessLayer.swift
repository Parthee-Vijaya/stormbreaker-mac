import Foundation

/// Concrete `ProcessLayer` backed by a `ProjectWorkspace` (file writes) and a
/// `DevServerManager` (commands + dev server).
public actor ForgeProcessLayer: ProcessLayer {
    private let workspace: ProjectWorkspace
    private let devServer: DevServerManager

    public init(workspace: ProjectWorkspace, devServer: DevServerManager) {
        self.workspace = workspace
        self.devServer = devServer
    }

    public func writeFile(_ relativePath: String, contents: String) async throws {
        try await workspace.writeFile(relativePath, contents: contents)
    }

    public func readFile(_ relativePath: String) async throws -> String {
        try await workspace.readFile(relativePath)
    }

    public func addDependencies(_ packages: [String]) async throws {
        guard !packages.isEmpty else { return }
        let command = "npm install " + packages.joined(separator: " ")
        let code = try await runToExit(command)
        if code != 0 { throw DevServerError.installFailed(exitCode: code, tail: []) }
    }

    @discardableResult
    public func runShell(_ command: String) async throws -> Int32 {
        try await runToExit(command)
    }

    @discardableResult
    public func startDevServerIfNeeded() async throws -> URL {
        if let url = await devServer.serverReadyURL { return url }
        return try await devServer.start()
    }

    public var serverReadyURL: URL? {
        get async { await devServer.serverReadyURL }
    }

    private func runToExit(_ command: String) async throws -> Int32 {
        let (events, _) = try await devServer.runShellCommand(command)
        var code: Int32 = -1
        for await event in events {
            if case .exited(let exitCode) = event { code = exitCode }
        }
        return code
    }
}
