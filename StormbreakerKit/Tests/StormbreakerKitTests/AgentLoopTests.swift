import XCTest
@testable import StormbreakerKit

/// Emits a scripted artifact per call (one per loop attempt), chunked to
/// exercise the streaming parser.
private final class ScriptedModel: ChatModel, @unchecked Sendable {
    private let responses: [String]
    private let lock = NSLock()
    private var index = 0

    init(_ responses: [String]) { self.responses = responses }

    func stream(messages: [ChatMessage], options: GenerationOptions)
        -> AsyncThrowingStream<ChatStreamEvent, Error>
    {
        lock.lock()
        let text = responses[min(index, responses.count - 1)]
        index += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            var start = text.startIndex
            while start < text.endIndex {
                let end = text.index(start, offsetBy: 8, limitedBy: text.endIndex) ?? text.endIndex
                continuation.yield(.token(String(text[start..<end])))
                start = end
            }
            continuation.yield(.done(reason: "stop", promptTokens: nil, completionTokens: nil))
            continuation.finish()
        }
    }
}

private actor NoopProcess: ProcessLayer {
    private(set) var written: [String] = []
    private var running = false
    private let url = URL(string: "http://localhost:5173")!

    func writeFile(_ relativePath: String, contents: String) async throws { written.append(relativePath) }
    func readFile(_ relativePath: String) async throws -> String { "" }
    func addDependencies(_ packages: [String]) async throws {}
    func runShell(_ command: String) async throws -> Int32 { 0 }
    func startDevServerIfNeeded() async throws -> URL { running = true; return url }
    var serverReadyURL: URL? { get async { running ? url : nil } }
}

private actor ScriptedErrors {
    private let reports: [ErrorReport]
    private var index = 0
    init(_ reports: [ErrorReport]) { self.reports = reports }
    func next() -> ErrorReport {
        defer { index += 1 }
        return index < reports.count ? reports[index] : ErrorReport()
    }
}

/// Records web-tool calls and returns canned content.
private actor WebRecorder {
    private(set) var calls: [(WebRequestKind, String)] = []
    func fetch(_ kind: WebRequestKind, _ query: String) -> String {
        calls.append((kind, query))
        return "REFERENCE about \(query)"
    }
}

final class AgentLoopTests: XCTestCase {
    private let artifact = """
    Building it now.
    <forgeArtifact id="a" title="A">
    <forgeAction type="file" filePath="src/App.tsx">export default function App(){return <div>hi</div>}</forgeAction>
    <forgeAction type="start">npm run dev</forgeAction>
    </forgeArtifact>
    """

    private func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in stream { events.append(event) }
        return events
    }
    private func states(_ events: [AgentEvent]) -> [AgentState] {
        events.compactMap { if case .state(let s) = $0 { return s }; return nil }
    }
    private func hasFailure(_ states: [AgentState]) -> Bool {
        states.contains { if case .failed = $0 { return true }; return false }
    }

    func testCleanFirstTry() async throws {
        let process = NoopProcess()
        let errors = ScriptedErrors([ErrorReport()])  // clean
        let loop = AgentLoop(.init(
            provider: ScriptedModel([artifact]),
            options: GenerationOptions(),
            process: process,
            collectErrors: { await errors.next() },
            settleDelay: .milliseconds(1)))

        let events = await collect(loop.run(userPrompt: "build a thing", history: []))
        let s = states(events)

        XCTAssertTrue(s.contains(.clean))
        XCTAssertFalse(hasFailure(s))
        let written = await process.written
        XCTAssertEqual(written, ["src/App.tsx"])
        XCTAssertTrue(events.contains { if case .previewReady = $0 { return true }; return false })
        // Prose surfaced, artifact internals not.
        let prose = events.compactMap { if case .assistantText(let t) = $0 { return t }; return nil }.joined()
        XCTAssertTrue(prose.contains("Building it now."))
        XCTAssertFalse(prose.contains("forgeAction"))
    }

    func testRepairsThenClean() async throws {
        let errors = ScriptedErrors([
            ErrorReport(items: [.init(source: .build, message: "src/App.tsx:3 Cannot find name 'foo'")]),
            ErrorReport(),  // clean after the repair
        ])
        let loop = AgentLoop(.init(
            provider: ScriptedModel([artifact, artifact]),
            options: GenerationOptions(),
            process: NoopProcess(),
            collectErrors: { await errors.next() },
            settleDelay: .milliseconds(1)))

        let s = states(await collect(loop.run(userPrompt: "x", history: [])))
        XCTAssertTrue(s.contains(.repairing(attempt: 1)))
        XCTAssertTrue(s.contains(.clean))
        XCTAssertFalse(hasFailure(s))
    }

    func testWebRoundFeedsResultsBackThenBuilds() async throws {
        let lookup = """
        Let me check the current API.
        <forgeArtifact id="r" title="Look it up">
        <forgeAction type="web-search">react router v7 api</forgeAction>
        </forgeArtifact>
        """
        let web = WebRecorder()
        let errors = ScriptedErrors([ErrorReport()])  // clean once the build response lands
        let loop = AgentLoop(.init(
            provider: ScriptedModel([lookup, artifact]),  // 1) web lookup, 2) the build
            options: GenerationOptions(),
            process: NoopProcess(),
            collectErrors: { await errors.next() },
            fetchWeb: { kind, q in await web.fetch(kind, q) },
            settleDelay: .milliseconds(1)))

        let events = await collect(loop.run(userPrompt: "use react router v7", history: []))
        let s = states(events)

        let calls = await web.calls
        XCTAssertEqual(calls.count, 1, "web tool called exactly once")
        XCTAssertEqual(calls.first?.0, .search)
        XCTAssertEqual(calls.first?.1, "react router v7 api")
        XCTAssertTrue(s.contains(.clean), "the web round is not a repair — build still converges")
        XCTAssertFalse(hasFailure(s))
    }

    func testTodoUpdatesSurfacedAsEventsWithoutBlockingBuild() async throws {
        let withTodos = """
        Planning.
        <forgeArtifact id="a" title="A">
        <forgeAction type="todo">
        [~] Build the thing
        [ ] Polish
        </forgeAction>
        <forgeAction type="file" filePath="src/App.tsx">export default function App(){return <div>hi</div>}</forgeAction>
        <forgeAction type="start">npm run dev</forgeAction>
        </forgeArtifact>
        """
        let process = NoopProcess()
        let errors = ScriptedErrors([ErrorReport()])
        let loop = AgentLoop(.init(
            provider: ScriptedModel([withTodos]),
            options: GenerationOptions(),
            process: process,
            collectErrors: { await errors.next() },
            settleDelay: .milliseconds(1)))

        let events = await collect(loop.run(userPrompt: "x", history: []))
        let todoEvents = events.compactMap { e -> [TodoItem]? in
            if case .todos(let t) = e { return t }; return nil
        }
        XCTAssertEqual(todoEvents.count, 1)
        XCTAssertEqual(todoEvents.first?.count, 2)
        XCTAssertEqual(todoEvents.first?.first?.status, .active)
        XCTAssertTrue(states(events).contains(.clean), "todo is not a tool round/repair — the build still completes")
        let written = await process.written
        XCTAssertEqual(written, ["src/App.tsx"], "todo action doesn't block the file write")
    }

    func testPlanModeStreamsPlanAndWritesNothing() async throws {
        let plan = "Here is the plan:\n1. Create src/App.tsx\n2. Add a centered button"
        let process = NoopProcess()
        let loop = AgentLoop(.init(
            provider: ScriptedModel([plan]),
            options: GenerationOptions(),
            process: process,
            collectErrors: { ErrorReport() },
            settleDelay: .milliseconds(1)))

        let events = await collect(loop.run(userPrompt: "build x", history: [], mode: .plan))
        let s = states(events)
        XCTAssertTrue(s.contains(.planning))
        XCTAssertTrue(s.contains(.planReady))
        XCTAssertFalse(hasFailure(s))

        let written = await process.written
        XCTAssertTrue(written.isEmpty, "plan mode must not write files")
        let prose = events.compactMap { if case .assistantText(let t) = $0 { return t }; return nil }.joined()
        XCTAssertTrue(prose.contains("Here is the plan"))
    }

    func testReasoningSplitFromInlineThink() async throws {
        let response = "<think>weighing layout options</think>The answer is a grid."
        let loop = AgentLoop(.init(
            provider: ScriptedModel([response]),
            options: GenerationOptions(),
            process: NoopProcess(),
            collectErrors: { ErrorReport() },
            settleDelay: .milliseconds(1)))

        let events = await collect(loop.run(userPrompt: "x", history: [], mode: .plan))
        let reasoning = events.compactMap { if case .reasoning(let r) = $0 { return r }; return nil }.joined()
        let prose = events.compactMap { if case .assistantText(let t) = $0 { return t }; return nil }.joined()
        XCTAssertTrue(reasoning.contains("weighing layout options"))
        XCTAssertTrue(prose.contains("The answer is a grid."))
        XCTAssertFalse(prose.contains("<think>"))
    }

    func testNoProgressStops() async throws {
        let sameError = ErrorReport(items: [.init(source: .build, message: "src/App.tsx:3 boom")])
        let errors = ScriptedErrors([sameError, sameError])  // identical signature twice
        let loop = AgentLoop(.init(
            provider: ScriptedModel([artifact, artifact, artifact]),
            options: GenerationOptions(),
            process: NoopProcess(),
            collectErrors: { await errors.next() },
            settleDelay: .milliseconds(1)))

        let s = states(await collect(loop.run(userPrompt: "x", history: [])))
        XCTAssertTrue(hasFailure(s))
        XCTAssertFalse(s.contains(.clean))
    }
}
