import XCTest
@testable import StormbreakerKit

final class LocalContentTests: XCTestCase {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("lc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testReadsFileContents() {
        let d = tmpDir(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("hello.txt")
        try! "hej verden".write(to: f, atomically: true, encoding: .utf8)
        let out = try! XCTUnwrap(LocalContent.read(f.path))
        XCTAssertTrue(out.contains("FIL:"))
        XCTAssertTrue(out.contains("hej verden"))
    }

    func testListsDirectoryRecursivelyIncludingNestedFiles() {
        let d = tmpDir(); defer { try? FileManager.default.removeItem(at: d) }
        try! "<html>".write(to: d.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let pub = d.appendingPathComponent("public")
        try! FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        try! Data().write(to: pub.appendingPathComponent("bjarne-ja.jpeg"))
        try! Data().write(to: pub.appendingPathComponent("bjarne-nej.jpeg"))
        let out = try! XCTUnwrap(LocalContent.read(d.path))
        XCTAssertTrue(out.contains("MAPPE:"))
        XCTAssertTrue(out.contains("index.html"))
        XCTAssertTrue(out.contains("public/"))
        // The whole point of the fix: nested files (the images inside public/) must appear.
        XCTAssertTrue(out.contains("bjarne-ja.jpeg"), "nested image must appear in the recursive listing")
        XCTAssertTrue(out.contains("bjarne-nej.jpeg"))
    }

    func testMissingReturnsNil() {
        XCTAssertNil(LocalContent.read("/no/such/path/xyz123"))
    }

    func testResolveExistingFindsLongestPrefixThroughTrailingJunk() {
        let d = tmpDir(); defer { try? FileManager.default.removeItem(at: d) }
        let name = d.lastPathComponent
        // escaped spaces + trailing words (the exact shape from the bug report)
        XCTAssertEqual(LocalContent.resolveExisting(d.path + "/\\ -\\ kan\\ du")?.hasSuffix(name), true)
        XCTAssertEqual(LocalContent.resolveExisting(d.path)?.hasSuffix(name), true)
        XCTAssertNil(LocalContent.resolveExisting("/definitely/not/here/at/all"))
        XCTAssertNil(LocalContent.resolveExisting("relative/path"))   // only absolute paths
    }

    func testExtractPaths() {
        let paths = LocalContent.extractPaths("hvad med /Users/parthee/Desktop/x og ~/notes.md — ikke /")
        XCTAssertTrue(paths.contains("/Users/parthee/Desktop/x"))
        XCTAssertTrue(paths.contains("~/notes.md"))
        XCTAssertFalse(paths.contains("/"))   // bare slash skipped
    }
}
