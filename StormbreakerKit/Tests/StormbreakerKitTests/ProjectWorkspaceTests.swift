import XCTest
@testable import StormbreakerKit

final class ProjectWorkspaceTests: XCTestCase {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("storm-test-\(UUID().uuidString)")
    }

    func testWritesAndReadsFileCreatingParents() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = ProjectWorkspace(root: root)

        try await workspace.writeFile("src/components/Card.tsx", contents: "export const x = 1")
        let exists = await workspace.fileExists("src/components/Card.tsx")
        XCTAssertTrue(exists)
        let read = try await workspace.readFile("src/components/Card.tsx")
        XCTAssertEqual(read, "export const x = 1")
    }

    func testRejectsPathEscapingRoot() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = ProjectWorkspace(root: root)

        do {
            try await workspace.writeFile("../../escape.txt", contents: "nope")
            XCTFail("expected a path escape to throw")
        } catch let error as DevServerError {
            XCTAssertEqual(error, .projectDirectoryUnwritable(path: "../../escape.txt"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRejectsWriteThroughInternalSymlink() async throws {
        let root = tempRoot()
        let outside = tempRoot()   // a sibling dir the jail must NOT reach
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        // A symlink INSIDE the project pointing to an outside directory.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside)

        let workspace = ProjectWorkspace(root: root)
        do {
            try await workspace.writeFile("escape/pwned.txt", contents: "nope")
            XCTFail("write through an internal symlink should be rejected")
        } catch let error as DevServerError {
            XCTAssertEqual(error, .projectDirectoryUnwritable(path: "escape/pwned.txt"))
        }
        let leaked = FileManager.default.fileExists(atPath: outside.appendingPathComponent("pwned.txt").path)
        XCTAssertFalse(leaked, "a file escaped the project root via the symlink")
    }

    func testInstallsTemplateFiles() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = ProjectWorkspace(root: root)

        try await TemplateInstaller().install(into: workspace)

        for path in ["package.json", "vite.config.ts", "index.html", "src/main.tsx", "src/index.css", "src/App.tsx"] {
            let exists = await workspace.fileExists(path)
            XCTAssertTrue(exists, "missing template file: \(path)")
        }
        let pkg = try await workspace.readFile("package.json")
        XCTAssertTrue(pkg.contains("@tailwindcss/vite"))
        XCTAssertTrue(pkg.contains("\"dev\": \"vite\""))
    }

    func testFileMapSkipsNodeModules() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = ProjectWorkspace(root: root)
        try await TemplateInstaller().install(into: workspace)
        try await workspace.writeFile("node_modules/react/index.js", contents: "// dep")

        let map = await workspace.fileMap()
        XCTAssertTrue(map.contains("src/App.tsx"))
        XCTAssertFalse(map.contains(where: { $0.contains("node_modules") }))
    }
}
