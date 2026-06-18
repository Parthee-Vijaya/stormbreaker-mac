import XCTest
@testable import StormbreakerKit

/// The description must surface the captured log tail (the actual npm/vite output)
/// so an install/dev-server failure is diagnosable, not just "exit code 1".
final class DevServerErrorTests: XCTestCase {
    func testInstallFailedSurfacesNpmTail() {
        let tail = [
            LogLine(stream: .stderr, text: "npm error code E404"),
            LogLine(stream: .stderr, text: "npm error 404 Not Found - GET https://registry.npmjs.org/nope"),
        ]
        let desc = DevServerError.installFailed(exitCode: 1, tail: tail).description
        XCTAssertTrue(desc.contains("exit code 1"))
        XCTAssertTrue(desc.contains("E404"))
        XCTAssertTrue(desc.contains("404 Not Found"))
    }

    func testServerFailedSurfacesTail() {
        let tail = [LogLine(stream: .stdout, text: "Error: Cannot find module 'missing'")]
        let desc = DevServerError.serverFailedToStart(tail: tail).description
        XCTAssertTrue(desc.contains("Cannot find module"))
    }

    func testEmptyTailHasNoTrailingNewline() {
        XCTAssertFalse(DevServerError.installFailed(exitCode: 1, tail: []).description.hasSuffix("\n"))
        XCTAssertFalse(DevServerError.serverFailedToStart(tail: []).description.hasSuffix("\n"))
    }

    func testBlankLinesFiltered() {
        let tail = [LogLine(stream: .stderr, text: "   "), LogLine(stream: .stderr, text: "real error")]
        let desc = DevServerError.installFailed(exitCode: 2, tail: tail).description
        XCTAssertTrue(desc.contains("real error"))
        XCTAssertFalse(desc.contains("   \n"))
    }
}
