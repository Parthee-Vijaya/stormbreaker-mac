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
        mode: Mode = .build
    ) -> AsyncStream<AgentEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
        let task = Task {
            switch mode {
            case .build: await runLoop(userPrompt: userPrompt, history: history, continuation)
            case .plan: await runPlan(userPrompt: userPrompt, history: history, continuation)
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
        _ continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        do {
            let context = await deps.projectContext()
            let messages = MessageBuilder().build(
                systemPrompt: deps.systemPrompt,
                projectContext: context,
                history: history,
                userPrompt: userPrompt)
            continuation.yield(.state(.planning))
            let splitter = ReasoningSplitter()
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
        _ continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        do {
            let context = await deps.projectContext()
            var messages = MessageBuilder().build(
                systemPrompt: deps.systemPrompt,
                projectContext: context,
                history: history,
                userPrompt: userPrompt)

            var attempt = 0
            var lastSignature: String?

            while !Task.isCancelled {
                await deps.onTurnStart()

                continuation.yield(.state(.building))
                let rawAssistant = try await streamAndApply(messages: messages, continuation)

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
    /// Returns the raw assistant text (for the repair history).
    private func streamAndApply(
        messages: [ChatMessage],
        _ continuation: AsyncStream<AgentEvent>.Continuation
    ) async throws -> String {
        let parser = StreamingArtifactParser()
        let executor = ActionExecutor(process: deps.process)
        let splitter = ReasoningSplitter()
        var raw = ""

        // Route split pieces: reasoning to the UI, visible text through the
        // artifact parser. `raw` holds only the visible text (no <think>), so the
        // repair history stays clean. Inlined (not a nested async fn) to keep the
        // non-Sendable parser inside this actor method's isolation region.
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
                        try await apply(parserEvent, executor: executor, continuation)
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
                    try await apply(parserEvent, executor: executor, continuation)
                }
            }
        }
        for parserEvent in parser.finish() {
            try await apply(parserEvent, executor: executor, continuation)
        }
        return raw
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
