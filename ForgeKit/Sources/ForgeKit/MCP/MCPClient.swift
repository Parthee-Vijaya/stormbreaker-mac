import Foundation

public enum MCPError: Error, Sendable, Equatable {
    case closed
    case server(String)
}

/// A minimal Model Context Protocol client over stdio: spawns an MCP server process
/// and speaks newline-delimited JSON-RPC 2.0 to it. Lets Forge's agent USE external
/// tools (filesystem, fetch, git, … — or forge-mcp itself). Sequential request/
/// response on a serial queue, bridged to async; that's enough for tool calls, which
/// the agent awaits one at a time. `@unchecked Sendable` (like RemoteServer) because
/// the serial `queue` is the synchronization point for all process I/O.
public final class MCPClient: @unchecked Sendable {
    public struct Tool: Sendable, Equatable {
        public let server: String
        public let name: String
        public let description: String
    }

    public let server: String
    private let process = Process()
    private let inWrite: FileHandle
    private let outRead: FileHandle
    private let queue: DispatchQueue
    private let idLock = NSLock()
    private var nextID = 1
    private var buffer = Data()

    public init(server: String, command: String, args: [String], env: [String: String], cwd: URL) {
        self.server = server
        self.queue = DispatchQueue(label: "forge.mcp.\(server)")
        let inPipe = Pipe(), outPipe = Pipe()
        inWrite = inPipe.fileHandleForWriting
        outRead = outPipe.fileHandleForReading
        // Login shell so npx/uvx/etc. resolve on PATH even when Forge is a GUI app.
        let full = ([command] + args).joined(separator: " ")
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", full]
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        process.environment = environment
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
    }

    /// Spawn + MCP handshake (initialize → notifications/initialized).
    public func start() async throws {
        try process.run()
        _ = try await rpc("initialize", [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "forge", "version": "0.1.0"],
        ])
        try await notify("notifications/initialized")
    }

    public func listTools() async throws -> [Tool] {
        let result = try await rpc("tools/list", [:])
        let raw = (result as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        return raw.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            return Tool(server: server, name: name, description: t["description"] as? String ?? "")
        }
    }

    /// Call a tool; flattens the MCP `content` array to text (what the model needs).
    public func call(tool: String, arguments: [String: Any]) async throws -> String {
        let result = try await rpc("tools/call", ["name": tool, "arguments": arguments])
        let content = (result as? [String: Any])?["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return text.isEmpty ? "(intet output)" : text
    }

    public func shutdown() {
        try? inWrite.close()
        if process.isRunning { process.terminate() }
    }

    // MARK: - JSON-RPC plumbing (all on `queue`)

    private func nextRequestID() -> Int { idLock.withLock { defer { nextID += 1 }; return nextID } }

    private func rpc(_ method: String, _ params: [String: Any]) async throws -> Any {
        // Encode here (async context) so the @Sendable queue closure only captures
        // Sendable values (Data + Int), not the non-Sendable [String: Any].
        let id = nextRequestID()
        let requestData = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ])
        return try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                do { cont.resume(returning: try sendAndAwait(requestData, id: id)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func notify(_ method: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try writeMessage(["jsonrpc": "2.0", "method": method, "params": [String: Any]()])
                    cont.resume()
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func sendAndAwait(_ requestData: Data, id: Int) throws -> Any {
        inWrite.write(requestData)
        inWrite.write(Data("\n".utf8))
        while true {
            guard let line = readLineSync() else { throw MCPError.closed }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            guard (obj["id"] as? Int) == id else { continue }   // skip notifications / other ids
            if let err = obj["error"] as? [String: Any] {
                throw MCPError.server(String(describing: err["message"] ?? err))
            }
            return obj["result"] ?? [String: Any]()
        }
    }

    private func writeMessage(_ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        inWrite.write(data)
        inWrite.write(Data("\n".utf8))
    }

    /// Read one newline-delimited line from the server (nil at EOF). Runs on `queue`.
    private func readLineSync() -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            let chunk = outRead.availableData   // blocks until data or EOF
            if chunk.isEmpty {
                guard !buffer.isEmpty else { return nil }
                let s = String(data: buffer, encoding: .utf8); buffer.removeAll(); return s
            }
            buffer.append(chunk)
        }
    }
}
