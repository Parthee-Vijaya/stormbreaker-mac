import XCTest
@testable import ForgeKit

final class ContextBuilderTests: XCTestCase {

    private func reader(_ map: [String: String]) -> (String) async -> String? {
        { path in map[path] }
    }

    // MARK: - Helpers

    func testEstimateTokens() {
        XCTAssertEqual(ContextBuilder.estimateTokens(String(repeating: "x", count: 400)), 100)
        XCTAssertEqual(ContextBuilder.estimateTokens(""), 1)
    }

    func testPrioritizePutsTouchedThenEntryFirst() {
        let files = ["src/App.tsx", "src/main.tsx", "src/components/Foo.tsx", "src/lib/util.ts"]
        let order = ContextBuilder.prioritize(files: files, touched: ["src/components/Foo.tsx"])
        XCTAssertEqual(order.first, "src/components/Foo.tsx")           // touched wins
        XCTAssertEqual(order[1], "src/App.tsx")                         // then entry point
        XCTAssertEqual(Set(order), Set(files))                         // all included, deduped
    }

    func testPrioritizeIgnoresUnknownTouched() {
        let files = ["src/App.tsx"]
        let order = ContextBuilder.prioritize(files: files, touched: ["src/Ghost.tsx"])
        XCTAssertEqual(order, ["src/App.tsx"])
    }

    func testIsSourceAndLang() {
        XCTAssertTrue(ContextBuilder.isSource("src/App.tsx"))
        XCTAssertFalse(ContextBuilder.isSource("package.json"))
        XCTAssertEqual(ContextBuilder.lang("a.tsx"), "tsx")
        XCTAssertEqual(ContextBuilder.lang("a.css"), "css")
    }

    // MARK: - build()

    func testEmptyFilesReturnsNil() async {
        let result = await ContextBuilder().build(files: [], touched: [], read: reader([:]))
        XCTAssertNil(result)
    }

    func testIncludesTouchedFileBeforeEntry() async {
        let files = ["src/App.tsx", "src/components/Hero.tsx"]
        let map = ["src/App.tsx": "export default function App(){}",
                   "src/components/Hero.tsx": "export const Hero = () => null"]
        let out = await ContextBuilder().build(files: files, touched: ["src/components/Hero.tsx"], read: reader(map))
        let unwrapped = try? XCTUnwrap(out)
        let hero = unwrapped?.range(of: "src/components/Hero.tsx:")
        let app = unwrapped?.range(of: "src/App.tsx:\n```")
        XCTAssertNotNil(hero)
        XCTAssertNotNil(app)
        // Hero (touched) inlined before App.
        XCTAssertTrue(hero!.lowerBound < app!.lowerBound)
    }

    func testBudgetLimitsIncludedFiles() async {
        // Two ~100-token files; budget only fits one.
        let big = String(repeating: "a", count: 400)   // ~100 tokens
        let files = ["src/App.tsx", "src/Other.tsx"]
        let map = ["src/App.tsx": big, "src/Other.tsx": big]
        let out = await ContextBuilder(tokenBudget: 120).build(files: files, touched: [], read: reader(map))
        let body = out ?? ""
        // App.tsx (entry) fits; Other.tsx does not.
        XCTAssertTrue(body.contains("src/App.tsx:\n```"))
        XCTAssertFalse(body.contains("src/Other.tsx:\n```"))
    }

    func testHeadTruncatesWhenTopFileExceedsBudget() async {
        let huge = String(repeating: "z", count: 4000)   // ~1000 tokens
        let out = await ContextBuilder(tokenBudget: 50)
            .build(files: ["src/App.tsx"], touched: [], read: reader(["src/App.tsx": huge]))
        let body = try? XCTUnwrap(out)
        XCTAssertEqual(body?.contains("truncated for context budget"), true)
    }

    func testCompressesLongFileList() async {
        let files = (0..<150).map { "src/f\($0).ts" }
        let out = await ContextBuilder(maxListedFiles: 100)
            .build(files: files, touched: [], read: { _ in nil })
        XCTAssertEqual(out?.contains("and 50 more files"), true)
    }
}
