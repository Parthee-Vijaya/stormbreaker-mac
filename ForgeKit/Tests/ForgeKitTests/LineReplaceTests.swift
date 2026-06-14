import XCTest
@testable import ForgeKit

final class LineReplaceTests: XCTestCase {

    // MARK: - parseLineEdits

    func testParsesSingleBlock() {
        let body = """
        <<<<<<< SEARCH
        const x = 1
        =======
        const x = 2
        >>>>>>> REPLACE
        """
        let edits = StreamingArtifactParser.parseLineEdits(body)
        XCTAssertEqual(edits, [LineEdit(search: "const x = 1", replace: "const x = 2")])
    }

    func testParsesMultipleBlocks() {
        let body = """
        <<<<<<< SEARCH
        import a
        =======
        import a
        import b
        >>>>>>> REPLACE
        <<<<<<< SEARCH
        foo()
        =======
        bar()
        >>>>>>> REPLACE
        """
        let edits = StreamingArtifactParser.parseLineEdits(body)
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits[0].replace, "import a\nimport b")
        XCTAssertEqual(edits[1], LineEdit(search: "foo()", replace: "bar()"))
    }

    func testPreservesMultilineAndSpecialCharsInBody() {
        let body = """
        <<<<<<< SEARCH
        <div className="p-4">
          {items.map(i => <li key={i}>{i}</li>)}
        </div>
        =======
        <div className="p-8">
          {items.map(i => <li key={i}>{i.name}</li>)}
        </div>
        >>>>>>> REPLACE
        """
        let edits = StreamingArtifactParser.parseLineEdits(body)
        XCTAssertEqual(edits.count, 1)
        XCTAssertTrue(edits[0].search.contains("<li key={i}>{i}</li>"))
        XCTAssertTrue(edits[0].replace.contains("{i.name}"))
    }

    // MARK: - Parser streaming (chunk-robust)

    private func lineReplaceEvents(_ events: [ParserEvent]) -> (opens: [String], closes: [(String, [LineEdit])]) {
        var opens: [String] = []
        var closes: [(String, [LineEdit])] = []
        for e in events {
            if case .lineReplaceOpen(let p) = e { opens.append(p) }
            if case .lineReplaceClose(let p, let edits) = e { closes.append((p, edits)) }
        }
        return (opens, closes)
    }

    private func parse(_ full: String, chunkSize: Int) -> [ParserEvent] {
        let parser = StreamingArtifactParser()
        var events: [ParserEvent] = []
        var index = full.startIndex
        while index < full.endIndex {
            let end = full.index(index, offsetBy: chunkSize, limitedBy: full.endIndex) ?? full.endIndex
            events += parser.consume(String(full[index..<end]))
            index = end
        }
        events += parser.finish()
        return events
    }

    private let artifact = """
    Updating the header.
    <forgeArtifact id="edit" title="Edit">
    <forgeAction type="line-replace" filePath="src/App.tsx">
    <<<<<<< SEARCH
    <h1>Old</h1>
    =======
    <h1>New</h1>
    >>>>>>> REPLACE
    </forgeAction>
    </forgeArtifact>
    """

    func testStreamingLineReplaceAcrossChunkSizes() {
        for chunk in [Int.max, 7, 3, 1] {
            let (opens, closes) = lineReplaceEvents(parse(artifact, chunkSize: chunk))
            XCTAssertEqual(opens, ["src/App.tsx"], "chunk \(chunk)")
            XCTAssertEqual(closes.count, 1, "chunk \(chunk)")
            XCTAssertEqual(closes.first?.0, "src/App.tsx", "chunk \(chunk)")
            XCTAssertEqual(closes.first?.1, [LineEdit(search: "<h1>Old</h1>", replace: "<h1>New</h1>")], "chunk \(chunk)")
        }
    }

    // MARK: - ActionExecutor.apply

    func testApplyReplacesInOrder() throws {
        let original = "let a = 1\nlet b = 2\n"
        let edits = [
            LineEdit(search: "let a = 1", replace: "let a = 10"),
            LineEdit(search: "let b = 2", replace: "let b = 20"),
        ]
        let result = try ActionExecutor.apply(edits, to: original, path: "x.ts")
        XCTAssertEqual(result, "let a = 10\nlet b = 20\n")
    }

    func testApplyThrowsOnMissingSearchWithoutPartialWrite() {
        let original = "const x = 1"
        let edits = [
            LineEdit(search: "const x = 1", replace: "const x = 2"),
            LineEdit(search: "DOES NOT EXIST", replace: "y"),
        ]
        XCTAssertThrowsError(try ActionExecutor.apply(edits, to: original, path: "x.ts")) { error in
            XCTAssertTrue(error is LineReplaceFailure)
        }
    }

    func testApplyIgnoresEmptySearch() throws {
        let result = try ActionExecutor.apply([LineEdit(search: "", replace: "noop")], to: "abc", path: "x.ts")
        XCTAssertEqual(result, "abc")
    }

    // MARK: - SystemPrompt gating

    func testSystemPromptIncludesLineReplaceOnlyForStrongModels() {
        XCTAssertFalse(SystemPrompt.forge(lineReplace: false).contains("line-replace"))
        XCTAssertTrue(SystemPrompt.forge(lineReplace: true).contains("SEARCH"))
    }

    func testFewShotExampleMatchesCapability() {
        // Weak models get a concrete whole-file example…
        let weak = SystemPrompt.forge(lineReplace: false)
        XCTAssertTrue(weak.contains("<example>"))
        XCTAssertTrue(weak.contains("Clicked {count} times"))
        XCTAssertFalse(weak.contains("REPLACE"))
        // …strong models get a line-replace diff example instead.
        let strong = SystemPrompt.forge(lineReplace: true)
        XCTAssertTrue(strong.contains("<example>"))
        XCTAssertTrue(strong.contains(">>>>>>> REPLACE"))
    }
}
