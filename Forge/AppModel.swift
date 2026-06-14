import SwiftUI
import AppKit
import ForgeKit

/// Root app state and the glue between the SwiftUI UI and the ForgeKit engine.
@MainActor
@Observable
final class AppModel {
    struct UIMessage: Identifiable, Codable {
        enum Role: String, Codable { case user, assistant }
        var id = UUID()
        let role: Role
        var text: String
        var files: [String] = []
        var reasoning: String = ""   // reasoning-model "thinking", shown collapsibly
        var isPlan: Bool = false     // a plan-mode response → show "Build this plan"
        var questions: [PlanQuestion] = []   // clarifying questions → tappable chips
    }

    enum PreviewWidth: CaseIterable {
        case full, tablet, phone
        var maxWidth: CGFloat? {
            switch self {
            case .full: nil
            case .tablet: 834
            case .phone: 414
            }
        }
        var icon: String {
            switch self {
            case .full: "rectangle"
            case .tablet: "ipad"
            case .phone: "iphone"
            }
        }
    }

    enum RightPaneMode { case preview, code }

    struct SelectedElement: Equatable {
        var tag: String
        var text: String
        var className: String
        var selector: String
    }

    // Chat
    var messages: [UIMessage] = []
    var draft: String = ""
    var isBusy: Bool = false
    var statusText: String = "Ready."
    var chatMode: AgentLoop.Mode = .build   // Plan vs Build toggle in the composer

    // Layout: the preview pane only appears once the first build has started.
    var hasStarted: Bool = false

    // Preview
    var previewURL: URL?
    var phase: AgentState = .idle
    var previewWidth: PreviewWidth = .full
    var reloadToken: Int = 0
    var rightPaneMode: RightPaneMode = .preview

    // Code view
    var projectFiles: [String] = []
    var selectedFile: String?
    var editorText: String = ""
    var editorDirty: Bool = false

    // Deploy
    var isDeploying = false
    var deployStatus = ""
    var deployLog: [String] = []
    var deployGithubURL: URL?
    var deployVercelURL: URL?
    var showDeploy = false

    // Visual editing
    var selectMode = false
    var selectedElement: SelectedElement?

    // Diagnostics
    var serverLog: [LogLine] = []
    var jsErrors: [RuntimeIssue] = []
    var showConsole: Bool = false

    // Model selection
    var availableModels: [ModelConfig] = []
    var selectedModelID: String = ""

    // ForgeKit handles (Sendable; safe to use from off-main tasks).
    // Config
    var preferences = Preferences()

    // Projects
    var projects: [Project] = []
    var currentProject: Project

    @ObservationIgnored private(set) var workspace: ProjectWorkspace
    @ObservationIgnored private(set) var devServer: DevServerManager
    @ObservationIgnored private(set) var processLayer: ForgeProcessLayer
    @ObservationIgnored private(set) var errorCollector: ErrorCollector
    @ObservationIgnored private var templateInstalled = false
    @ObservationIgnored private var agentTask: Task<Void, Never>?
    @ObservationIgnored private var logTask: Task<Void, Never>?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastLoadedText = ""

    init() {
        let prefs = PreferencesStore.load()
        self.preferences = prefs
        if !prefs.projectsRoot.isEmpty {
            ProjectStore.configuredRoot = URL(fileURLWithPath: prefs.projectsRoot)
        }
        var loaded = ProjectStore.loadProjects()
        if loaded.isEmpty {
            let project = ProjectStore.makeProject(name: "Untitled")
            ProjectStore.saveProjects([project])
            loaded = [project]
        }
        let current = loaded[0]
        self.projects = loaded
        self.currentProject = current

        let workspace = ProjectWorkspace(root: ProjectStore.dir(for: current))
        let devServer = DevServerManager(workspace: workspace)
        self.workspace = workspace
        self.devServer = devServer
        self.processLayer = ForgeProcessLayer(workspace: workspace, devServer: devServer)
        self.errorCollector = ErrorCollector(devServer: devServer)

        self.availableModels = [.localDefault]
        self.selectedModelID = prefs.defaultModelID.isEmpty ? ModelConfig.localDefault.id : prefs.defaultModelID

        self.messages = ProjectStore.loadChat(for: current)
        self.hasStarted = !messages.isEmpty
        self.templateInstalled = ProjectStore.hasBuiltApp(current)

        startLogStream()
        let resume = templateInstalled && !messages.isEmpty
        let devServerRef = devServer
        Task {
            await refreshModels()
            if resume { try? await devServerRef.start() }
        }
    }

    var selectedModel: ModelConfig {
        availableModels.first { $0.id == selectedModelID } ?? .localDefault
    }

    /// Re-discover local models (Ollama + LM Studio) plus the optional cloud
    /// model. Called at launch and from the picker's Refresh button.
    func refreshModels() async {
        var models = await ModelDiscovery.discoverLocal()
        if let key = KeychainStore.get(account: KeychainStore.cloudKeyAccount), !key.isEmpty {
            models.append(cloudConfig(key: key))
        } else if let key = ProcessInfo.processInfo.environment["FORGE_CLOUD_API_KEY"], !key.isEmpty {
            let cloud = ProcessInfo.processInfo.environment["FORGE_CLOUD_MODEL"] ?? "nvidia/llama-3.1-nemotron-70b-instruct"
            models.append(.nvidiaNIM(key: key, model: cloud))
        }
        if models.isEmpty { models = [.localDefault] }
        availableModels = models
        if !models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = Self.preferredDefault(models).id
        }
    }

    static func preferredDefault(_ models: [ModelConfig]) -> ModelConfig {
        models.first { $0.modelID.lowercased().contains("coder") }
            ?? models.first { $0.source == .ollama }
            ?? models.first ?? .localDefault
    }

    // MARK: - Preferences / config

    func savePreferences() { PreferencesStore.save(preferences) }

    func completeOnboarding() {
        preferences.onboarded = true
        applyPreferences()
    }

    /// Apply runtime-affecting preferences (projects location + default model).
    /// Called when onboarding finishes or Settings changes them.
    func applyPreferences() {
        savePreferences()
        ProjectStore.configuredRoot = preferences.projectsRoot.isEmpty
            ? nil : URL(fileURLWithPath: preferences.projectsRoot)
        var loaded = ProjectStore.loadProjects()
        if loaded.isEmpty {
            let project = ProjectStore.makeProject(name: "Untitled")
            ProjectStore.saveProjects([project])
            loaded = [project]
        }
        projects = loaded
        if !loaded.contains(where: { $0.id == currentProject.id }) {
            activate(loaded[0], freshState: false)
        }
        if !preferences.defaultModelID.isEmpty { selectedModelID = preferences.defaultModelID }
        Task { await refreshModels() }
    }

    /// System prompt = base + user name + global memory + project AI_RULES.md.
    private func composedSystemPrompt(mode: AgentLoop.Mode = .build) async -> String {
        let base = mode == .plan
            ? SystemPrompt.plan
            : SystemPrompt.forge(lineReplace: selectedModel.supportsLineReplace)
        var parts = [base]
        if !preferences.userName.isEmpty {
            parts.append("The user you are helping is called \(preferences.userName). Address them by name when natural.")
        }
        let memory = preferences.memory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !memory.isEmpty {
            parts.append("User preferences and context to always respect:\n\(memory)")
        }
        if let rules = try? await workspace.readFile("AI_RULES.md"),
           !rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Project-specific rules (AI_RULES.md):\n\(rules)")
        }
        return parts.joined(separator: "\n\n")
    }

    private func cloudConfig(key: String) -> ModelConfig {
        let model = preferences.cloudModel
        switch preferences.cloudProvider {
        case "openai": return .openAI(key: key, model: model.isEmpty ? "gpt-4o" : model)
        case "anthropic": return .anthropic(key: key, model: model.isEmpty ? "claude-sonnet-4-6" : model)
        default: return .nvidiaNIM(key: key, model: model.isEmpty ? "nvidia/llama-3.1-nemotron-70b-instruct" : model)
        }
    }

    // MARK: - Projects

    func newProject() {
        guard !isBusy else { return }
        persistCurrentChat()
        let project = ProjectStore.makeProject(name: "Untitled")
        projects.insert(project, at: 0)
        ProjectStore.saveProjects(projects)
        activate(project, freshState: true)
    }

    func switchTo(_ project: Project) {
        guard !isBusy, project.id != currentProject.id else { return }
        persistCurrentChat()
        activate(project, freshState: false)
    }

    func deleteProject(_ project: Project) {
        guard !isBusy else { return }
        projects.removeAll { $0.id == project.id }
        ProjectStore.deleteDir(for: project)
        if projects.isEmpty {
            projects = [ProjectStore.makeProject(name: "Untitled")]
        }
        ProjectStore.saveProjects(projects)
        if currentProject.id == project.id {
            activate(projects[0], freshState: false)
        }
    }

    private func activate(_ project: Project, freshState: Bool) {
        let previous = devServer
        Task { await previous.shutdown() }

        currentProject = project
        installHandles(for: project)

        previewURL = nil
        phase = .idle
        rightPaneMode = .preview
        selectedFile = nil
        editorText = ""
        projectFiles = []
        serverLog = []
        jsErrors = []
        statusText = "Ready."
        messages = freshState ? [] : ProjectStore.loadChat(for: project)
        templateInstalled = ProjectStore.hasBuiltApp(project)
        hasStarted = !messages.isEmpty

        if templateInstalled && !messages.isEmpty {
            let devServerRef = devServer
            Task { try? await devServerRef.start() }
        }
    }

    private func installHandles(for project: Project) {
        let workspace = ProjectWorkspace(root: ProjectStore.dir(for: project))
        self.workspace = workspace
        self.devServer = DevServerManager(workspace: workspace)
        self.processLayer = ForgeProcessLayer(workspace: workspace, devServer: devServer)
        self.errorCollector = ErrorCollector(devServer: devServer)
        startLogStream()
    }

    private func persistCurrentChat() {
        ProjectStore.saveChat(messages, for: currentProject)
        currentProject.updatedAt = Date()
        if let index = projects.firstIndex(where: { $0.id == currentProject.id }) {
            projects[index] = currentProject
        }
        ProjectStore.saveProjects(projects)
    }

    private func renameCurrent(to name: String) {
        currentProject.name = name
        if let index = projects.firstIndex(where: { $0.id == currentProject.id }) {
            projects[index] = currentProject
        }
        ProjectStore.saveProjects(projects)
    }

    static func projectName(from prompt: String) -> String {
        let trimmed = prompt.split(separator: " ").prefix(6).joined(separator: " ")
        return String(trimmed.prefix(42))
    }

    // MARK: - Deploy (GitHub + Vercel)

    func deploy() {
        guard !isDeploying, !isBusy, hasStarted else { return }
        isDeploying = true
        showDeploy = true
        deployLog = []
        deployGithubURL = nil
        deployVercelURL = nil
        let repo = "forge-" + Self.slug(currentProject.name)
        Task {
            await runDeploy(repo: repo)
            isDeploying = false
        }
    }

    private func runDeploy(repo: String) async {
        let owner = preferences.githubOwner.isEmpty ? "Parthee-Vijaya" : preferences.githubOwner
        let ownerPrefix = preferences.githubOwner.isEmpty ? "" : "\(preferences.githubOwner)/"
        let scopeFlag = preferences.vercelScope.isEmpty ? "" : " --scope \(preferences.vercelScope)"

        deployStatus = "Preparing repository…"
        _ = try? await deployShell(
            "git init -q 2>/dev/null; git config user.email 'partivijaya@icloud.com'; "
            + "git config user.name 'Parthee Vijaya'; git add -A; "
            + "git commit -q -m 'Deploy from Forge' 2>/dev/null || true")

        deployStatus = "Pushing to GitHub…"
        let githubOutput = (try? await deployShell(
            "gh repo create \(ownerPrefix)\(repo) --private --source=. --remote=origin --push 2>&1 "
            + "|| git push -u origin HEAD 2>&1")) ?? ""
        deployGithubURL = Self.firstMatch(#"https://github\.com/[^\s]+"#, in: githubOutput)
            ?? URL(string: "https://github.com/\(owner)/\(repo)")

        deployStatus = "Deploying to Vercel…"
        let vercelOutput = (try? await deployShell("vercel deploy --prod --yes\(scopeFlag) 2>&1")) ?? ""
        deployVercelURL = Self.firstMatch(#"https://[^\s]+\.vercel\.app"#, in: vercelOutput)
        deployStatus = deployVercelURL != nil ? "Live on Vercel." : "Finished — check the log."
    }

    @discardableResult
    private func deployShell(_ command: String) async throws -> String {
        let (events, _) = try await devServer.runShellCommand(command)
        var output = ""
        for await event in events {
            if case .log(let line) = event {
                output += line.text + "\n"
                deployLog.append(line.text)
                if deployLog.count > 300 { deployLog.removeFirst(deployLog.count - 300) }
            }
        }
        return output
    }

    func openURL(_ url: URL) { NSWorkspace.shared.open(url) }

    static func slug(_ name: String) -> String {
        var s = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "app" : String(s.prefix(40))
    }

    static func firstMatch(_ pattern: String, in text: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[range]))
    }

    // MARK: - Visual editing

    func toggleSelectMode() {
        selectMode.toggle()
        if !selectMode { selectedElement = nil }
    }

    func handleElementSelected(tag: String, text: String, className: String, selector: String) {
        selectedElement = SelectedElement(tag: tag, text: text, className: className, selector: selector)
    }

    func clearSelection() {
        selectedElement = nil
        selectMode = false
    }

    /// Turn the selected element + a natural-language instruction into a targeted
    /// edit turn for the agent loop (which rewrites the source → HMR).
    func applyVisualEdit(_ instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let element = selectedElement, !trimmed.isEmpty, !isBusy else { return }
        selectMode = false
        selectedElement = nil
        draft = """
        In the running preview the user selected this element:
        <\(element.tag) class="\(element.className)">\(element.text)</\(element.tag)>
        Apply this change to that exact element in the source: \(trimmed)
        """
        submit()
    }

    // MARK: - Code view

    func enterCodeMode() {
        rightPaneMode = .code
        Task {
            await refreshFiles()
            if selectedFile == nil {
                let entry = projectFiles.first { $0 == "src/App.tsx" } ?? projectFiles.first
                if let entry { await openFile(entry) }
            }
        }
    }

    func refreshFiles() async {
        projectFiles = await workspace.fileMap()
    }

    func openFile(_ path: String) async {
        autosaveTask?.cancel()
        guard let text = try? await workspace.readFile(path) else { return }
        editorText = text
        lastLoadedText = text
        selectedFile = path
        editorDirty = false
    }

    /// Debounced autosave: writing the file lets Vite HMR refresh the preview.
    func onEditorChange() {
        guard editorText != lastLoadedText else { return }
        editorDirty = true
        autosaveTask?.cancel()
        let path = selectedFile
        let text = editorText
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let path else { return }
            try? await workspace.writeFile(path, contents: text)
            lastLoadedText = text
            editorDirty = false
        }
    }

    func saveNow() async {
        autosaveTask?.cancel()
        guard let path = selectedFile else { return }
        try? await workspace.writeFile(path, contents: editorText)
        lastLoadedText = editorText
        editorDirty = false
    }

    // MARK: - Chat submission

    func submit() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isBusy else { return }
        if messages.isEmpty { renameCurrent(to: Self.projectName(from: prompt)) }
        draft = ""
        hasStarted = true
        let history = chatHistory()
        messages.append(UIMessage(role: .user, text: prompt))
        messages.append(UIMessage(role: .assistant, text: ""))
        let assistantIndex = messages.count - 1
        isBusy = true
        let mode = chatMode

        agentTask = Task {
            await runAgent(prompt: prompt, history: history, assistantIndex: assistantIndex, mode: mode)
            if Task.isCancelled {
                phase = .idle
                statusText = "Stopped."
                if messages.indices.contains(assistantIndex), messages[assistantIndex].text.isEmpty {
                    messages[assistantIndex].text = "_Stopped._"
                }
            } else {
                statusText = Self.statusText(for: phase)
            }
            isBusy = false
            agentTask = nil
        }
    }

    /// Cancel an in-flight generation. The AgentLoop's stream terminates on the
    /// consuming task's cancellation; partial assistant text + any files already
    /// written are kept.
    func cancelGeneration() {
        agentTask?.cancel()
    }

    private func runAgent(prompt: String, history: [ChatMessage], assistantIndex: Int, mode: AgentLoop.Mode) async {
        if mode == .plan {
            await runPlan(prompt: prompt, history: history, assistantIndex: assistantIndex)
            return
        }
        if !templateInstalled {
            do {
                try await TemplateInstaller().install(into: workspace)
                if !preferences.rulesTemplate.isEmpty, !(await workspace.fileExists("AI_RULES.md")) {
                    try? await workspace.writeFile("AI_RULES.md", contents: preferences.rulesTemplate)
                }
                templateInstalled = true
            } catch {
                appendAssistant(assistantIndex, "Could not scaffold the project: \(error)")
                return
            }
        }
        await errorCollector.reset()

        let config = selectedModel
        let systemPrompt = await composedSystemPrompt()
        let touched = Self.recentTouched(from: messages)
        let deps = AgentLoop.Dependencies(
            provider: ModelRouter.provider(for: config),
            options: ModelRouter.options(for: config),
            process: processLayer,
            systemPrompt: systemPrompt,
            projectContext: { [workspace] in await AppModel.buildContext(workspace, touched: touched) },
            collectErrors: { [errorCollector] in await errorCollector.collect() },
            onTurnStart: { [errorCollector] in await errorCollector.reset() },
            settleDelay: .seconds(2),
            maxRepairAttempts: 3)

        for await event in AgentLoop(deps).run(userPrompt: prompt, history: history) {
            switch event {
            case .assistantText(let text):
                appendAssistant(assistantIndex, text)
            case .reasoning(let text):
                appendReasoning(assistantIndex, text)
            case .state(let state):
                phase = state
                statusText = Self.statusText(for: state)
            case .fileWriting(let path):
                statusText = "Writing \(path)…"
            case .fileWritten(let path):
                addFile(path, to: assistantIndex)
            case .previewReady(let url):
                previewURL = url
            }
        }
        await refreshFiles()
        persistCurrentChat()
    }

    /// Plan-mode turn: stream a plan + reasoning, write nothing. The model's
    /// `<forgeQuestion>` blocks are parsed out of the text on completion and the
    /// message is marked `isPlan` so the UI can offer "Build this plan".
    private func runPlan(prompt: String, history: [ChatMessage], assistantIndex: Int) async {
        let config = selectedModel
        let systemPrompt = await composedSystemPrompt(mode: .plan)
        let touched = Self.recentTouched(from: messages)
        let deps = AgentLoop.Dependencies(
            provider: ModelRouter.provider(for: config),
            options: ModelRouter.options(for: config),
            process: processLayer,
            systemPrompt: systemPrompt,
            projectContext: { [workspace] in await AppModel.buildContext(workspace, touched: touched) },
            collectErrors: { ErrorReport() })

        for await event in AgentLoop(deps).run(userPrompt: prompt, history: history, mode: .plan) {
            switch event {
            case .assistantText(let text): appendAssistant(assistantIndex, text)
            case .reasoning(let text): appendReasoning(assistantIndex, text)
            case .state(let state):
                phase = state
                statusText = Self.statusText(for: state)
            default: break
            }
        }
        if messages.indices.contains(assistantIndex) {
            let (cleaned, questions) = PlanQuestionParser.extract(from: messages[assistantIndex].text)
            messages[assistantIndex].text = cleaned
            messages[assistantIndex].questions = questions
            messages[assistantIndex].isPlan = true
        }
        persistCurrentChat()
    }

    /// Approve a plan: switch to Build and ask the agent to implement it.
    func buildFromPlan() {
        guard !isBusy else { return }
        chatMode = .build
        draft = "Implement the plan above."
        submit()
    }

    /// Answer a clarifying question → continue planning with the choice.
    func answer(_ option: String, to question: PlanQuestion) {
        guard !isBusy else { return }
        chatMode = .plan
        draft = "For “\(question.question)” — \(option)."
        submit()
    }

    func handleRuntimeIssue(_ issue: RuntimeIssue) {
        jsErrors.append(issue)
        if jsErrors.count > 200 { jsErrors.removeFirst(jsErrors.count - 200) }
        let collector = errorCollector
        Task { await collector.submit([issue]) }
    }

    func reloadPreview() { reloadToken += 1 }

    func openInBrowser() {
        if let url = previewURL { NSWorkspace.shared.open(url) }
    }

    func shutdown() async {
        logTask?.cancel()
        await devServer.shutdown()
    }

    // MARK: - Helpers

    private func appendAssistant(_ index: Int, _ text: String) {
        guard messages.indices.contains(index) else { return }
        messages[index].text += text
    }

    private func appendReasoning(_ index: Int, _ text: String) {
        guard messages.indices.contains(index) else { return }
        messages[index].reasoning += text
    }

    private func addFile(_ path: String, to index: Int) {
        guard messages.indices.contains(index) else { return }
        if !messages[index].files.contains(path) { messages[index].files.append(path) }
    }

    private func chatHistory() -> [ChatMessage] {
        messages.map { ChatMessage(role: $0.role == .user ? .user : .assistant, content: $0.text) }
    }

    nonisolated static func buildContext(_ workspace: ProjectWorkspace, touched: [String]) async -> String? {
        let files = await workspace.fileMap()
        return await ContextBuilder().build(files: files, touched: touched) {
            try? await workspace.readFile($0)
        }
    }

    /// Most-recently-written unique files (across prior assistant turns), so the
    /// context builder can prioritize what the model just edited.
    static func recentTouched(from messages: [UIMessage]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for message in messages.reversed() where message.role == .assistant {
            for file in message.files.reversed() where seen.insert(file).inserted {
                result.append(file)
            }
            if result.count >= 8 { break }
        }
        return result
    }

    private func startLogStream() {
        logTask?.cancel()
        let devServer = self.devServer
        logTask = Task { [weak self] in
            for await event in await devServer.events() {
                guard let self else { break }
                switch event {
                case .log(let line):
                    self.serverLog.append(line)
                    if self.serverLog.count > 500 { self.serverLog.removeFirst(self.serverLog.count - 500) }
                case .ready(let url):
                    self.previewURL = url
                case .phase, .exited:
                    break
                }
            }
        }
    }

    static func statusText(for state: AgentState) -> String {
        switch state {
        case .idle: "Ready."
        case .building: "Thinking & writing code…"
        case .applying: "Installing & starting…"
        case .awaitingHMR: "Applying changes…"
        case .collectingErrors: "Checking for errors…"
        case .repairing(let attempt): "Fixing errors (attempt \(attempt))…"
        case .clean: "Done."
        case .failed(let reason): "Stopped: \(reason)"
        case .planning: "Planning…"
        case .planReady: "Plan ready."
        }
    }
}
