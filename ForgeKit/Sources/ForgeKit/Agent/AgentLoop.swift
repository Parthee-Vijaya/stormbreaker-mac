import Foundation

/// The agent loop: build messages → stream the model → parse the artifact →
/// apply actions (write files, install deps, start the server) → let it settle →
/// collect errors → repair (≤ maxRepairAttempts, with a no-progress guard) →
/// clean / failed.
///
/// Dependencies are injected so the loop is testable without a live model or
/// dev server.
public actor AgentLoop {
    public struct Dependencies: Sendable {
        public var provider: any ChatModel
        public var options: GenerationOptions
        public var process: any ProcessLayer
        public var systemPrompt: String
        public var projectContext: @Sendable () async -> String?
        public var collectErrors: @Sendable () async -> ErrorReport
        public var onTurnStart: @Sendable () async -> Void
        /// A2b: returns a project file's current contents (nil if it doesn't
        /// exist) when the model asks to read it mid-build.
        public var readFile: @Sendable (String) async -> String?
        /// Call an external MCP tool (server, tool, JSON arguments) → text result.
        public var callMCP: @Sendable (String, String, String) async -> String
        public var settleDelay: Duration
        public var maxRepairAttempts: Int

        public init(
            provider: any ChatModel,
            options: GenerationOptions,
            process: any ProcessLayer,
            systemPrompt: String = SystemPrompt.forge,
            projectContext: @escaping @Sendable () async -> String? = { nil },
            collectErrors: @escaping @Sendable () async -> ErrorReport,
            onTurnStart: @escaping @Sendable () async -> Void = {},
            readFile: @escaping @Sendable (String) async -> String? = { _ in nil },
            callMCP: @escaping @Sendable (String, String, String) async -> String = { _, _, _ in "" },
            settleDelay: Duration = .seconds(2),
            maxRepairAttempts: Int = 3
        ) {
            self.provider = provider
            self.options = options
            self.process = process
            self.systemPrompt = systemPrompt
            self.projectContext = projectContext
            self.collectErrors = collectErrors
            self.onTurnStart = onTurnStart
            self.readFile = readFile
            self.callMCP = callMCP
            self.settleDelay = settleDelay
            self.maxRepairAttempts = maxRepairAttempts
        }
    }

    /// Build = the full write/install/start/self-correct loop. Plan = a single
    /// streaming turn that proposes a plan and never touches the project.
    public enum Mode: Sendable, Hashable, CaseIterable { case build, plan }

    private let deps: Dependencies

    public init(_ deps: Dependencies) { self.deps = deps }

    public nonisolated func run(
        userPrompt: String,
        history: [ChatMessage],
        mode: Mode = .build,
        images: [String] = []
    ) -> AsyncStream<AgentEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
        let task = Task {
            switch mode {
            case .build: await runLoop(userPrompt: userPrompt, history: history, images: images, continuation)
            case .plan: await runPlan(userPrompt: userPrompt, history: history, images: images, continuation)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Plan mode: one streaming turn (reasoning + plan prose), no actions, no dev
    /// server, no error loop. The caller's `deps.systemPrompt` is the plan prompt.
    private func runPlan(
        userPrompt: String,
        history: [ChatMessage],
        images: [String] = [],
        _ continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        do {
            let context = await deps.projectContext()
            let messages = MessageBuilder().build(
                systemPrompt: deps.systemPrompt,
                projectContext: context,
                history: history,
                userPrompt: userPrompt,
                images: images)
            continuation.yield(.state(.planning))
            let splitter = ReasoningSplitter()
            let clock = ContinuousClock()
            let started = clock.now
            var firstTokenAt: ContinuousClock.Instant?
            for try await event in deps.provider.stream(messages: messages, options: deps.options) {
                try Task.checkCancellation()
                let pieces: [ReasoningSplitter.Piece]
                switch event {
                case .reasoning(let r):
                    if firstTokenAt == nil { firstTokenAt = clock.now }
                    continuation.yield(.reasoning(r)); continue
                case .token(let token):
                    if firstTokenAt == nil { firstTokenAt = clock.now }
                    pieces = splitter.consume(token)
                case .done(_, let pt, let ct):
                    if let pt, let ct { continuation.yield(.usage(promptTokens: pt, completionTokens: ct)) }
                    continuation.yield(.metrics(GenerationMetrics(
                        promptTokens: pt ?? 0, completionTokens: ct ?? 0,
                        timeToFirstTokenSeconds: firstTokenAt.map { started.duration(to: $0).seconds },
                        totalSeconds: started.duration(to: clock.now).seconds)))
                    continue
                }
                for piece in pieces {
                    switch piece {
                    case .reasoning(let r): continuation.yield(.reasoning(r))
                    case .text(let text): continuation.yield(.assistantText(text))
                    }
                }
            }
            for piece in splitter.finish() {
                switch piece {
                case .reasoning(let r): continuation.yield(.reasoning(r))
                case .text(let text): continuation.yield(.assistantText(text))
                }
            }
            continuation.yield(.state(.planReady))
        } catch is CancellationError {
            // user stopped planning
        } catch {
            continuation.yield(.state(.failed(String(describing: error))))
        }
        continuation.finish()
    }

    private func runLoop(
        userPrompt: String,
        history: [ChatMessage],
        images: [String] = [],
        _ continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        do {
            let context = await deps.projectContext()
            var messages = MessageBuilder().build(
                systemPrompt: deps.systemPrompt,
                projectContext: context,
                history: history,
                userPrompt: userPrompt,
                images: images)

            var attempt = 0
            var lastSignature: String?
            var readRounds = 0
            var toolRounds = 0

            while !Task.isCancelled {
                await deps.onTurnStart()

                continuation.yield(.state(.building))
                let (rawAssistant, reads, mcpReqs) = try await streamAndApply(messages: messages, continuation)

                // A2b: the model asked to see files before building. Fetch them,
                // feed them back, and let it continue — not counted as a repair.
                if !reads.isEmpty, readRounds < 3 {
                    readRounds += 1
                    var fetched: [(path: String, contents: String?)] = []
                    for path in reads { fetched.append((path, await deps.readFile(path))) }
                    messages.append(ChatMessage(role: .assistant, content: rawAssistant))
                    messages.append(MessageBuilder().readResultTurn(fetched))
                    continue
                }

                // The model called external MCP tools. Run them, feed the results
                // back, and continue — like the read round, not counted as a repair.
                if !mcpReqs.isEmpty, toolRounds < 5 {
                    toolRounds += 1
                    var results: [(server: String, tool: String, output: String)] = []
                    for r in mcpReqs {
                        results.append((r.server, r.tool, await deps.callMCP(r.server, r.tool, r.arguments)))
                    }
                    messages.append(ChatMessage(role: .assistant, content: rawAssistant))
                    messages.append(MessageBuilder().mcpResultTurn(results))
                    continue
                }

                continuation.yield(.state(.awaitingHMR))
                try? await Task.sleep(for: deps.settleDelay)

                continuation.yield(.state(.collectingErrors))
                let report = await deps.collectErrors()

                if report.isClean {
                    continuation.yield(.state(.clean))
                    break
                }
                if lastSignature == report.signature {
                    continuation.yield(.state(.failed("Could not resolve:\n\(report.formatted())")))
                    break
                }
                attempt += 1
                if attempt > deps.maxRepairAttempts {
                    continuation.yield(.state(.failed(report.formatted())))
                    break
                }
                lastSignature = report.signature
                continuation.yield(.state(.repairing(attempt: attempt)))
                // A11: fetch the current contents of the failing files (max 3, deduped)
                // so the repair turn edits the real code instead of guessing.
                var failFiles: [(path: String, contents: String?)] = []
                var seenPaths = Set<String>()
                for item in report.items {
                    guard let path = item.file, seenPaths.insert(path).inserted else { continue }
                    failFiles.append((path, await deps.readFile(path)))
                    if failFiles.count >= 3 { break }
                }
                messages.append(ChatMessage(role: .assistant, content: rawAssistant))
                messages.append(MessageBuilder().errorTurn(report, files: failFiles))
            }
        } catch is CancellationError {
            // caller terminated the stream
        } catch {
            continuation.yield(.state(.failed(String(describing: error))))
        }
        continuation.finish()
    }

    /// Stream one model response, parse it, and apply actions as they close.
    /// Returns the raw assistant text (for the repair history) and any files the
    /// model asked to read (A2b).
    private func streamAndApply(
        messages: [ChatMessage],
        _ continuation: AsyncStream<AgentEvent>.Continuation
    ) async throws -> (raw: String, reads: [String], mcp: [(server: String, tool: String, arguments: String)]) {
        let parser = StreamingArtifactParser()
        let executor = ActionExecutor(process: deps.process)
        let splitter = ReasoningSplitter()
        var raw = ""
        var reads: [String] = []
        var mcpReqs: [(server: String, tool: String, arguments: String)] = []
        var sawArtifactClose = false
        var wroteFiles = false

        // Synchronous triage of one parser event: collect read-requests (A2b) and MCP
        // tool calls, skip the flush on a tool-request artifact's close; otherwise
        // return the event to apply. Nested (non-async) so the non-Sendable parser/
        // executor stay inside this actor method's isolation region.
        func toApply(_ event: ParserEvent) -> ParserEvent? {
            switch event {
            case .readRequest(let path):
                reads.append(path)
                continuation.yield(.assistantText("\n_Læser \(path)…_\n"))
                return nil
            case .mcpRequest(let server, let tool, let arguments):
                mcpReqs.append((server, tool, arguments))
                continuation.yield(.assistantText("\n_Kalder \(server)/\(tool)…_\n"))
                return nil
            case .artifactClose where !reads.isEmpty || !mcpReqs.isEmpty:
                return nil   // tool-request artifact: don't install/start — the tool round handles it
            case .artifactClose:
                sawArtifactClose = true
                return event
            case .fileClose, .lineReplaceClose:
                wroteFiles = true
                return event
            default:
                return event
            }
        }

        // Route split pieces: reasoning to the UI, visible text through the
        // artifact parser. `raw` holds only the visible text (no <think>), so the
        // repair history stays clean.
        let clock = ContinuousClock()
        let started = clock.now
        var firstTokenAt: ContinuousClock.Instant?
        for try await event in deps.provider.stream(messages: messages, options: deps.options) {
            try Task.checkCancellation()
            let pieces: [ReasoningSplitter.Piece]
            switch event {
            case .reasoning(let r):
                if firstTokenAt == nil { firstTokenAt = clock.now }
                continuation.yield(.reasoning(r)); continue
            case .token(let token):
                if firstTokenAt == nil { firstTokenAt = clock.now }
                pieces = splitter.consume(token)
            case .done(_, let pt, let ct):
                if let pt, let ct { continuation.yield(.usage(promptTokens: pt, completionTokens: ct)) }
                continuation.yield(.metrics(GenerationMetrics(
                    promptTokens: pt ?? 0, completionTokens: ct ?? 0,
                    timeToFirstTokenSeconds: firstTokenAt.map { started.duration(to: $0).seconds },
                    totalSeconds: started.duration(to: clock.now).seconds)))
                continue
            }
            for piece in pieces {
                switch piece {
                case .reasoning(let r): continuation.yield(.reasoning(r))
                case .text(let text):
                    raw += text
                    for parserEvent in parser.consume(text) {
                        if let event = toApply(parserEvent) {
                            try await apply(event, executor: executor, continuation)
                        }
                    }
                }
            }
        }
        for piece in splitter.finish() {
            switch piece {
            case .reasoning(let r): continuation.yield(.reasoning(r))
            case .text(let text):
                raw += text
                for parserEvent in parser.consume(text) {
                    if let event = toApply(parserEvent) {
                        try await apply(event, executor: executor, continuation)
                    }
                }
            }
        }
        for parserEvent in parser.finish() {
            if let event = toApply(parserEvent) {
                try await apply(event, executor: executor, continuation)
            }
        }

        // Robustness: the dev-server start lives in artifact-close (flush). If the
        // model wrote files but never emitted a clean </forgeArtifact> (seen with
        // less-familiar frameworks and smaller models), flush anyway — otherwise the
        // loop settles and reports CLEAN against a server that never started (a blank
        // "done"). Skipped on read-rounds and when artifact-close already flushed.
        if reads.isEmpty, mcpReqs.isEmpty, !sawArtifactClose, wroteFiles {
            continuation.yield(.state(.applying))
            try await executor.flush()
            if let url = await deps.process.serverReadyURL {
                continuation.yield(.previewReady(url))
            }
        }

        return (raw, reads, mcpReqs)
    }

    private func apply(
        _ event: ParserEvent,
        executor: ActionExecutor,
        _ continuation: AsyncStream<AgentEvent>.Continuation
    ) async throws {
        switch event {
        case .text(let text):
            continuation.yield(.assistantText(text))
        case .fileOpen(let path), .lineReplaceOpen(let path):
            continuation.yield(.fileWriting(path))
        case .fileChunk(let path, let text):
            continuation.yield(.fileChunk(path, text))
        case .fileClose(let path, _), .lineReplaceClose(let path, _):
            try await executor.handle(event)
            continuation.yield(.fileWritten(path))
        case .artifactClose:
            continuation.yield(.state(.applying))
            try await executor.handle(event)
            if let url = await deps.process.serverReadyURL {
                continuation.yield(.previewReady(url))
            }
        default:
            try await executor.handle(event)
        }
    }
}
