import Foundation

/// Loads `<project>/.forge/.mcp.json`, starts the configured MCP servers, aggregates
/// their tools, and routes the agent's tool calls. Best-effort: a server that fails
/// to start is skipped (its tools just won't be offered). `@unchecked Sendable` via
/// an internal lock guarding the client/tool maps.
public final class MCPManager: @unchecked Sendable {
    public struct ServerConfig: Sendable, Equatable {
        public let name: String
        public let command: String
        public let args: [String]
        public let env: [String: String]
    }

    private let lock = NSLock()
    private var clients: [String: MCPClient] = [:]
    private var tools: [MCPClient.Tool] = []

    public init() {}

    /// Parse `.forge/.mcp.json` (`{"mcpServers": {name: {command, args, env}}}`,
    /// nanocoder-compatible). `${VAR}` in env values is expanded from the environment.
    public static func loadConfig(projectRoot: URL) -> [ServerConfig] {
        let path = projectRoot.appendingPathComponent(".forge/.mcp.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: [String: Any]] else { return [] }
        let environment = ProcessInfo.processInfo.environment
        return servers.compactMap { name, cfg in
            guard let command = cfg["command"] as? String, !command.isEmpty else { return nil }
            var env: [String: String] = [:]
            for (k, v) in (cfg["env"] as? [String: String]) ?? [:] {
                env[k] = expandEnv(v, environment)
            }
            return ServerConfig(name: name, command: command,
                                args: (cfg["args"] as? [String]) ?? [], env: env)
        }
    }

    private static func expandEnv(_ value: String, _ environment: [String: String]) -> String {
        var out = value
        for (k, v) in environment {
            out = out.replacingOccurrences(of: "${\(k)}", with: v)
        }
        return out
    }

    /// Start every configured server and collect its tools (best-effort, concurrent).
    public func start(projectRoot: URL) async {
        let configs = Self.loadConfig(projectRoot: projectRoot)
        await withTaskGroup(of: (MCPClient, [MCPClient.Tool])?.self) { group in
            for cfg in configs {
                group.addTask {
                    let client = MCPClient(server: cfg.name, command: cfg.command,
                                           args: cfg.args, env: cfg.env, cwd: projectRoot)
                    do {
                        try await client.start()
                        return (client, try await client.listTools())
                    } catch {
                        client.shutdown(); return nil
                    }
                }
            }
            for await result in group {
                guard let (client, t) = result else { continue }
                lock.withLock { clients[client.server] = client; tools.append(contentsOf: t) }
            }
        }
    }

    public var availableTools: [MCPClient.Tool] {
        lock.withLock { tools }
    }

    public var isEmpty: Bool { availableTools.isEmpty }

    /// A prompt section listing the tools the model may call, and how. Empty when no
    /// MCP servers are configured (so the base prompt is unchanged).
    public func promptSection() -> String? {
        let t = availableTools
        guard !t.isEmpty else { return nil }
        let list = t.map { "- `\($0.server)` / `\($0.name)`: \($0.description)" }.joined(separator: "\n")
        return """
        EXTERNAL TOOLS (MCP): you may call these when they help. Emit a tool call as a
        forgeAction and STOP — the result is fed back to you, then you continue:
        <forgeAction type="mcp" server="<server>" tool="<tool>">{ "arg": "value" }</forgeAction>
        Available:
        \(list)
        """
    }

    public func call(server: String, tool: String, arguments: [String: Any]) async -> String {
        let client = lock.withLock { clients[server] }
        guard let client else { return "Fejl: ukendt MCP-server '\(server)'." }
        do { return try await client.call(tool: tool, arguments: arguments) }
        catch { return "Fejl ved \(server)/\(tool): \(error)" }
    }

    public func shutdownAll() {
        let cs: [MCPClient] = lock.withLock {
            let c = Array(clients.values); clients.removeAll(); tools.removeAll(); return c
        }
        cs.forEach { $0.shutdown() }
    }
}
