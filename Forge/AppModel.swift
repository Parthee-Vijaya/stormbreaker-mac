import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
        var checkpoint: String?      // shadow-git sha snapshotted before this turn ran
        var imageDataURLs: [String] = []   // B4: images the user attached to this turn
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
    var attachedImages: [String] = []   // B4: pending image data URLs for the next turn
    var isBusy: Bool = false
    var isEnhancing: Bool = false        // B14: expanding the draft into a detailed brief
    var statusText: String = "Ready."
    var chatMode: AgentLoop.Mode = .build   // Plan vs Build toggle in the composer

    // Layout: the preview pane only appears once the first build has started.
    var hasStarted: Bool = false

    // Preview
    var previewURL: URL?
    var serverPhase: DevServerPhase = .idle   // dev-server lifecycle, mirrored for the preview UI
    var phase: AgentState = .idle
    var previewWidth: PreviewWidth = .full
    var reloadToken: Int = 0
    var rightPaneMode: RightPaneMode = .preview

    // Code view
    var projectFiles: [String] = []
    var selectedFile: String?
    var editorText: String = ""
    var editorDirty: Bool = false
    var isStreamingFile: Bool = false   // C2: a file is being "typed" live into the editor

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

    // Learning mode
    var currentLesson: Lesson?      // the explainer card currently shown (beginner)
    var showGlossary = false
    @ObservationIgnored private var lessonQueue: [String] = []   // milestone ids waiting to show

    // Start screen (clone from Git)
    var showCloneDialog = false
    var cloneURL = ""
    @ObservationIgnored private var cloneTask: Task<Void, Never>?

    // Copy a design from a link (offscreen screenshot → attached reference)
    var showLinkDialog = false
    var linkURL = ""
    var isCapturing = false
    @ObservationIgnored private var captureTask: Task<Void, Never>?

    // Diagnostics
    var serverLog: [LogLine] = []
    var jsErrors: [RuntimeIssue] = []
    var showConsole: Bool = false

    // Toasts (transient success/info confirmations)
    var toast: ToastMessage?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

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
    @ObservationIgnored private(set) var checkpoints: CheckpointManager
    @ObservationIgnored private var templateInstalled = false
    @ObservationIgnored private var agentTask: Task<Void, Never>?
    @ObservationIgnored private var autoFixTask: Task<Void, Never>?
    @ObservationIgnored private var lastAutoFixSignature: String?
    @ObservationIgnored private var streamingPath: String?      // file currently being typed live
    @ObservationIgnored private var autoEngagedCode = false      // auto-switched to Code for streaming
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
        // Open on the start screen (like Xcode/VS Code): the current canvas is a
        // fresh/empty project, while the worked-on projects stay as "Recent" in
        // the sidebar. Reuse an existing empty project so untitled ones don't pile up.
        let current: Project
        if let empty = loaded.first(where: { ProjectStore.loadChat(for: $0).isEmpty }) {
            current = empty
        } else {
            current = ProjectStore.makeProject(name: "Untitled")
            loaded.insert(current, at: 0)
            ProjectStore.saveProjects(loaded)
        }
        self.projects = loaded
        self.currentProject = current

        let workspace = ProjectWorkspace(root: ProjectStore.dir(for: current))
        let devServer = DevServerManager(workspace: workspace)
        self.workspace = workspace
        self.devServer = devServer
        self.processLayer = ForgeProcessLayer(workspace: workspace, devServer: devServer)
        self.errorCollector = ErrorCollector(devServer: devServer)
        self.checkpoints = CheckpointManager(root: ProjectStore.dir(for: current))

        if AppModel.isStaleModelID(prefs.defaultModelID) { self.preferences.defaultModelID = "" }
        self.availableModels = [.localDefault]
        let savedDefault = self.preferences.defaultModelID
        self.selectedModelID = savedDefault.isEmpty ? ModelConfig.localDefault.id : savedDefault

        self.messages = ProjectStore.loadChat(for: current)
        self.hasStarted = !messages.isEmpty
        self.templateInstalled = ProjectStore.hasBuiltApp(current)

        startLogStream()
        let resume = templateInstalled && !messages.isEmpty
        let devServerRef = devServer
        let projectsRootPath = ProjectStore.root.path
        Task {
            // Clear dev servers leaked by a previous session (a crash, or a
            // watchdog that didn't fire) BEFORE starting anything — otherwise a
            // stale one keeps holding its port and the preview can show the wrong
            // project. Off the main thread (ps + signals); completes before any
            // start() so it can't race-kill the server we're about to launch.
            await Task.detached(priority: .utility) {
                ProcessSupervisor.reclaimAllOrphans(under: URL(fileURLWithPath: projectsRootPath))
            }.value
            await refreshModels()
            if resume { try? await devServerRef.start() }
        }
    }

    var selectedModel: ModelConfig {
        availableModels.first { $0.id == selectedModelID } ?? .localDefault
    }

    /// Multi-model roles (B25). Plan/build/copy can each use a different model;
    /// an unset role falls back to the model picked in the header.
    enum ModelRole { case plan, build, copy }

    func modelFor(_ role: ModelRole) -> ModelConfig {
        let id: String
        switch role {
        case .plan: id = preferences.planModelID
        case .build: id = preferences.buildModelID
        case .copy: id = preferences.copyModelID
        }
        return availableModels.first { $0.id == id } ?? selectedModel
    }

    /// The configured Danish copy model, or nil if none is set / discovered.
    /// `nil` disables the copy-pass entirely.
    var copyModel: ModelConfig? {
        guard !preferences.copyModelID.isEmpty else { return nil }
        return availableModels.first { $0.id == preferences.copyModelID }
    }

    /// Whether the manual "Dansk copy" action is currently available.
    var canCopyPass: Bool { copyModel != nil && hasStarted && templateInstalled && !isBusy }

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
        models.first { $0.modelID.lowercased().contains("qwen3.6") }
            ?? models.first { $0.modelID.lowercased().contains("qwen") }
            ?? models.first ?? .localDefault
    }

    /// A saved default that no longer exists (the retired qwen2.5-coder) should
    /// not stick — treat it as unset so discovery picks the new default (qwen3.6).
    static func isStaleModelID(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("qwen2.5") || lower.contains("coder")
    }

    // MARK: - Preferences / config

    func savePreferences() { PreferencesStore.save(preferences) }

    /// The app's color scheme, driven by `Preferences.appearance` (Midnat dark by
    /// default). Applied at each window/sheet root via `.preferredColorScheme`.
    var colorScheme: ColorScheme { preferences.appearance == "light" ? .light : .dark }

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

    /// System prompt = role-specific base + user name + global memory + project
    /// AI_RULES.md. The base depends on the turn's role and the model driving it
    /// (line-replace capability gates the edit format).
    private func composedSystemPrompt(role: ModelRole, config: ModelConfig) async -> String {
        let base: String
        switch role {
        case .plan: base = SystemPrompt.plan
        case .build: base = SystemPrompt.forge(lineReplace: config.supportsLineReplace)
        case .copy: base = SystemPrompt.copyPass(lineReplace: config.supportsLineReplace)
        }
        var parts = [base]
        if preferences.learningMode, role != .copy {
            parts.append("""
            The user is a COMPLETE BEGINNER who is learning to code by using this tool. \
            Be warm and encouraging. Explain briefly, in plain language, what you are doing and \
            why — in Danish. The FIRST time you use a technical term (e.g. component, state, hook, \
            prop, dependency, deploy, commit), keep the English word and add a short Danish \
            explanation in parentheses, e.g. "en component (en genbrugelig byggeklods)". Never tell \
            them to edit files or run commands themselves. Keep it short — a couple of sentences \
            of plain explanation, then build.
            """)
        }
        if !greetingName.isEmpty {
            parts.append("The user you are helping is called \(greetingName). Address them by name when natural.")
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
        serverPhase = .idle
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
        self.checkpoints = CheckpointManager(root: ProjectStore.dir(for: project))
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

    /// A short, tidy project title from the first prompt: strips a leading
    /// imperative ("Byg en…", "Build a…"), cuts at the first clause boundary
    /// (":", ",", " med ", " with "…), keeps a few words, and capitalizes the
    /// first letter. Turns "Byg en todo-app: tilføj opgaver, marker" into
    /// "Todo-app" instead of a truncated sentence.
    static func projectName(from prompt: String) -> String {
        var s = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadIns = ["byg mig ", "lav mig ", "byg en ", "byg et ", "lav en ", "lav et ",
                       "kan du lave ", "kan du bygge ", "jeg vil gerne have ", "jeg vil have ",
                       "byg ", "lav ", "build me ", "build a ", "build an ", "create a ",
                       "create an ", "make me ", "make a ", "build ", "create ", "make ",
                       "en ", "et ", "a ", "an "]
        var strips = 0
        stripping: while strips < 3 {        // peel stacked lead-ins ("lav mig en …")
            let lower = s.lowercased()
            for lead in leadIns where lower.hasPrefix(lead) {
                s = String(s.dropFirst(lead.count)); strips += 1; continue stripping
            }
            break
        }
        for cutter in [":", ",", ".", " med ", " der ", " som ", " hvor ", " with ", " that ", " — ", " - "] {
            if let r = s.range(of: cutter, options: [.caseInsensitive]) { s = String(s[..<r.lowerBound]) }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = s.split(separator: " ").prefix(5).joined(separator: " ")
        let base = String((words.isEmpty ? s : words).prefix(36)).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return "Untitled" }
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    // MARK: - Deploy (GitHub + Vercel)

    func deploy() {
        guard !isDeploying, !isBusy, hasStarted else { return }
        presentLessonIfNew("deploy-git")
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
        if deployVercelURL != nil { showToast("Live på Vercel 🎉", icon: "checkmark.seal.fill") }
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

    // MARK: - Project access (B13 / B24)

    /// Open the project in an external editor, chosen by what it is: VS Code /
    /// Cursor for web projects, Xcode for native/Swift targets. Edits there flow
    /// to the live preview via Vite HMR. Falls back to Finder if none is found.
    func openInEditor() {
        let dir = ProjectStore.dir(for: currentProject)
        let candidates = projectIsNative(dir)
            ? ["com.apple.dt.Xcode"]
            : ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.vscodium", "com.apple.dt.Xcode"]
        for bundleID in candidates {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open([dir], withApplicationAt: appURL,
                                        configuration: NSWorkspace.OpenConfiguration())
                statusText = "Opened in \(appURL.deletingPathExtension().lastPathComponent)."
                return
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
        statusText = "No external editor found — revealed in Finder."
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([ProjectStore.dir(for: currentProject)])
    }

    /// Export the project as a zip (source only — no node_modules/.forge/.git).
    func exportZip() {
        let dir = ProjectStore.dir(for: currentProject)
        let panel = NSSavePanel()
        panel.title = "Export project"
        panel.nameFieldStringValue = "forge-\(Self.slug(currentProject.name)).zip"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let out = panel.url else { return }
        statusText = "Exporting…"
        Task {
            let ok = await Self.zipProject(at: dir, to: out)
            statusText = ok ? "Exported \(out.lastPathComponent)." : "Export failed."
            if ok { NSWorkspace.shared.activateFileViewerSelecting([out]) }
        }
    }

    private func projectIsNative(_ dir: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return true }
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return contents.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    nonisolated static func zipProject(at dir: URL, to out: URL) async -> Bool {
        try? FileManager.default.removeItem(at: out)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = dir
        process.arguments = ["-r", "-q", "-X", out.path, ".",
                             "-x", "node_modules/*", "*/node_modules/*",
                             ".forge/*", ".git/*", "dist/*", ".DS_Store"]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
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

    // MARK: - Learning mode (beginner)

    /// Queue a milestone explainer the first time it's relevant. No-op unless
    /// learning mode is on / already learned / already queued. Lessons that fire
    /// while another card is showing are QUEUED (not dropped), so none is lost
    /// when milestones land close together (e.g. a build going clean while the
    /// welcome card is still up).
    func presentLessonIfNew(_ id: String) {
        guard preferences.learningMode,
              !preferences.learnedLessons.contains(id),
              currentLesson?.id != id, !lessonQueue.contains(id),
              Lessons.lesson(id) != nil else { return }
        lessonQueue.append(id)
        showNextLesson()
    }

    /// Show the next queued lesson if no card is up. Marked learned only when
    /// actually shown (so a queued-but-unseen lesson re-fires later if missed).
    private func showNextLesson() {
        guard currentLesson == nil, !lessonQueue.isEmpty else { return }
        let id = lessonQueue.removeFirst()
        preferences.learnedLessons.append(id)
        savePreferences()
        currentLesson = Lessons.lesson(id)
    }

    func dismissLesson() {
        currentLesson = nil
        showNextLesson()
    }

    // MARK: - Code view

    /// Toggle the right pane between preview and code (⌘\). No-op before a build.
    func toggleRightPane() {
        guard hasStarted else { return }
        if rightPaneMode == .code { rightPaneMode = .preview } else { enterCodeMode() }
    }

    func enterCodeMode() {
        presentLessonIfNew("code-view")
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
        guard !isStreamingFile else { return }   // C2: live-typed chunks aren't user edits
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

    // MARK: - Start screen

    /// How to address the user: preferred name, else onboarding name, else nothing.
    var greetingName: String {
        let preferred = preferences.preferredName.trimmingCharacters(in: .whitespaces)
        if !preferred.isEmpty { return preferred }
        return preferences.userName.trimmingCharacters(in: .whitespaces)
    }

    /// The personalized start-screen heading.
    var startGreeting: String {
        greetingName.isEmpty ? "Hvad vil du bygge?" : "Hvad vil du bygge, \(greetingName)?"
    }

    /// Show the first-run name popup only once (until answered or skipped).
    var shouldAskPreferredName: Bool {
        preferences.preferredName.trimmingCharacters(in: .whitespaces).isEmpty && !preferences.askedPreferredName
    }

    func setPreferredName(_ name: String) {
        preferences.preferredName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.askedPreferredName = true
        savePreferences()
    }

    func skipPreferredNamePrompt() {
        preferences.askedPreferredName = true
        savePreferences()
    }

    /// B14: expand the short draft into a detailed build brief (one model turn),
    /// then replace the draft with it so the user can review and build. Uses the
    /// plan-role model (good at structure), falling back to the selected model.
    func enhancePrompt() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isBusy, !isEnhancing else { return }
        isEnhancing = true
        let config = modelFor(.plan)
        let provider = ModelRouter.provider(for: config)
        let options = ModelRouter.options(for: config)
        let messages = [
            ChatMessage(role: .system, content: SystemPrompt.enhance),
            ChatMessage(role: .user, content: prompt),
        ]
        Task {
            var raw = ""
            do {
                for try await event in provider.stream(messages: messages, options: options) {
                    if case .token(let token) = event { raw += token }
                }
            } catch {
                isEnhancing = false
                return   // leave the draft untouched on failure
            }
            let cleaned = Self.stripReasoning(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { draft = cleaned }
            isEnhancing = false
        }
    }

    /// Drop inline `<think>…</think>` reasoning a model may emit in its token text.
    static func stripReasoning(_ text: String) -> String {
        var out = text
        if let close = out.range(of: "</think>", options: .backwards) {
            out = String(out[close.upperBound...])   // keep only what follows the last </think>
        }
        out = out.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "",
                                       options: [.regularExpression, .caseInsensitive])
        return out
    }

    static let examplePrompts = [
        "En prisside med tre planer og en CTA",
        "En pomodoro-timer med start, pause og nulstil",
        "En todo-app med tilføj, fuldfør og slet",
        "En landingsside for en kaffebar med hero og menu",
    ]

    /// Fill a random example into the composer and build it.
    func tryExample() {
        guard !isBusy else { return }
        draft = Self.examplePrompts.randomElement() ?? "En todo-app med tilføj og fuldfør"
        submit()
    }

    /// Build from a starter template (B6): seed its detailed brief and submit.
    /// Forces Build mode so a card always produces a running app.
    func startFromTemplate(_ template: StarterTemplate) {
        guard !isBusy else { return }
        chatMode = .build
        draft = template.prompt
        submit()
    }

    /// Begin the guided tutorial: turn learning mode on, reset the lessons so the
    /// explainer cards re-fire, and seed a simple first build for the user to run.
    func startTutorial() {
        guard !isBusy else { return }
        preferences.learningMode = true
        preferences.learnedLessons = []
        savePreferences()
        draft = "En simpel todo-app med tilføj, fuldfør og slet"
    }

    /// Clone a Git repo into a new project, open it, and (if it's a Node/Vite
    /// project) install deps + start the dev server so the preview works.
    func cloneFromGit() {
        let url = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !isBusy else { return }
        showCloneDialog = false
        cloneURL = ""
        let name = Self.repoName(from: url)
        persistCurrentChat()
        let project = ProjectStore.makeProject(name: name)
        projects.insert(project, at: 0)
        ProjectStore.saveProjects(projects)
        activate(project, freshState: true)
        hasStarted = true
        isBusy = true
        phase = .applying
        statusText = "Kloner \(name)…"
        messages.append(UIMessage(role: .assistant, text: "Kloner **\(name)** fra Git…"))
        let index = messages.count - 1

        cloneTask = Task {
            await runCloneShell("git clone --depth 1 \(Self.shellQuote(url)) . 2>&1")
            let files = await workspace.fileMap()
            let cloned = !files.isEmpty
            var note: String
            if cloned, await workspace.fileExists("package.json") {
                statusText = "Installerer afhængigheder…"
                await runCloneShell("npm install 2>&1")
                templateInstalled = true
                let server = devServer
                Task { try? await server.start() }   // fire-and-forget; preview fills in via the log stream
                note = "Klonede **\(name)** og er ved at starte den. Bed mig om en ændring, eller åbn koden i Kode-visningen."
            } else if cloned {
                note = "Klonede **\(name)**. Det ligner ikke et Node/Vite-projekt, så jeg startede ikke en server — filerne er i Kode-visningen."
            } else {
                note = "Kunne ikke klone \(name). Tjek at URL'en er korrekt og at du har adgang til repoet."
            }
            if messages.indices.contains(index) { messages[index].text = note }
            await refreshFiles()
            rightPaneMode = .code
            phase = .idle
            statusText = cloned ? "Klonet." : "Klon fejlede."
            isBusy = false
            cloneTask = nil
            persistCurrentChat()
        }
    }

    private func runCloneShell(_ command: String) async {
        guard let (events, _) = try? await devServer.runShellCommand(command) else { return }
        for await event in events {
            if case .log(let line) = event {
                serverLog.append(line)
                if serverLog.count > 500 { serverLog.removeFirst(serverLog.count - 500) }
            }
        }
    }

    /// Last path component of a git URL, sans `.git`, as a project name.
    static func repoName(from url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        let noGit = trimmed.hasSuffix(".git") ? String(trimmed.dropLast(4)) : trimmed
        let last = noGit.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? "repo"
        let cleaned = last.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return cleaned.isEmpty ? "repo" : String(cleaned.prefix(40))
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Image attachments (B4)

    /// Open a file picker and attach the chosen image(s) to the next turn.
    func attachImagesFromPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Vedhæft"
        if panel.runModal() == .OK { attachImages(at: panel.urls) }
    }

    /// Attach image files (from the picker or a drag-and-drop), normalizing each
    /// to a downscaled JPEG data URL so the payload stays small and vision models
    /// accept it. Caps at 4 images per turn.
    func attachImages(at urls: [URL]) {
        for url in urls where attachedImages.count < 4 {
            if let dataURL = Self.encodeImageDataURL(from: url) { attachedImages.append(dataURL) }
        }
    }

    func removeAttachedImage(at index: Int) {
        guard attachedImages.indices.contains(index) else { return }
        attachedImages.remove(at: index)
    }

    /// "Copy this design from a link": render the page in an offscreen browser,
    /// snapshot it, and attach the screenshot as a visual reference for the next
    /// turn — so a URL works exactly like dropping a screenshot. Accepts bare
    /// hosts ("stripe.com") by defaulting to https://.
    func captureDesignFromLink() {
        let raw = linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !isCapturing, attachedImages.count < 4 else { return }
        let normalized = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: normalized), let host = url.host, !host.isEmpty else {
            statusText = "Ugyldig URL."
            return
        }
        showLinkDialog = false
        linkURL = ""
        isCapturing = true
        statusText = "Henter design fra \(host)…"
        captureTask = Task {
            defer { isCapturing = false; captureTask = nil }
            do {
                let image = try await DesignCapture().capture(url)
                if let dataURL = Self.encodeImageDataURL(from: image), attachedImages.count < 4 {
                    attachedImages.append(dataURL)
                    statusText = "Design hentet fra \(host) — beskriv evt. ændringer, eller send for at genskabe det."
                    showToast("Design hentet fra \(host)", icon: "photo")
                } else {
                    statusText = "Kunne ikke behandle skærmbilledet."
                }
            } catch {
                statusText = "Kunne ikke hente \(host) — tjek linket og din forbindelse."
            }
        }
    }

    /// Load an image file and encode it (see `encodeImageDataURL(from image:)`).
    static func encodeImageDataURL(from url: URL, maxDimension: CGFloat = 1568) -> String? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return encodeImageDataURL(from: image, maxDimension: maxDimension)
    }

    /// Downscale (longest side ≤ 1568px — a common vision-model cap) and re-encode
    /// an image to a base64 JPEG data URL. Returns nil if it can't be rasterized.
    /// Shared by file attachments and link/screenshot capture (the captured page
    /// rides the same image → vision-model pipeline).
    static func encodeImageDataURL(from image: NSImage, maxDimension: CGFloat = 1568) -> String? {
        guard let tiff = image.tiffRepresentation,
              let source = NSBitmapImageRep(data: tiff) else { return nil }
        let pw = source.pixelsWide, ph = source.pixelsHigh
        guard pw > 0, ph > 0 else { return nil }
        let longest = CGFloat(max(pw, ph))
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let tw = max(1, Int(CGFloat(pw) * scale)), th = max(1, Int(CGFloat(ph) * scale))

        guard let target = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: tw, pixelsHigh: th,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        target.size = NSSize(width: tw, height: th)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
        source.draw(in: NSRect(x: 0, y: 0, width: tw, height: th))
        NSGraphicsContext.restoreGraphicsState()

        guard let jpeg = target.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return nil }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    // MARK: - Chat submission

    func submit() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = attachedImages
        guard !prompt.isEmpty || !images.isEmpty, !isBusy else { return }
        draft = ""
        attachedImages = []
        let mode = chatMode
        let modelPrompt = Self.composeModelPrompt(prompt: prompt, hasImages: !images.isEmpty, mode: mode)
        let visiblePrompt = prompt.isEmpty ? "Kopiér dette design" : prompt
        if mode == .build { presentLessonIfNew("welcome") }
        beginTurn(visiblePrompt: visiblePrompt, modelPrompt: modelPrompt,
                  mode: mode, role: mode == .plan ? .plan : .build, images: images)
    }

    /// The prompt the model receives. With an attached design (uploaded screenshot
    /// or a captured link) we add explicit "copy this design" framing so the model
    /// recreates it faithfully — layout, sections, spacing, colors, typography —
    /// whether or not the user also typed instructions.
    static func composeModelPrompt(prompt: String, hasImages: Bool, mode: AgentLoop.Mode) -> String {
        guard hasImages else { return prompt }
        let copyDirective = "Recreate the attached design as closely as possible — match its layout, "
            + "sections, spacing, colors, typography and overall visual style. Use sensible "
            + "placeholder text and images where real content isn't legible in the reference."
        if prompt.isEmpty {
            return mode == .plan
                ? "Plan how to build a web app that recreates the attached design as closely as possible."
                : copyDirective
        }
        return "\(copyDirective)\n\nAdditional instructions from the user: \(prompt)"
    }

    /// Run the Danish copy-pass (B25): a normal build turn driven by the COPY
    /// model that rewrites all user-facing text to Danish. It reuses the full
    /// pipeline (snapshot → parser → executor → HMR → self-correction), so the
    /// pass is checkpointed and any breakage repairs itself. No-op if no copy
    /// model is configured.
    func runCopyPass() {
        guard canCopyPass else { return }
        let visible = "Oversæt appen til dansk"
        let instruction = "Localize ALL user-facing text in the current app into natural, "
            + "idiomatic Danish. Change ONLY the visible copy — keep code, structure, "
            + "imports, classNames, and logic identical."
        beginTurn(visiblePrompt: visible, modelPrompt: instruction, mode: .build, role: .copy)
    }

    /// Append a user+assistant message pair and kick off the agent task. Shared by
    /// `submit()` and `runCopyPass()`. `visiblePrompt` is what the chat shows;
    /// `modelPrompt` is what the model receives (they differ for the copy-pass).
    private func beginTurn(visiblePrompt: String, modelPrompt: String,
                           mode: AgentLoop.Mode, role: ModelRole, images: [String] = []) {
        if messages.isEmpty { renameCurrent(to: Self.projectName(from: visiblePrompt)) }
        hasStarted = true
        jsErrors = []                  // a new turn supersedes prior runtime errors
        lastAutoFixSignature = nil
        autoFixTask?.cancel()
        let history = chatHistory()
        messages.append(UIMessage(role: .user, text: visiblePrompt, imageDataURLs: images))
        messages.append(UIMessage(role: .assistant, text: ""))
        let assistantIndex = messages.count - 1
        isBusy = true

        agentTask = Task {
            await runAgent(prompt: modelPrompt, history: history,
                           assistantIndex: assistantIndex, mode: mode, role: role, images: images)
            let cancelled = Task.isCancelled
            if cancelled {
                phase = .idle
                statusText = "Stopped."
                if messages.indices.contains(assistantIndex), messages[assistantIndex].text.isEmpty {
                    messages[assistantIndex].text = "_Stopped._"
                }
            } else {
                statusText = Self.statusText(for: phase)
                // A turn that errored before producing any text would otherwise
                // sit on the "Working…" placeholder forever — surface why instead.
                if case .failed(let reason) = phase,
                   messages.indices.contains(assistantIndex),
                   messages[assistantIndex].text.isEmpty, messages[assistantIndex].reasoning.isEmpty {
                    messages[assistantIndex].text = "_Kunne ikke fuldføre: \(Self.briefReason(reason))_"
                }
            }
            isBusy = false
            agentTask = nil
            if !cancelled {
                if role == .copy, phase == .clean {
                    showToast("Dansk oversættelse færdig", icon: "character.bubble")
                }
                maybeAutoCopyPass(afterRole: role)
            }
        }
    }

    /// After a clean build, automatically run the Danish copy-pass if enabled.
    /// Gated on `role == .build` so a copy-pass never triggers itself (no loop)
    /// and a plan turn never triggers one.
    private func maybeAutoCopyPass(afterRole role: ModelRole) {
        guard role == .build, preferences.autoCopyPass, copyModel != nil, phase == .clean else { return }
        runCopyPass()
    }

    /// Cancel an in-flight generation. The AgentLoop's stream terminates on the
    /// consuming task's cancellation; partial assistant text + any files already
    /// written are kept.
    func cancelGeneration() {
        agentTask?.cancel()
    }

    private func runAgent(prompt: String, history: [ChatMessage], assistantIndex: Int,
                          mode: AgentLoop.Mode, role: ModelRole, images: [String] = []) async {
        if mode == .plan {
            await runPlan(prompt: prompt, history: history, assistantIndex: assistantIndex, images: images)
            return
        }
        // Checkpoint the pre-turn state so this turn can be rolled back.
        let preSha = await checkpoints.snapshot(label: prompt)
        if messages.indices.contains(assistantIndex) { messages[assistantIndex].checkpoint = preSha }
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

        let config = modelFor(role)
        let systemPrompt = await composedSystemPrompt(role: role, config: config)
        let touched = Self.recentTouched(from: messages)
        let deps = AgentLoop.Dependencies(
            provider: ModelRouter.provider(for: config),
            options: ModelRouter.options(for: config),
            process: processLayer,
            systemPrompt: systemPrompt,
            projectContext: { [workspace] in await AppModel.buildContext(workspace, touched: touched) },
            collectErrors: { [errorCollector] in await errorCollector.collect() },
            onTurnStart: { [errorCollector] in await errorCollector.reset() },
            readFile: { [workspace] path in try? await workspace.readFile(path) },
            settleDelay: .seconds(2),
            maxRepairAttempts: 3)

        for await event in AgentLoop(deps).run(userPrompt: prompt, history: history, images: images) {
            switch event {
            case .assistantText(let text):
                appendAssistant(assistantIndex, text)
            case .reasoning(let text):
                appendReasoning(assistantIndex, text)
            case .state(let state):
                phase = state
                statusText = Self.statusText(for: state)
                if case .clean = state { presentLessonIfNew("app-running") }
                if case .repairing = state { presentLessonIfNew("errors-fixing") }
            case .fileWriting(let path):
                statusText = "Writing \(path)…"
                beginStreaming(path)
            case .fileChunk(let path, let text):
                if path == streamingPath { editorText += text }
            case .fileWritten(let path):
                addFile(path, to: assistantIndex)
                if path == streamingPath { streamingPath = nil }
            case .previewReady(let url):
                previewURL = url
                endStreaming()
            }
        }
        endStreaming()
        await refreshFiles()
        persistCurrentChat()
    }

    /// C2 — stream the file being written into the editor: auto-switch to Code,
    /// clear the buffer, and let `.fileChunk` append to it (autosave suppressed).
    private func beginStreaming(_ path: String) {
        if rightPaneMode == .preview { autoEngagedCode = true; rightPaneMode = .code }
        selectedFile = path
        editorText = ""
        lastLoadedText = ""
        streamingPath = path
        isStreamingFile = true
    }

    private func endStreaming() {
        guard isStreamingFile else { return }
        isStreamingFile = false
        streamingPath = nil
        if autoEngagedCode { autoEngagedCode = false; rightPaneMode = .preview }
    }

    /// Plan-mode turn: stream a plan + reasoning, write nothing. The model's
    /// `<forgeQuestion>` blocks are parsed out of the text on completion and the
    /// message is marked `isPlan` so the UI can offer "Build this plan".
    private func runPlan(prompt: String, history: [ChatMessage], assistantIndex: Int, images: [String] = []) async {
        let config = modelFor(.plan)
        let systemPrompt = await composedSystemPrompt(role: .plan, config: config)
        let touched = Self.recentTouched(from: messages)
        let deps = AgentLoop.Dependencies(
            provider: ModelRouter.provider(for: config),
            options: ModelRouter.options(for: config),
            process: processLayer,
            systemPrompt: systemPrompt,
            projectContext: { [workspace] in await AppModel.buildContext(workspace, touched: touched) },
            collectErrors: { ErrorReport() })

        for await event in AgentLoop(deps).run(userPrompt: prompt, history: history, mode: .plan, images: images) {
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

    // MARK: - Checkpoints (B1/B2)

    /// Roll the project back to the state before `message`'s turn ran. Later
    /// turns' changes are discarded; the preview reloads.
    func restoreCheckpoint(_ message: UIMessage) {
        guard !isBusy, let sha = message.checkpoint else { return }
        let cp = checkpoints
        Task {
            await cp.restore(to: sha)
            await refreshFiles()
            reloadPreview()
            statusText = "Restored to checkpoint."
            showToast("Gendannet til tidligere version", icon: "arrow.uturn.backward")
        }
    }

    /// Unified diff of what `message`'s turn changed: from its pre-turn snapshot
    /// to the next turn's snapshot (or the working tree if it's the latest turn).
    func diffForTurn(_ message: UIMessage) async -> String {
        guard let sha = message.checkpoint else { return "" }
        return await checkpoints.diff(from: sha, to: nextCheckpointSha(after: message))
    }

    private func nextCheckpointSha(after message: UIMessage) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        for later in messages[messages.index(after: index)...] where later.checkpoint != nil {
            return later.checkpoint
        }
        return nil   // latest turn → diff against the working tree
    }

    func handleRuntimeIssue(_ issue: RuntimeIssue) {
        jsErrors.append(issue)
        if jsErrors.count > 200 { jsErrors.removeFirst(jsErrors.count - 200) }
        let collector = errorCollector
        Task { await collector.submit([issue]) }
        scheduleAutoFixIfEnabled()
    }

    /// Whether there are unaddressed runtime errors to offer a fix for.
    var hasFixableErrors: Bool { !jsErrors.isEmpty && hasStarted && !isBusy }

    /// Run a repair turn for the current runtime errors (B12). Manual entry point
    /// for the "Fix it" affordance; also used by auto-fix.
    func fixErrors() {
        guard hasFixableErrors else { return }
        let summary = jsErrors.suffix(3).map(\.displayMessage).joined(separator: "\n")
        draft = "The running app has a runtime error. Find and fix the root cause:\n\(summary)"
        submit()
    }

    /// Auto-fix: after an error burst settles, fire a repair turn — but only once
    /// per distinct error set, so a fix that doesn't resolve it can't loop.
    private func scheduleAutoFixIfEnabled() {
        guard preferences.autoFix, !isBusy, hasStarted else { return }
        autoFixTask?.cancel()
        autoFixTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, preferences.autoFix, !isBusy, hasStarted, !jsErrors.isEmpty else { return }
            let signature = jsErrors.suffix(3).map(\.displayMessage).joined(separator: "|")
            guard signature != lastAutoFixSignature else { return }
            lastAutoFixSignature = signature
            fixErrors()
        }
    }

    func reloadPreview() { reloadToken += 1 }

    /// Show a transient toast confirmation (auto-dismisses after a few seconds).
    /// Used for async successes that would otherwise change state silently.
    func showToast(_ text: String, icon: String = "checkmark.circle.fill",
                   style: ToastMessage.Style = .success) {
        toast = ToastMessage(text: text, icon: icon, style: style)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

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
                    self.serverPhase = .running(url: url)
                case .phase(let phase):
                    self.serverPhase = phase
                case .exited:
                    // Dev server stopped → drop the now-dead preview so we don't
                    // show a frozen page; the UI offers a restart instead.
                    self.previewURL = nil
                }
            }
        }
    }

    /// First line of a failure reason, capped — for an inline chat message.
    static func briefReason(_ reason: String) -> String {
        let firstLine = reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? reason
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
    }

    // MARK: - Preview status

    /// The dev server is actively coming up (installing / starting) but the
    /// preview isn't live yet.
    var isStartingPreview: Bool {
        guard previewURL == nil else { return false }
        switch serverPhase {
        case .installingDependencies, .startingServer, .running: return true
        default: return false
        }
    }

    /// A build finished but there's no live preview and the server isn't coming
    /// up — it failed or stopped, so we offer a restart.
    var previewServerDown: Bool {
        previewURL == nil && hasStarted && templateInstalled && !isBusy && !isStartingPreview
    }

    /// Status for the preview placeholder + chat. Never claims "Done" without a
    /// live preview — it reflects the dev server while it comes up.
    var displayStatus: String {
        if previewURL != nil { return Self.statusText(for: phase) }
        switch serverPhase {
        case .failed(let reason): return "Preview kunne ikke starte: \(Self.briefReason(reason))"
        case .installingDependencies: return "Installerer afhængigheder…"
        case .startingServer, .running: return "Forge starter preview…"
        case .stopped: return "Preview-serveren stoppede — genstart for at se den."
        case .idle:
            switch phase {
            case .clean, .idle, .planReady: return "Forge starter preview…"
            default: return Self.statusText(for: phase)   // building / repairing / failed…
            }
        }
    }

    /// Restart the dev server for the current project (after a crash, or when it
    /// never came up). Relaunches and the preview reappears once it's ready.
    func restartDevServer() {
        guard templateInstalled, !isBusy else { return }
        serverPhase = .startingServer
        statusText = "Forge starter preview…"
        let server = devServer
        Task { try? await server.restartForDependencyChange() }
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
