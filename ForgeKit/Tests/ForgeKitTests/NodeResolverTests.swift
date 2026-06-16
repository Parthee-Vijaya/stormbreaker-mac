import XCTest
@testable import ForgeKit

final class NodeResolverTests: XCTestCase {
    func testResolvesNodeAndNpmOnThisMachine() throws {
        let resolver = NodeResolver()
        let node = try resolver.resolve(.node)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: node.path))

        let npm = try resolver.resolve(.npm)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: npm.path))

        let binDir = try resolver.nodeBinDirectory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: binDir.path))
    }

    func testSearchDirectoriesAreDeduplicatedAndAbsolute() {
        let dirs = NodeResolver().searchDirectories().map(\.path)
        XCTAssertEqual(Set(dirs).count, dirs.count, "search directories should be unique")
        XCTAssertTrue(dirs.allSatisfy { $0.hasPrefix("/") })
    }

    // A13: a valid cached path short-circuits the search.
    func testUsesCachedPathWhenValid() throws {
        NodeResolver.clearCache()
        UserDefaults.standard.removeObject(forKey: NodeResolver.overrideDefaultsKey)
        defer { NodeResolver.clearCache() }
        let key = NodeResolver.cacheDefaultsKeyPrefix + "node"
        UserDefaults.standard.set("/bin/echo", forKey: key)   // a known executable
        XCTAssertEqual(try NodeResolver().resolve(.node).path, "/bin/echo")
    }

    // A13: a stale cache (path no longer executable) is ignored and re-resolved.
    func testIgnoresStaleCache() throws {
        NodeResolver.clearCache()
        UserDefaults.standard.removeObject(forKey: NodeResolver.overrideDefaultsKey)
        defer { NodeResolver.clearCache() }
        let key = NodeResolver.cacheDefaultsKeyPrefix + "node"
        UserDefaults.standard.set("/nonexistent/forge/node", forKey: key)
        let node = try NodeResolver().resolve(.node)   // falls through to a real node
        XCTAssertNotEqual(node.path, "/nonexistent/forge/node")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: node.path))
    }
}
