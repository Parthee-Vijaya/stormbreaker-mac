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

    private let deps: Dependencies

    public init(_ deps: Dependencies) { self.deps = deps }

    public nonisolated func run(userPrompt: String, history: [ChatMessage]) -> AsyncStream<AgentEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
        let task = Task { await runLoop(userPrompt: userPrompt, history: history, continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
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
        var raw = ""

        for try await event in deps.provider.stream(messages: messages, options: deps.options) {
            try Task.checkCancellation()
            guard case .token(let token) = event else { continue }
            raw += token
            for parserEvent in parser.consume(token) {
                try await apply(parserEvent, executor: executor, continuation)
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
