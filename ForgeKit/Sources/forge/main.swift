import Foundation
import ForgeKit

// ─────────────────────────────────────────────────────────────────────────────
// `forge` — the Forge engine, on the command line.
//
// Drives the REAL ForgeKit AgentLoop (same provider, process layer, artifact
// parser, executor and self-correction the GUI app uses) from a terminal. The
// dogfood harness proved the engine is headless-ready; this is the user-facing
// command on top of it.
//
//   forge new <name> [--framework react|svelte|vue|nextjs]
//   forge build "<prompt>" [--project DIR] [--framework F] [--model M]
//                          [--provider lmStudio|ollama|openai|anthropic|gemini|nvidia]
//                          [--plan] [--plain]
//   forge chat [--project DIR] [--framework F] ...    # interactive REPL
//
// Config: ~/.config/forge/config.json (provider/model/framework/baseURL/apiKey).
// Flags override config.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Output

let isTTY = isatty(fileno(stdout)) != 0
let plain = CommandLine.arguments.contains("--plain") || !isTTY

func paint(_ s: String, _ code: String) -> String { plain ? s : "\u{001B}[\(code)m\(s)\u{001B}[0m" }
func dim(_ s: String) -> String { paint(s, "2") }
func bold(_ s: String) -> String { paint(s, "1") }
func green(_ s: String) -> String { paint(s, "32") }
func red(_ s: String) -> String { paint(s, "31") }
func cyan(_ s: String) -> String { paint(s, "36") }

func say(_ s: String) { print(s); fflush(stdout) }
func info(_ s: String) { say(dim("· ") + s) }
func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((red("forge: ") + s + "\n").utf8)); exit(1) }

// MARK: - Config

struct ForgeConfig: Codable {
    var provider: String?
    var model: String?
    var framework: String?
    var baseURL: String?
    var apiKey: String?
    var verbose: Bool?
    var theme: String?

    static func load() -> ForgeConfig {
        let path = configDir().appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: path),
              let cfg = try? JSONDecoder().decode(ForgeConfig.self, from: data)
        else { return ForgeConfig() }
        return cfg
    }

    func save() {
        try? FileManager.default.createDirectory(at: configDir(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        if let data = try? enc.encode(self) {
            try? data.write(to: configDir().appendingPathComponent("config.json"), options: .atomic)
        }
    }
}

/// XDG-ish config dir: $XDG_CONFIG_HOME/forge or ~/.config/forge.
func configDir() -> URL {
    let env = ProcessInfo.processInfo.environment
    let base = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
    return base.appendingPathComponent("forge")
}

// MARK: - Args

/// Pulls `--key value` pairs and `--flag` switches out of argv; returns the rest
/// as positional arguments.
struct Args {
    private(set) var positionals: [String] = []
    private var options: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < raw.count, !raw[i + 1].hasPrefix("--") {
                    options[key] = raw[i + 1]; i += 2
                } else {
                    flags.insert(key); i += 1
                }
            } else {
                positionals.append(a); i += 1
            }
        }
    }
    func option(_ k: String) -> String? { options[k] }
    func flag(_ k: String) -> Bool { flags.contains(k) }
}

// MARK: - Model selection

func makeModelConfig(_ args: Args, _ cfg: ForgeConfig) -> ModelConfig {
    let provider = args.option("provider") ?? cfg.provider ?? "lmStudio"
    let model = args.option("model") ?? cfg.model ?? "qwen/qwen3.6-35b-a3b"
    let apiKey = args.option("api-key") ?? cfg.apiKey ?? ProcessInfo.processInfo.environment["FORGE_CLOUD_API_KEY"] ?? ""
    let baseURL = (args.option("base-url") ?? cfg.baseURL).flatMap { URL(string: $0) }

    switch provider.lowercased() {
    case "ollama":    return baseURL.map { ModelConfig.ollama(model: model, baseURL: $0) } ?? .ollama(model: model)
    case "openai":     return .openAI(key: apiKey, model: model)
    case "anthropic":  return .anthropic(key: apiKey, model: model)
    case "gemini":     return .gemini(key: apiKey, model: model)
    case "openrouter": return .openRouter(key: apiKey, model: model)
    case "nvidia":     return .nvidiaNIM(key: apiKey, model: model)
    default:          return baseURL.map { ModelConfig.lmStudio(model: model, baseURL: $0) } ?? .lmStudio(model: model)
    }
}

// MARK: - Engine wiring (mirrors tools/dogfood)

/// One project's live engine context, reused across REPL turns.
struct Engine: Sendable {
    let workspace: ProjectWorkspace
    let devServer: DevServerManager
    let collector: ErrorCollector
    var config: ModelConfig            // var: mid-session model switch (P10) reassigns this
    let mcp: MCPManager
    let checkpoints: CheckpointManager // pre-turn snapshots → /diff + /undo + /restore
}

/// Open `dir` as a project; scaffold the framework template only if it isn't one yet.
func prepareEngine(dir: URL, framework: Framework, config: ModelConfig) async throws -> Engine {
    let workspace = ProjectWorkspace(root: dir)
    let pkg = dir.appendingPathComponent("package.json")
    if !FileManager.default.fileExists(atPath: pkg.path) {
        try await TemplateInstaller().install(framework.template, into: workspace)
        info("scaffolded \(framework.displayName) + Vite + Tailwind in \(dir.path)")
    } else {
        info("opened existing project at \(dir.path)")
    }
    let devServer = DevServerManager(workspace: workspace)
    let mcp = MCPManager()
    await mcp.start(projectRoot: dir)
    if !mcp.isEmpty { info("MCP: \(mcp.availableTools.count) eksternt værktøj(er) tilgængelige") }
    return Engine(workspace: workspace, devServer: devServer,
                  collector: ErrorCollector(devServer: devServer), config: config, mcp: mcp,
                  checkpoints: CheckpointManager(root: dir))
}

func makeDeps(_ engine: Engine, mode: AgentLoop.Mode, gate: (any PermissionGate)? = nil,
              pinned: [String] = []) -> AgentLoop.Dependencies {
    let processLayer = ForgeProcessLayer(workspace: engine.workspace, devServer: engine.devServer)
    // Strong models (cloud) get the line-replace prompt; local models keep full-file writes.
    let base = mode == .plan ? SystemPrompt.plan : SystemPrompt.forge(lineReplace: engine.config.supportsLineReplace)
    var systemPrompt = engine.mcp.promptSection().map { base + "\n\n" + $0 } ?? base
    if let rules = RulesLoader.read(projectRoot: engine.workspace.root) {   // AGENTS.md + AI_RULES.md
        systemPrompt += "\n\n" + rules
    }
    return AgentLoop.Dependencies(
        provider: ModelRouter.provider(for: engine.config),
        options: ModelRouter.options(for: engine.config),
        process: processLayer,
        systemPrompt: systemPrompt,
        projectContext: { [workspace = engine.workspace, pinned] in
            let files = await workspace.fileMap()
            return await ContextBuilder().build(files: files, touched: [], pinned: pinned) { try? await workspace.readFile($0) }
        },
        collectErrors: { [collector = engine.collector] in await collector.collect() },
        onTurnStart: { [collector = engine.collector] in await collector.reset() },
        readFile: { [workspace = engine.workspace] path in try? await workspace.readFile(path) },
        callMCP: { [mcp = engine.mcp] server, tool, argsJSON in
            let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
            return await mcp.call(server: server, tool: tool, arguments: args)
        },
        permissionGate: gate,
        settleDelay: .seconds(2),
        maxRepairAttempts: 3)
}

/// Run one turn, streaming the engine's events to the terminal. Returns the
/// assistant text (for REPL history), the preview URL, and whether it reached clean.
@discardableResult
// MARK: - Metrics (verbose / observability)

func fmtTTFT(_ s: Double?) -> String { s.map { String(format: "%.2fs", $0) } ?? "—" }
func fmtRate(_ r: Double) -> String { String(format: "%.0f tok/s", r) }
func fmtSecs(_ s: Double) -> String { String(format: "%.1fs", s) }
/// "Gratis" / "≈ $0.03" / nil (unknown cloud price). USD — CLI keeps it currency-neutral.
func fmtCost(_ usd: Double?) -> String? {
    guard let usd else { return nil }
    return usd <= 0 ? "gratis" : String(format: "≈ $%.3f", usd)
}

/// Session-wide accumulator across every model call in this `forge` run.
final class MetricsAccumulator {
    var calls = 0
    var promptTokens = 0
    var completionTokens = 0
    var totalSeconds = 0.0
    var costUSD: Double?
    func add(_ m: GenerationMetrics, cost: Double?) {
        calls += 1
        promptTokens += m.promptTokens
        completionTokens += m.completionTokens
        totalSeconds += m.totalSeconds
        if let cost { costUSD = (costUSD ?? 0) + cost }
    }
    var totalTokens: Int { promptTokens + completionTokens }
    var tokensPerSecond: Double { totalSeconds > 0 ? Double(completionTokens) / totalSeconds : 0 }
}

func printSession(_ m: MetricsAccumulator) {
    guard m.calls > 0 else { return }
    let cost = fmtCost(m.costUSD).map { " · \($0)" } ?? ""
    say(bold("Session: ") + "\(m.calls) kald · \(m.totalTokens) tok (\(m.promptTokens)→\(m.completionTokens)) · "
        + "\(fmtRate(m.tokensPerSecond)) · \(fmtSecs(m.totalSeconds))\(cost)")
}

/// CLI approval gate: prompts on stdin (j/n/a) before shell/dep/MCP actions.
/// Interactive runs only — CI (`--plain`/non-TTY) and `--yes` use nil (allow-all).
final class StdinPermissionGate: PermissionGate, @unchecked Sendable {
    private var sessionAllowed = Set<String>()
    func decide(_ request: PermissionRequest) async -> PermissionDecision {
        let key = request.label
        if sessionAllowed.contains(key) { return .allowForSession }
        say("\n" + cyan("⚠ Forge vil \(request.label)"))
        FileHandle.standardOutput.write(Data(bold("  Tillad? [j]a / [n]ej / [a]ltid: ").utf8))
        let answer = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch answer.first {
        case "a": sessionAllowed.insert(key); return .allowForSession
        case "n": return .deny
        default:  return .allow   // empty or j/y → allow once
        }
    }
}

func runTurn(_ engine: Engine, prompt: String, history: [ChatMessage], mode: AgentLoop.Mode,
             verbose: Bool = false, session: MetricsAccumulator? = nil,
             gate: (any PermissionGate)? = nil)
    async -> (assistant: String, preview: URL?, clean: Bool)
{
    let pinnedFiles = ContextBuilder.pinned(from: prompt, files: await engine.workspace.fileMap())
    let loop = AgentLoop(makeDeps(engine, mode: mode, gate: gate, pinned: pinnedFiles))
    var assistant = ""
    var preview: URL?
    var clean = false
    // Per-message (besked) accumulation — a turn may issue several calls (read/tool
    // rounds + repairs).
    var turnCalls = 0, turnPrompt = 0, turnCompletion = 0
    var turnSeconds = 0.0
    var turnFirstTTFT: Double?
    var turnCostUSD: Double?
    for await event in loop.run(userPrompt: prompt, history: history, mode: mode) {
        switch event {
        case .state(let s):
            switch s {
            case .planning:        info("planlægger…")
            case .building:        info("genererer kode…")
            case .applying:        info("skriver filer + starter dev-server…")
            case .awaitingHMR:     info("lader det sætte sig…")
            case .collectingErrors: info("tjekker for fejl…")
            case .repairing(let n): info(cyan("retter fejl (forsøg \(n))…"))
            case .clean:           clean = true; say(green("✓ klar"))
            case .planReady:       say(green("✓ plan klar"))
            case .failed(let why): say(red("✗ fejlede: ") + why.prefix(200))
            case .idle:            break
            }
        case .fileWritten(let path): say("  " + green("✎") + " \(path)")
        case .previewReady(let url): preview = url; say("  " + cyan("→ preview: ") + url.absoluteString)
        case .assistantText(let t):
            if mode == .plan {
                FileHandle.standardOutput.write(Data(t.utf8))
            } else {
                // Surface tool/read activity in build mode (markers like "_Kalder fs/x…_").
                let line = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("_Kalder ") || line.hasPrefix("_Læser ") {
                    say("  " + cyan("⚙ ") + line.trimmingCharacters(in: CharacterSet(charactersIn: "_")))
                }
            }
            assistant += t
        case .metrics(let m):
            turnCalls += 1
            turnPrompt += m.promptTokens; turnCompletion += m.completionTokens; turnSeconds += m.totalSeconds
            if turnFirstTTFT == nil { turnFirstTTFT = m.timeToFirstTokenSeconds }
            let callCost = engine.config.cost(promptTokens: m.promptTokens, completionTokens: m.completionTokens)
            if let callCost { turnCostUSD = (turnCostUSD ?? 0) + callCost }
            session?.add(m, cost: callCost)
            if verbose {
                let n = session?.calls ?? turnCalls
                let costStr = fmtCost(callCost).map { " · \($0)" } ?? ""
                say("  " + dim("↳ kald \(n): \(m.totalTokens) tok (\(m.promptTokens)→\(m.completionTokens)) · "
                    + "TTFT \(fmtTTFT(m.timeToFirstTokenSeconds)) · \(fmtRate(m.tokensPerSecond)) · \(fmtSecs(m.totalSeconds))\(costStr)"))
            }
        case .reasoning, .fileWriting, .fileChunk, .usage: break
        }
    }
    if turnCalls > 0 {
        let rate = turnSeconds > 0 ? Double(turnCompletion) / turnSeconds : 0
        let costStr = fmtCost(turnCostUSD).map { " · \($0)" } ?? ""
        say("  " + dim("Σ besked: \(turnCalls) kald · \(turnPrompt + turnCompletion) tok (\(turnPrompt)→\(turnCompletion)) · "
            + "TTFT \(fmtTTFT(turnFirstTTFT)) · \(fmtRate(rate)) · \(fmtSecs(turnSeconds))\(costStr)"))
    }
    if mode == .plan { say("") }
    return (assistant, preview, clean)
}

// MARK: - Keep-alive

/// Block until Ctrl-C, then shut the dev server down cleanly.
func waitUntilInterrupt(_ engine: Engine) async {
    say(dim("Preview kører — tryk Ctrl-C for at stoppe."))
    signal(SIGINT, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    src.setEventHandler { Task { await engine.devServer.shutdown(); say(""); exit(0) } }
    src.resume()
    while true { try? await Task.sleep(for: .seconds(3600)) }
}

// MARK: - Project dir resolution

func resolveProjectDir(_ args: Args, defaultName: String) -> URL {
    if let p = args.option("project") {
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(defaultName)
}

func slug(_ s: String) -> String {
    let lowered = s.lowercased().prefix(40)
    let cleaned = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
    let joined = String(cleaned).split(separator: "-").joined(separator: "-")
    return joined.isEmpty ? "forge-app" : joined
}

// MARK: - Commands

let helpText = """
\(bold("forge")) — byg web-apps fra terminalen med en lokal AI-model.

\(bold("KOMMANDOER"))
  forge new <navn> [--framework F]      Scaffold et tomt projekt (ingen model)
  forge build "<prompt>" [valg]         Byg én gang; holder preview kørende
  forge chat [valg]                     Interaktiv session (byg videre i samme projekt)
  forge skills [--project DIR]          Vis tilgængelige skills (presets)
  forge mcp [--project DIR]             Start MCP-servere fra .forge/.mcp.json + vis værktøjer

\(bold("VALG"))
  --project DIR        Projektmappe (default: ./<navn> eller ./<slug>)
  --framework F        react (default) · svelte · vue · nextjs
  --skill <id>         brug en skill som prompt (se 'forge skills'); positional = ekstra input
  --provider P         lmStudio (default) · ollama · openai · anthropic · gemini · openrouter · nvidia
  --model M            model-id (default: qwen/qwen3.6-35b-a3b)
  --base-url URL       eget OpenAI-kompatibelt endpoint
  --api-key KEY        cloud-nøgle (ellers $FORGE_CLOUD_API_KEY eller config)
  --plan               kun planlæg (ingen filer skrives)
  --no-serve           afslut efter build i stedet for at holde preview kørende (CI)
  --plain              ingen farver/ANSI (CI-venligt; bruger linje-REPL, ikke TUI)
  --no-tui             brug den simple linje-REPL i stedet for fuldskærms-TUI
  --resume             genoptag seneste session (forge chat i TUI)
  --verbose            vis metrics pr. kald (tokens, TTFT, tok/s) + session-total
  --yes                spørg ikke før shell-kommandoer/pakker/MCP (interaktiv default: spørg)

Config: \(configDir().appendingPathComponent("config.json").path)
"""

func cmdNew(_ args: Args, _ cfg: ForgeConfig) async {
    guard let name = args.positionals.first else { fail("brug: forge new <navn> [--framework F]") }
    let framework = Framework(id: args.option("framework") ?? cfg.framework ?? "react")
    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(name)
    do {
        let workspace = ProjectWorkspace(root: dir)
        try await TemplateInstaller().install(framework.template, into: workspace)
        say(green("✓ ") + "scaffolded \(framework.displayName)-projekt: \(dir.path)")
        info("kør:  forge chat --project \(name)")
    } catch { fail("kunne ikke scaffolde: \(error)") }
}

func cmdBuild(_ args: Args, _ cfg: ForgeConfig) async {
    let framework = Framework(id: args.option("framework") ?? cfg.framework ?? "react")
    let config = makeModelConfig(args, cfg)

    // Prompt + mode come from either a --skill (a named preset) or a positional prompt.
    let prompt: String
    let mode: AgentLoop.Mode
    let defaultName: String
    if let skillID = args.option("skill") {
        let projForSkills = args.option("project").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let skills = SkillStore.load(projectRoot: projForSkills)
        guard let skill = SkillStore.find(skillID, in: skills) else {
            fail("ukendt skill '\(skillID)'. Se: forge skills")
        }
        prompt = skill.expand(input: args.positionals.first ?? "")
        mode = skill.mode
        defaultName = skill.id
        info("skill: \(skill.name) (\(skill.origin.rawValue))")
    } else {
        guard let p = args.positionals.first, !p.isEmpty else {
            fail("brug: forge build \"<prompt>\"   ·   eller: forge build --skill <id>")
        }
        prompt = p
        mode = args.flag("plan") ? .plan : .build
        defaultName = slug(p)
    }

    let dir = resolveProjectDir(args, defaultName: defaultName)
    info("model: \(config.displayName) (\(config.source.rawValue)) · framework: \(framework.displayName)")
    do {
        let engine = try await prepareEngine(dir: dir, framework: framework, config: config)
        let session = MetricsAccumulator()
        let verbose = args.flag("verbose") || cfg.verbose == true
        let gate: (any PermissionGate)? = (!plain && !args.flag("yes")) ? StdinPermissionGate() : nil
        let result = await runTurn(engine, prompt: prompt, history: [], mode: mode,
                                   verbose: verbose, session: session, gate: gate)
        printSession(session)
        if mode == .build, result.preview != nil, !args.flag("no-serve") {
            await waitUntilInterrupt(engine)
        } else {
            await engine.devServer.shutdown()
        }
    } catch { fail("\(error)") }
}

func cmdChat(_ args: Args, _ cfg: ForgeConfig) async {
    let framework = Framework(id: args.option("framework") ?? cfg.framework ?? "react")
    let dir = resolveProjectDir(args, defaultName: "forge-app")
    let config = makeModelConfig(args, cfg)
    info("model: \(config.displayName) (\(config.source.rawValue)) · framework: \(framework.displayName)")
    var engine: Engine
    do { engine = try await prepareEngine(dir: dir, framework: framework, config: config) }
    catch { fail("\(error)") }

    let verbose = args.flag("verbose") || cfg.verbose == true

    // Full-screen TUI is the default on an interactive TTY; --no-tui / --plain / a
    // pipe fall back to the line REPL (byte-identical to before).
    if !plain, isTTY, !args.flag("no-tui") {
        // --resume reloads the prior session; a local model from it wins unless --model was given.
        let resume = args.flag("resume") ? SessionFile.load(projectDir: dir) : nil
        if let resume, args.option("model") == nil {
            engine.config = resume.resolvedConfig(fallback: config)
        }
        let theme = ANSITheme.named(cfg.theme ?? "") ?? .midnight
        let term = Terminal()
        do { try term.enter() } catch { fail("\(error)") }
        await TUIApp(size: Size(cols: term.cols, rows: term.rows),
                     engine: engine, modelName: engine.config.displayName, framework: framework.displayName,
                     verbose: verbose, theme: theme, resume: resume).run()
        term.restore()
        await engine.devServer.shutdown()
        return
    }

    say(dim("Skriv hvad du vil bygge. ':plan <prompt>' for kun at planlægge · ':quit' for at stoppe."))
    let session = MetricsAccumulator()
    let gate: (any PermissionGate)? = (!plain && !args.flag("yes")) ? StdinPermissionGate() : nil
    var history: [ChatMessage] = []
    while true {
        FileHandle.standardOutput.write(Data((bold("\nforge› ")).utf8))
        guard let line = readLine(strippingNewline: true) else { break } // EOF
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        if trimmed == ":quit" || trimmed == ":q" { break }
        if trimmed == ":skills" {
            for s in SkillStore.load(projectRoot: dir) {
                say("  " + green(s.id) + dim(" · ") + s.name + (s.origin == .builtin ? "" : dim(" [\(s.origin.rawValue)]")))
            }
            continue
        }

        var mode: AgentLoop.Mode = .build
        var prompt = trimmed
        if trimmed.hasPrefix(":plan ") {
            mode = .plan; prompt = String(trimmed.dropFirst(6))
        } else if trimmed.hasPrefix(":skill ") {
            let parts = trimmed.dropFirst(7).split(separator: " ", maxSplits: 1).map(String.init)
            guard let skill = SkillStore.find(parts.first ?? "", in: SkillStore.load(projectRoot: dir)) else {
                say(red("ukendt skill — prøv :skills")); continue
            }
            mode = skill.mode
            prompt = skill.expand(input: parts.count > 1 ? parts[1] : "")
            info("skill: \(skill.name)")
        }

        let result = await runTurn(engine, prompt: prompt, history: history, mode: mode,
                                   verbose: verbose, session: session, gate: gate)
        if mode == .build {
            history.append(ChatMessage(role: .user, content: prompt))
            history.append(ChatMessage(role: .assistant, content: result.assistant))
        }
    }
    await engine.devServer.shutdown()
    printSession(session)
    say(dim("\nFarvel."))
}

func cmdSkills(_ args: Args, _ cfg: ForgeConfig) {
    let dir = args.option("project").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    let skills = SkillStore.load(projectRoot: dir)
    say(bold("Skills") + dim("  (~/.config/forge/skills/ + <projekt>/.forge/skills/)"))
    for s in skills {
        let tag = s.origin == .builtin ? "" : dim(" [\(s.origin.rawValue)]")
        say("  " + green(s.id) + dim(" · ") + s.name + tag)
        if !s.description.isEmpty { say("      " + dim(s.description)) }
    }
    say(dim("\nBrug:  forge build --skill <id> [\"ekstra tekst\"]   ·   i chat:  :skill <id> [tekst]"))
}

func cmdMCP(_ args: Args, _ cfg: ForgeConfig) async {
    let dir = args.option("project").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let configs = MCPManager.loadConfig(projectRoot: dir)
    guard !configs.isEmpty else {
        say(dim("Ingen MCP-servere konfigureret i \(dir.appendingPathComponent(".forge/.mcp.json").path). Eksempel:"))
        say(dim(#"  {"mcpServers": {"fs": {"command": "npx", "args": ["-y","@modelcontextprotocol/server-filesystem","."]}}}"#))
        return
    }
    info("starter \(configs.count) MCP-server(e)…")
    let manager = MCPManager()
    await manager.start(projectRoot: dir)
    let tools = manager.availableTools
    if tools.isEmpty {
        say(red("Ingen værktøjer fundet — kunne en server ikke starte? (tjek command/args)"))
    } else {
        say(bold("MCP-værktøjer") + dim("  (\(tools.count))"))
        for t in tools {
            say("  " + green("\(t.server)/\(t.name)") + (t.description.isEmpty ? "" : dim(" · \(t.description)")))
        }
    }
    manager.shutdownAll()
}

// MARK: - TUI selftest (hidden)

/// `forge __tuicheck` — phase-1 lifecycle probe: enter raw mode + alt screen,
/// draw a centered banner, wait for q / Ctrl-C / Ctrl-D, restore. Used by the
/// pty test harness to prove the terminal is always restored (incl. on SIGTERM).
func cmdTUICheck() {
    let term = Terminal()
    do { try term.enter() } catch { fail("\(error)") }
    defer { term.restore() }
    let msg = "Forge TUI ✓   \(term.cols)×\(term.rows)   — tryk q for at afslutte"
    TUIOutput.emit("\u{1B}[\(max(1, term.rows / 2));\(max(1, (term.cols - msg.count) / 2))H" + msg)
    var byte: UInt8 = 0
    while read(STDIN_FILENO, &byte, 1) == 1 {
        if byte == UInt8(ascii: "q") || byte == 3 || byte == 4 { break }   // q · Ctrl-C · Ctrl-D
    }
}

// MARK: - Dispatch

let argv = Array(CommandLine.arguments.dropFirst())
let cfg = ForgeConfig.load()

if argv.isEmpty || argv.first == "--help" || argv.first == "-h" || argv.first == "help" {
    say(helpText); exit(0)
}

let command = argv.first!
let rest = Args(Array(argv.dropFirst()))

switch command {
case "new":    await cmdNew(rest, cfg)
case "build":  await cmdBuild(rest, cfg)
case "chat":   await cmdChat(rest, cfg)
case "skills": cmdSkills(rest, cfg)
case "mcp":    await cmdMCP(rest, cfg)
case "__tuicheck": cmdTUICheck()
default:
    // `forge "<prompt>"` is shorthand for `forge build "<prompt>"`.
    if command.hasPrefix("--") { fail("ukendt kommando. Prøv: forge --help") }
    await cmdBuild(Args(argv), cfg)
}
