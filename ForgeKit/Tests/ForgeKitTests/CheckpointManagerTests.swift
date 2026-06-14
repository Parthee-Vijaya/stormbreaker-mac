import XCTest
@testable import ForgeKit

final class CheckpointManagerTests: XCTestCase {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-cp-\(UUID().uuidString)")
    }
    private func write(_ root: URL, _ rel: String, _ contents: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    private func read(_ root: URL, _ rel: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    func testSnapshotThenRestoreRevertsFile() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "src/App.tsx", "version one")
        let cp = CheckpointManager(root: root)

        let sha1 = await cp.snapshot(label: "first")
        XCTAssertNotNil(sha1)

        try write(root, "src/App.tsx", "version two")
        _ = await cp.snapshot(label: "second")
        XCTAssertEqual(read(root, "src/App.tsx"), "version two")

        await cp.restore(to: sha1!)
        XCTAssertEqual(read(root, "src/App.tsx"), "version one")
    }

    func testRestoreRemovesFilesAddedAfterSnapshot() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "src/App.tsx", "app")
        let cp = CheckpointManager(root: root)
        let sha1 = await cp.snapshot(label: "base")

        try write(root, "src/components/New.tsx", "added later")
        _ = await cp.snapshot(label: "added")
        await cp.restore(to: sha1!)

        XCTAssertNil(read(root, "src/components/New.tsx"), "files added after the checkpoint are removed")
        XCTAssertEqual(read(root, "src/App.tsx"), "app")
    }

    func testDiffShowsChange() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "src/App.tsx", "the old line\n")
        let cp = CheckpointManager(root: root)
        let sha1 = await cp.snapshot(label: "a")
        try write(root, "src/App.tsx", "the new line\n")
        let sha2 = await cp.snapshot(label: "b")

        let diff = await cp.diff(from: sha1!, to: sha2!)
        XCTAssertTrue(diff.contains("-the old line"))
        XCTAssertTrue(diff.contains("+the new line"))
        XCTAssertTrue(diff.contains("src/App.tsx"))
    }

    func testNodeModulesExcludedAndSurvivesRestore() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "src/App.tsx", "v1")
        let cp = CheckpointManager(root: root)
        let sha1 = await cp.snapshot(label: "before deps")

        // A dependency dir appears after the snapshot.
        try write(root, "node_modules/pkg/index.js", "module.exports = 1")
        try write(root, "src/App.tsx", "v2")
        let sha2 = await cp.snapshot(label: "after deps")

        // node_modules must not be tracked…
        let diff = await cp.diff(from: sha1!, to: sha2!)
        XCTAssertFalse(diff.contains("node_modules"))
        // …and must survive a restore (clean -fd skips ignored paths).
        await cp.restore(to: sha1!)
        XCTAssertEqual(read(root, "node_modules/pkg/index.js"), "module.exports = 1")
        XCTAssertEqual(read(root, "src/App.tsx"), "v1")
    }
}
