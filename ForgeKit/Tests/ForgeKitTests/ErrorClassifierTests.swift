import XCTest
@testable import ForgeKit

final class ErrorClassifierTests: XCTestCase {
    private let classifier = ErrorClassifier()

    private func log(_ text: String) -> LogLine { LogLine(stream: .stderr, text: text) }

    // MARK: - Structured build-error parsing

    func testParsesTSCParenForm() {
        let item = classifier.classifyBuildLine("src/App.tsx(12,5): error TS2304: Cannot find name 'foo'.")
        XCTAssertEqual(item?.source, .build)
        XCTAssertEqual(item?.file, "src/App.tsx")
        XCTAssertEqual(item?.line, 12)
        XCTAssertEqual(item?.code, "TS2304")
    }

    func testParsesTSCColonForm() {
        let item = classifier.classifyBuildLine("src/components/Timer.tsx:8:3 - error TS2552: Cannot find name 'usestate'.")
        XCTAssertEqual(item?.file, "src/components/Timer.tsx")
        XCTAssertEqual(item?.line, 8)
        XCTAssertEqual(item?.code, "TS2552")
    }

    func testParsesEsbuildFileLocation() {
        let item = classifier.classifyBuildLine("src/App.tsx:5:10: ERROR: Expected \";\" but found \"const\"")
        XCTAssertEqual(item?.file, "src/App.tsx")
        XCTAssertEqual(item?.line, 5)
        XCTAssertNil(item?.code)
    }

    func testKeepsUnstructuredErrorWithoutLocation() {
        let item = classifier.classifyBuildLine("✘ [ERROR] Could not resolve \"./missing\"")
        XCTAssertEqual(item?.source, .build)
        XCTAssertNil(item?.file)
    }

    // MARK: - Noise filtering

    func testFiltersViteAndRollupNoise() {
        let noise = [
            "[vite] connecting...",
            "[vite] connected.",
            "[vite] hot updated: /src/App.tsx",
            "[vite] page reload src/App.tsx",
            "VITE v5.4.0  ready in 312 ms",
            "  ➜  Local:   http://localhost:5173/",
            "Found 0 errors. Watching for file changes.",
            "(!) Some chunks are larger than 500 kB after minification.",
            "npm warn deprecated foo@1.0.0",
        ]
        for line in noise {
            XCTAssertNil(classifier.classifyBuildLine(line), "should be noise: \(line)")
        }
    }

    func testIgnoresNonErrorChatter() {
        XCTAssertNil(classifier.classifyBuildLine("Building for development..."))
        XCTAssertNil(classifier.classifyBuildLine(""))
    }

    // MARK: - Runtime classification

    func testKeepsRealRuntimeCrash() {
        let issue = RuntimeIssue(kind: .onerror, message: "Uncaught TypeError: x is not a function", source: "App.tsx", line: 20)
        let item = classifier.classifyRuntime(issue)
        XCTAssertEqual(item?.source, .runtime)
        XCTAssertEqual(item?.file, "App.tsx")
        XCTAssertEqual(item?.line, 20)
    }

    func testFiltersReactDevWarning() {
        let warning = RuntimeIssue(kind: .consoleError, message: "Warning: Each child in a list should have a unique \"key\" prop.")
        XCTAssertNil(classifier.classifyRuntime(warning))
    }

    func testFiltersDevToolsHint() {
        let hint = RuntimeIssue(kind: .consoleError, message: "Download the React DevTools for a better development experience")
        XCTAssertNil(classifier.classifyRuntime(hint))
    }

    func testKeepsRealConsoleError() {
        let real = RuntimeIssue(kind: .consoleError, message: "Failed to fetch weather data")
        XCTAssertNotNil(classifier.classifyRuntime(real))
    }

    // MARK: - Dedup + report integration

    func testDedupsSameErrorReportedTwice() {
        let logs = [
            log("src/App.tsx:12:5: error TS2304: Cannot find name 'foo'."),
            log("src/App.tsx(12,5): error TS2304: Cannot find name 'foo'."),  // same file+line+code
        ]
        let report = classifier.report(logs: logs, runtime: [])
        XCTAssertEqual(report.items.count, 1)
    }

    func testReportKeepsOnlyRealErrors() {
        let logs = [
            log("[vite] connecting..."),
            log("VITE v5.4.0  ready in 200 ms"),
            log("src/App.tsx(3,7): error TS2304: Cannot find name 'Bar'."),
            log("Found 0 errors. Watching for file changes."),
        ]
        let runtime = [
            RuntimeIssue(kind: .consoleError, message: "Warning: deprecated lifecycle"),
            RuntimeIssue(kind: .onerror, message: "ReferenceError: bar is not defined", source: "App.tsx", line: 3),
        ]
        let report = classifier.report(logs: logs, runtime: runtime)
        XCTAssertEqual(report.items.count, 2)
        XCTAssertFalse(report.isClean)
    }

    func testCleanWhenNoErrors() {
        let report = classifier.report(logs: [log("[vite] connected."), log("Found 0 errors.")], runtime: [])
        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.signature, "")
    }

    func testSignatureStableAcrossLineDrift() {
        let a = classifier.report(logs: [log("src/App.tsx(12,5): error TS2304: Cannot find name 'foo'.")], runtime: [])
        let b = classifier.report(logs: [log("src/App.tsx(40,2): error TS2304: Cannot find name 'foo'.")], runtime: [])
        // Same file + code + message-shape, only the line/col moved → same signature.
        XCTAssertEqual(a.signature, b.signature)
    }
}
