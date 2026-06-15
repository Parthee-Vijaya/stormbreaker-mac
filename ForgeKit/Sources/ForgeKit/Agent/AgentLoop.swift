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
            for try await event in deps.provider.stream(messages: messages, options: deps.options) {
                try Task.checkCancellation()
                let pieces: [ReasoningSplitter.Piece]
                switch event {
                case .reasoning(let r): continuation.yield(.reasoning(r)); continue
                case .token(let token): pieces = splitter.consume(token)
                case .done(_, let pt, let ct):
                    if let pt, let ct { continuation.yield(.usage(promptTokens: pt, completionTokens: ct)) }
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

            while !Task.isCancelled {
                await deps.onTurnStart()

                continuation.yield(.state(.building))
                let (rawAssistant, reads) = try await streamAndApply(messages: messages, continuation)

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
                messages.append(ChatMessage(role: .assistant, content: rawAssistant))
                messages.append(MessageBuilder().errorTurn(report))
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
    ) async throws -> (raw: String, reads: [String]) {
        let parser = StreamingArtifactParser()
        let executor = ActionExecutor(process: deps.process)
        let splitter = ReasoningSplitter()
        var raw = ""
        var reads: [String] = []

        // Synchronous triage of one parser event: collect read-requests (A2b) and
        // skip the flush on a read-only artifact's close; otherwise return the
        // event to apply. Nested (non-async) so the non-Sendable parser/executor
        // stay inside this actor method's isolation region.
        func toApply(_ event: ParserEvent) -> ParserEvent? {
            switch event {
            case .readRequest(let path):
                reads.append(path)
                continuation.yield(.assistantText("\n_Læser \(path)…_\n"))
                return nil
            case .artifactClose where !reads.isEmpty:
                return nil   // read-only artifact: don't install/start — the read-round handles it
            default:
                return event
            }
        }

        // Route split pieces: reasoning to the UI, visible text through the
        // artifact parser. `raw` holds only the visible text (no <think>), so the
        // repair history stays clean.
        for try await event in deps.provider.stream(messages: messages, options: deps.options) {
            try Task.checkCancellation()
            let pieces: [ReasoningSplitter.Piece]
            switch event {
            case .reasoning(let r): continuation.yield(.reasoning(r)); continue
            case .token(let token): pieces = splitter.consume(token)
            case .done: continue
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
        return (raw, reads)
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
