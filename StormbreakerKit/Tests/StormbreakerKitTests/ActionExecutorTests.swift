import XCTest
@testable import StormbreakerKit

/// Records calls so we can assert on ordering/coalescing without real processes.
private actor MockProcessLayer: ProcessLayer {
    var writes: [(String, String)] = []
    var installs: [[String]] = []
    var shells: [String] = []
    var startCount = 0
    var fileContents: [String: String] = [:]
    private var running = false
    private let url = URL(string: "http://localhost:5173")!

    func writeFile(_ relativePath: String, contents: String) async throws {
        writes.append((relativePath, contents))
        fileContents[relativePath] = contents
    }
    func readFile(_ relativePath: String) async throws -> String { fileContents[relativePath] ?? "" }
    func addDependencies(_ packages: [String]) async throws { installs.append(packages) }
    func runShell(_ command: String) async throws -> Int32 { shells.append(command); return 0 }
    func startDevServerIfNeeded() async throws -> URL { startCount += 1; running = true; return url }
    var serverReadyURL: URL? { get async { running ? url : nil } }

    func markRunning() { running = true }
}

final class ActionExecutorTests: XCTestCase {
    func testWritesFilesCoalescesDepsAndStartsOnce() async throws {
        let mock = MockProcessLayer()
        let executor = ActionExecutor(process: mock)
        let events: [ParserEvent] = [
            .artifactOpen(id: "x", title: "X"),
            .inlineAction(.addDependency(package: "clsx")),
            .inlineAction(.addDependency(package: "zustand")),
            .fileClose(path: "src/App.tsx", contents: "export default function App(){return null}"),
            .inlineAction(.shell(command: "echo hi")),
            .inlineAction(.start(command: "npm run dev")),
            .artifactClose,
        ]
        for event in events { try await executor.handle(event) }

        let writes = await mock.writes
        XCTAssertEqual(writes.map(\.0), ["src/App.tsx"])
        let installs = await mock.installs
        XCTAssertEqual(installs, [["clsx", "zustand"]])   // one coalesced install
        let shells = await mock.shells
        XCTAssertEqual(shells, ["echo hi"])
        let startCount = await mock.startCount
        XCTAssertEqual(startCount, 1)
    }

    func testSecondTurnDoesNotRestartRunningServer() async throws {
        let mock = MockProcessLayer()
        await mock.markRunning()                 // simulate server already up
        let executor = ActionExecutor(process: mock)

        try await executor.handle(.fileClose(path: "src/App.tsx", contents: "// edit"))
        try await executor.handle(.inlineAction(.start(command: "npm run dev")))
        try await executor.handle(.artifactClose)

        let startCount = await mock.startCount
        XCTAssertEqual(startCount, 0)            // no (re)start for a source edit
        let writes = await mock.writes
        XCTAssertEqual(writes.count, 1)
    }

    func testLineReplaceReadsAppliesAndWritesBack() async throws {
        let mock = MockProcessLayer()
        let executor = ActionExecutor(process: mock)
        try await executor.handle(.fileClose(path: "src/App.tsx", contents: "<h1>Old</h1>"))
        try await executor.handle(.lineReplaceClose(
            path: "src/App.tsx",
            edits: [LineEdit(search: "<h1>Old</h1>", replace: "<h1>New</h1>")]))

        let final = await mock.fileContents["src/App.tsx"]
        XCTAssertEqual(final, "<h1>New</h1>")
    }

    // Fase 1 (opencode borrow): the permission gate skips denied deps/shell + records them.
    func testDenyGateSkipsDepsAndShellButFilesStillWrite() async throws {
        let mock = MockProcessLayer()
        let executor = ActionExecutor(process: mock, gate: FixedGate(.deny))
        let events: [ParserEvent] = [
            .inlineAction(.addDependency(package: "left-pad")),
            .inlineAction(.shell(command: "git push origin main")),  // ask-classified → hits the gate
            .fileClose(path: "src/App.tsx", contents: "// ok"),
            .artifactClose,
        ]
        for event in events { try await executor.handle(event) }

        let installs = await mock.installs
        XCTAssertTrue(installs.isEmpty, "denied deps must not install")
        let shells = await mock.shells
        XCTAssertTrue(shells.isEmpty, "denied shell must not run")
        let writes = await mock.writes
        XCTAssertEqual(writes.map(\.0), ["src/App.tsx"], "file writes are NOT gated")
        let denied = await executor.denied
        XCTAssertEqual(denied.count, 2, "both denied actions recorded for model feedback")
    }

    // Per-command shell triage (opencode borrow): safe commands run WITHOUT asking
    // the gate, catastrophic ones are refused even under an allow-all gate.
    func testSafeShellRunsWithoutAskingDenyGate() async throws {
        let mock = MockProcessLayer()
        let executor = ActionExecutor(process: mock, gate: FixedGate(.deny))   // would deny if asked
        try await executor.handle(.inlineAction(.shell(command: "npm run build")))
        try await executor.handle(.artifactClose)
        let shells = await mock.shells
        XCTAssertEqual(shells, ["npm run build"], "safe dev command bypasses the gate")
        let denied = await executor.denied
        XCTAssertTrue(denied.isEmpty)
    }

    func testCatastrophicShellBlockedUnderAllowGate() async throws {
        let mock = MockProcessLayer()
        let executor = ActionExecutor(process: mock, gate: FixedGate(.allow))   // even if it says allow
        try await executor.handle(.inlineAction(.shell(command: "rm -rf /")))
        try await executor.handle(.artifactClose)
        let shells = await mock.shells
        XCTAssertTrue(shells.isEmpty, "catastrophic command never runs")
        let denied = await executor.denied
        XCTAssertEqual(denied.count, 1, "blocked command is reported back to the model")
    }

    func testAllowGateRunsDepsAndShell() async throws {
        let mock = MockProcessLayer()
        let executor = ActionExecutor(process: mock, gate: FixedGate(.allow))
        try await executor.handle(.inlineAction(.addDependency(package: "clsx")))
        try await executor.handle(.inlineAction(.shell(command: "echo hi")))
        try await executor.handle(.artifactClose)
        let installs = await mock.installs
        XCTAssertEqual(installs, [["clsx"]])
        let shells = await mock.shells
        XCTAssertEqual(shells, ["echo hi"])
        let denied = await executor.denied
        XCTAssertTrue(denied.isEmpty)
    }

    func testNoGateAllowsEverything() async throws {
        let mock = MockProcessLayer()
        let executor = ActionExecutor(process: mock)   // gate nil = allow-all (default)
        try await executor.handle(.inlineAction(.addDependency(package: "clsx")))
        try await executor.handle(.artifactClose)
        let installs = await mock.installs
        XCTAssertEqual(installs, [["clsx"]])
    }
}

/// A gate that always returns the same decision — for testing.
private struct FixedGate: PermissionGate {
    let decision: PermissionDecision
    init(_ decision: PermissionDecision) { self.decision = decision }
    func decide(_ request: PermissionRequest) async -> PermissionDecision { decision }
}
