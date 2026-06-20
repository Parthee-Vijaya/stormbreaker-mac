import Foundation
import StormbreakerKit

// B18 — storm-mcp: a Model Context Protocol (MCP) stdio server that lets external
// agents (Claude Code, Cline, nanocoder, or a LangChain/deepagents orchestrator)
// DRIVE a Stormbreaker project. Speaks newline-delimited JSON-RPC 2.0 on stdin/stdout.
// The project root is argv[1] (or the current directory).
//
// Tools:
//  - list_files, read_file (explore) · write_file (create/overwrite)
//  - run_command (shell in the project root: npm install / build / test)
//  - get_errors (tsc --noEmit, classified through Stormbreaker's hardened
//    ErrorClassifier so the agent gets the same deduped errors the app uses)
//  - build — delegate a WHOLE build to Stormbreaker's own self-correcting agent loop
//    (scaffold + write + install + repair) and get a summary back. This makes
//    Stormbreaker a specialized SUB-AGENT inside a larger platform: a deepagents
//    "deep agent" can hand off "build me this app" and stay native underneath.
// Verified by piping JSON-RPC.

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func reply(id: Any, result: [String: Any]) {
    emit(["jsonrpc": "2.0", "id": id, "result": result])
}

func fail(id: Any, code: Int, message: String) {
    emit(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func toolDefinitions() -> [[String: Any]] {
    [
        ["name": "list_files",
         "description": "List the project's source files (node_modules/.git/dist excluded).",
         "inputSchema": ["type": "object", "properties": [String: Any]()]],
        ["name": "read_file",
         "description": "Read a project file's contents.",
         "inputSchema": ["type": "object",
                         "properties": ["path": ["type": "string", "description": "Project-relative path."]],
                         "required": ["path"]]],
        ["name": "write_file",
         "description": "Create or overwrite a project file (path stays inside the project).",
         "inputSchema": ["type": "object",
                         "properties": ["path": ["type": "string", "description": "Project-relative path."],
                                        "contents": ["type": "string", "description": "Full file contents."]],
                         "required": ["path", "contents"]]],
        ["name": "run_command",
         "description": "Run a shell command in the project root (e.g. 'npm install', 'npm run build'). Returns the exit code + combined stdout/stderr.",
         "inputSchema": ["type": "object",
                         "properties": ["command": ["type": "string", "description": "Shell command."]],
                         "required": ["command"]]],
        ["name": "get_errors",
         "description": "Type-check the project (tsc --noEmit) and return deduped, classified build errors, or 'No errors'.",
         "inputSchema": ["type": "object", "properties": [String: Any]()]],
        ["name": "build",
         "description": "Delegate a whole build to Stormbreaker's own agent: it writes a real React/Svelte/Vue/Next.js project from a plain-language prompt, installs it, and self-corrects type/build errors. Scaffolds the framework on an empty project, edits an existing one. Long-running. Returns a summary: files changed, clean/errors, preview URL. (Stormbreaker as a sub-agent.)",
         "inputSchema": ["type": "object",
                         "properties": [
                            "prompt": ["type": "string", "description": "What to build or change, in plain language."],
                            "framework": ["type": "string", "description": "react | svelte | vue | nextjs (only used when scaffolding an empty project). Default react."],
                            "model": ["type": "string", "description": "Override the model id (else uses ~/.config/storm/config.json)."],
                            "provider": ["type": "string", "description": "Override the provider (lmStudio|ollama|openai|anthropic|gemini|openrouter|nvidia)."],
                            "plan": ["type": "boolean", "description": "Only plan (no code written). Default false."]],
                         "required": ["prompt"]]],
    ]
}

func listFiles(root: URL) -> [String] {
    let skip: Set<String> = ["node_modules", ".git", "dist", ".forge", ".next", "out", ".DS_Store"]
    let base = root.resolvingSymlinksInPath()
    let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
    guard let en = FileManager.default.enumerator(
        at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
    var out: [String] = []
    for case let url as URL in en {
        if skip.contains(url.lastPathComponent) { en.skipDescendants(); continue }
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(prefix) else { continue }
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            out.append(String(path.dropFirst(prefix.count)))
        }
    }
    return out.sorted()
}

func readFile(root: URL, path: String) -> String? {
    let target = root.appendingPathComponent(path).standardizedFileURL
    // Refuse to read outside the project root.
    guard target.path.hasPrefix(root.standardizedFileURL.path) else { return nil }
    return try? String(contentsOf: target, encoding: .utf8)
}

func writeFile(root: URL, path: String, contents: String) -> Bool {
    let target = root.appendingPathComponent(path).standardizedFileURL
    guard target.path.hasPrefix(root.standardizedFileURL.path) else { return false }   // stay inside the project
    do {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: target, atomically: true, encoding: .utf8)
        return true
    } catch { return false }
}

/// Run a command via a login shell (so node/npm are on PATH even when launched by a
/// GUI agent), in `dir`, with stdout+stderr merged into one stream.
func runShell(_ command: String, in dir: URL) -> (output: String, code: Int32) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-lc", command]
    proc.currentDirectoryURL = dir
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do { try proc.run() } catch { return ("kunne ikke starte kommando: \(error)", -1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()   // drains as it runs → no deadlock
    proc.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", proc.terminationStatus)
}

func getErrors(root: URL) -> String {
    let (output, _) = runShell("npx tsc --noEmit", in: root)
    let logs = output.split(separator: "\n", omittingEmptySubsequences: true)
        .map { LogLine(stream: .stderr, text: String($0)) }
    let report = ErrorClassifier().report(logs: logs, runtime: [])
    return report.isClean ? "No errors. ✓" : report.formatted()
}

func textResult(id: Any, _ text: String) {
    reply(id: id, result: ["content": [["type": "text", "text": text]]])
}

// MARK: - build tool (run Stormbreaker's own agent loop)

/// `$XDG_CONFIG_HOME/storm` or `~/.config/storm` — same place the CLI reads.
func mcpConfigDir() -> URL {
    let env = ProcessInfo.processInfo.environment
    let base = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
    return base.appendingPathComponent("storm")
}

/// Build a ModelConfig from the build args, falling back to the user's CLI config
/// (`~/.config/storm/config.json`) and the STORM_CLOUD_API_KEY env var.
func resolveModelConfig(_ args: [String: Any]) -> ModelConfig {
    let cfg = (try? Data(contentsOf: mcpConfigDir().appendingPathComponent("config.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    let provider = (args["provider"] as? String) ?? (cfg["provider"] as? String) ?? "lmStudio"
    let model = (args["model"] as? String) ?? (cfg["model"] as? String) ?? "qwen/qwen3.6-35b-a3b"
    let apiKey = (cfg["apiKey"] as? String) ?? ProcessInfo.processInfo.environment["STORM_CLOUD_API_KEY"] ?? ""
    var config: ModelConfig
    switch provider.lowercased() {
    case "openai":     config = .openAI(key: apiKey, model: model)
    case "anthropic":  config = .anthropic(key: apiKey, model: model)
    case "gemini":     config = .gemini(key: apiKey, model: model)
    case "openrouter": config = .openRouter(key: apiKey, model: model)
    case "nvidia":     config = .nvidiaNIM(key: apiKey, model: model)
    case "ollama":     config = .ollama(model: model)
    default:           config = .lmStudio(model: model)
    }
    if let b = (cfg["baseURL"] as? String).flatMap({ URL(string: $0) }) { config.baseURL = b }
    return config
}

/// Run one turn of Stormbreaker's agent loop on `prompt` and return a text summary.
/// Mirrors the CLI's build wiring (scaffold if empty, dev server for HMR/runtime
/// errors, self-correcting loop), then shuts the dev server down — no human gate,
/// since an external agent is driving (ShellRules' catastrophic floor still holds).
func runBuild(root: URL, prompt: String, framework: Framework, config: ModelConfig, plan: Bool) async -> String {
    let workspace = ProjectWorkspace(root: root)
    var scaffolded = false
    if !FileManager.default.fileExists(atPath: root.appendingPathComponent("package.json").path), !plan {
        try? await TemplateInstaller().install(framework.template, into: workspace)
        scaffolded = true
    }
    let devServer = DevServerManager(workspace: workspace)
    let collector = ErrorCollector(devServer: devServer)
    let processLayer = StormbreakerProcessLayer(workspace: workspace, devServer: devServer)
    var systemPrompt = plan ? SystemPrompt.plan : SystemPrompt.storm(lineReplace: config.supportsLineReplace)
    if let rules = RulesLoader.read(projectRoot: root) { systemPrompt += "\n\n" + rules }

    let deps = AgentLoop.Dependencies(
        provider: ModelRouter.provider(for: config),
        options: ModelRouter.options(for: config),
        process: processLayer,
        systemPrompt: systemPrompt,
        projectContext: {
            let files = await workspace.fileMap()
            return await ContextBuilder().build(files: files, touched: [], pinned: []) { try? await workspace.readFile($0) }
        },
        collectErrors: { await collector.collect() },
        onTurnStart: { await collector.reset() },
        readFile: { try? await workspace.readFile($0) },
        searchCode: { kind, q in await CodeSearch.run(kind, query: q, root: root) },
        permissionConfig: PermissionConfig.load(projectRoot: root))

    var assistant = "", files: [String] = [], preview: URL?, clean = false, failed: String?
    for await ev in AgentLoop(deps).run(userPrompt: prompt, history: [], mode: plan ? .plan : .build) {
        switch ev {
        case .assistantText(let t): assistant += t
        case .fileWritten(let p): if !files.contains(p) { files.append(p) }
        case .previewReady(let u): preview = u
        case .state(let s):
            if case .clean = s { clean = true }
            if case .failed(let m) = s { failed = m }
        default: break
        }
    }
    await devServer.shutdown()

    if plan {
        return assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(ingen plan returneret)" : assistant
    }
    var out = scaffolded ? "Scaffoldede \(framework.displayName) + byggede.\n" : "Byggede.\n"
    out += clean ? "Status: ✓ ren (ingen build-fejl)\n" : (failed.map { "Status: ✗ fejlede — \($0)\n" } ?? "Status: færdig\n")
    out += files.isEmpty ? "Ingen filer ændret.\n" : "Filer (\(files.count)): \(files.joined(separator: ", "))\n"
    if let preview { out += "Preview kørte på \(preview.absoluteString) (lukket nu).\n" }
    let trimmed = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { out += "\n" + String(trimmed.prefix(1200)) }
    return out
}

/// Bridge the async build into the synchronous JSON-RPC loop (one request at a time).
func runBuildSync(root: URL, args: [String: Any]) -> String {
    let prompt = (args["prompt"] as? String) ?? ""
    let framework = Framework(id: (args["framework"] as? String) ?? "react")
    let plan = (args["plan"] as? Bool) ?? false
    let config = resolveModelConfig(args)
    let sem = DispatchSemaphore(value: 0)
    let box = ResultBox()
    Task {
        let s = await runBuild(root: root, prompt: prompt, framework: framework, config: config, plan: plan)
        box.set(s); sem.signal()
    }
    sem.wait()
    return box.get()
}

/// Tiny thread-safe holder so the Task result crosses back to the waiting thread.
final class ResultBox: @unchecked Sendable {
    private var value = ""
    private let lock = NSLock()
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - Main loop

let rootURL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty,
          let data = trimmed.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

    let method = msg["method"] as? String ?? ""
    let id = msg["id"] ?? NSNull()
    let isNotification = msg["id"] == nil

    switch method {
    case "initialize":
        reply(id: id, result: [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "storm-mcp", "version": "0.1.0"],
        ])
    case "tools/list":
        reply(id: id, result: ["tools": toolDefinitions()])
    case "tools/call":
        let params = msg["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "list_files":
            textResult(id: id, listFiles(root: rootURL).joined(separator: "\n"))
        case "read_file":
            guard let path = args["path"] as? String else {
                fail(id: id, code: -32602, message: "read_file requires a 'path' argument"); break
            }
            if let contents = readFile(root: rootURL, path: path) {
                textResult(id: id, contents)
            } else {
                fail(id: id, code: -32603, message: "Could not read \(path)")
            }
        case "write_file":
            guard let path = args["path"] as? String, let contents = args["contents"] as? String else {
                fail(id: id, code: -32602, message: "write_file requires 'path' and 'contents'"); break
            }
            if writeFile(root: rootURL, path: path, contents: contents) {
                textResult(id: id, "Wrote \(path)")
            } else {
                fail(id: id, code: -32603, message: "Could not write \(path)")
            }
        case "run_command":
            guard let command = args["command"] as? String else {
                fail(id: id, code: -32602, message: "run_command requires a 'command'"); break
            }
            let (out, code) = runShell(command, in: rootURL)
            textResult(id: id, "exit \(code)\n\(out)")
        case "get_errors":
            textResult(id: id, getErrors(root: rootURL))
        case "build":
            guard let prompt = args["prompt"] as? String, !prompt.isEmpty else {
                fail(id: id, code: -32602, message: "build requires a 'prompt' argument"); break
            }
            textResult(id: id, runBuildSync(root: rootURL, args: args))
        default:
            fail(id: id, code: -32601, message: "Unknown tool: \(name)")
        }
    case "notifications/initialized", "initialized":
        break   // notifications take no response
    default:
        if !isNotification { fail(id: id, code: -32601, message: "Method not found: \(method)") }
    }
}
