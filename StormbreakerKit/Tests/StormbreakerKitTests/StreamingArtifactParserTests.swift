import XCTest
@testable import StormbreakerKit

final class StreamingArtifactParserTests: XCTestCase {
    /// Feed `full` through the parser in fixed-size chunks and return all events.
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

    private func files(_ events: [ParserEvent]) -> [(String, String)] {
        events.compactMap { if case .fileClose(let p, let c) = $0 { return (p, c) }; return nil }
    }

    private func inlineActions(_ events: [ParserEvent]) -> [StormbreakerAction] {
        events.compactMap { if case .inlineAction(let a) = $0 { return a }; return nil }
    }

    private func readRequests(_ events: [ParserEvent]) -> [String] {
        events.compactMap { if case .readRequest(let p) = $0 { return p }; return nil }
    }

    func testReadFileRequest() {
        let input = """
        Let me check the board first.
        <forgeArtifact id="read" title="Read">
        <forgeAction type="read-file" filePath="src/components/Board.tsx"></forgeAction>
        <forgeAction type="read-file" filePath="src/lib/utils.ts"></forgeAction>
        </forgeArtifact>
        """
        for chunk in [Int.max, 1, 7] {
            let events = parse(input, chunkSize: chunk)
            XCTAssertEqual(readRequests(events), ["src/components/Board.tsx", "src/lib/utils.ts"],
                           "chunk size \(chunk)")
            XCTAssertTrue(files(events).isEmpty, "read-file must not produce file writes")
        }
    }

    func testMCPActionEmitsRequest() {
        let input = """
        <forgeArtifact id="x" title="X">
        <forgeAction type="mcp" server="fs" tool="read_file">{ "path": "package.json" }</forgeAction>
        </forgeArtifact>
        """
        for chunk in [Int.max, 1, 9] {
            let events = parse(input, chunkSize: chunk)
            let mcp = events.compactMap { e -> (String, String, String)? in
                if case .mcpRequest(let s, let t, let a) = e { return (s, t, a) }; return nil
            }
            XCTAssertEqual(mcp.count, 1, "chunk \(chunk)")
            XCTAssertEqual(mcp.first?.0, "fs", "chunk \(chunk)")
            XCTAssertEqual(mcp.first?.1, "read_file", "chunk \(chunk)")
            XCTAssertTrue(mcp.first?.2.contains("package.json") ?? false, "args preserved (chunk \(chunk))")
            XCTAssertTrue(files(events).isEmpty, "mcp must not write a file (chunk \(chunk))")
            XCTAssertEqual(events.filter { $0 == .artifactClose }.count, 1, "chunk \(chunk)")
        }
    }

    func testWebActionsEmitRequests() {
        let input = """
        <forgeArtifact id="x" title="X">
        <forgeAction type="web-search">react router v7 api</forgeAction>
        <forgeAction type="web-fetch">https://example.com/docs</forgeAction>
        </forgeArtifact>
        """
        for chunk in [Int.max, 1, 9] {
            let events = parse(input, chunkSize: chunk)
            let web = events.compactMap { e -> (WebRequestKind, String)? in
                if case .webRequest(let k, let q) = e { return (k, q) }; return nil
            }
            XCTAssertEqual(web.count, 2, "chunk \(chunk)")
            XCTAssertEqual(web.first?.0, .search, "chunk \(chunk)")
            XCTAssertEqual(web.first?.1, "react router v7 api", "chunk \(chunk)")
            XCTAssertEqual(web.last?.0, .fetch, "chunk \(chunk)")
            XCTAssertEqual(web.last?.1, "https://example.com/docs", "chunk \(chunk)")
            XCTAssertTrue(files(events).isEmpty, "web must not write a file (chunk \(chunk))")
        }
    }

    func testTodoActionEmitsUpdateWithoutBlockingFiles() {
        let input = """
        <forgeArtifact id="x" title="X">
        <forgeAction type="todo">
        [x] Scaffold
        [~] Hero
        [ ] Footer
        </forgeAction>
        <forgeAction type="file" filePath="src/App.tsx">export default function App(){return null}</forgeAction>
        </forgeArtifact>
        """
        for chunk in [Int.max, 1, 11] {
            let events = parse(input, chunkSize: chunk)
            let todos = events.compactMap { e -> [TodoItem]? in
                if case .todoUpdate(let t) = e { return t }; return nil
            }
            XCTAssertEqual(todos.count, 1, "chunk \(chunk)")
            XCTAssertEqual(todos.first?.count, 3, "chunk \(chunk)")
            XCTAssertEqual(todos.first?[0].status, .done, "chunk \(chunk)")
            XCTAssertEqual(todos.first?[1].status, .active, "chunk \(chunk)")
            let wroteApp = events.contains { if case .fileClose(let p, _) = $0 { return p == "src/App.tsx" }; return false }
            XCTAssertTrue(wroteApp, "todo action must not block the file write (chunk \(chunk))")
        }
    }

    /// Regression (dogfood, Svelte/qwen): the model wrote the file but omitted the
    /// inner </forgeAction>, jumping straight to </forgeArtifact>. The close tag must
    /// NOT leak into the file body — it made Svelte components end with a literal
    /// "</forgeArtifact>" and fail to compile. </forgeArtifact> implicitly closes the
    /// open file, and an artifactClose is still emitted.
    func testArtifactCloseTerminatesUnclosedFile() {
        let input = """
        <forgeArtifact id="app" title="App">
        <forgeAction type="file" filePath="src/App.svelte">
        <div class="board">
          <h1>Kanban</h1>
        </div>
        </forgeArtifact>
        """
        for chunk in [Int.max, 1, 7, 13] {
            let events = parse(input, chunkSize: chunk)
            let written = files(events)
            XCTAssertEqual(written.count, 1, "chunk \(chunk)")
            XCTAssertEqual(written.first?.0, "src/App.svelte", "chunk \(chunk)")
            XCTAssertFalse(written.first?.1.contains("forgeArtifact") ?? true,
                           "close tag leaked into file body (chunk \(chunk))")
            XCTAssertTrue(written.first?.1.contains("</div>") ?? false,
                          "real content must survive (chunk \(chunk))")
            XCTAssertEqual(events.filter { $0 == .artifactClose }.count, 1,
                           "must still emit artifactClose (chunk \(chunk))")
        }
    }

    private let sample = """
    Here is your app.
    <forgeArtifact id="todo" title="Todo App">
    <forgeAction type="add-dependency">clsx</forgeAction>
    <forgeAction type="file" filePath="src/App.tsx">
    export default function App() {
      return <div className="p-4">{"</not-a-real-close>"}</div>
    }
    </forgeAction>
    <forgeAction type="start">npm run dev</forgeAction>
    </forgeArtifact>
    Done!
    """

    func testParsesWholeInputInOneChunk() {
        let events = parse(sample, chunkSize: .max)
        assertSampleParsedCorrectly(events)
    }

    func testParsesCharacterByCharacter() {
        // The hardest case: every delimiter is split across chunk boundaries.
        let events = parse(sample, chunkSize: 1)
        assertSampleParsedCorrectly(events)
    }

    func testParsesAtAwkwardChunkSize() {
        let events = parse(sample, chunkSize: 7)
        assertSampleParsedCorrectly(events)
    }

    private func assertSampleParsedCorrectly(_ events: [ParserEvent]) {
        let writtenFiles = files(events)
        XCTAssertEqual(writtenFiles.count, 1)
        XCTAssertEqual(writtenFiles.first?.0, "src/App.tsx")

        let contents = writtenFiles.first?.1 ?? ""
        // JSX with `<`, `</div>`, and a literal "</not-a-real-close>" survives intact.
        XCTAssertTrue(contents.contains("export default function App()"))
        XCTAssertTrue(contents.contains("<div className=\"p-4\">"))
        XCTAssertTrue(contents.contains("</not-a-real-close>"))
        XCTAssertTrue(contents.contains("</div>"))
        // No artifact tags leaked into the file body.
        XCTAssertFalse(contents.contains("forgeAction"))
        XCTAssertFalse(contents.contains("forgeArtifact"))
        // Leading/trailing newline trimmed.
        XCTAssertFalse(contents.hasPrefix("\n"))
        XCTAssertFalse(contents.hasSuffix("\n"))

        // Inline actions, in order.
        XCTAssertEqual(inlineActions(events), [
            .addDependency(package: "clsx"),
            .start(command: "npm run dev"),
        ])

        // Prose before/after the artifact is surfaced as text.
        let text = events.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined()
        XCTAssertTrue(text.contains("Here is your app."))
        XCTAssertTrue(text.contains("Done!"))

        // Exactly one artifact open/close.
        XCTAssertEqual(events.filter { if case .artifactOpen = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(events.filter { $0 == .artifactClose }.count, 1)
    }

    func testPlainProseWithNoArtifact() {
        let events = parse("Just a normal reply, no code.", chunkSize: 3)
        let text = events.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined()
        XCTAssertEqual(text, "Just a normal reply, no code.")
        XCTAssertTrue(files(events).isEmpty)
    }

    func testMultipleFiles() {
        let input = """
        <forgeArtifact id="x" title="X">
        <forgeAction type="file" filePath="a.ts">const a = 1</forgeAction>
        <forgeAction type="file" filePath="b.ts">const b = 2</forgeAction>
        </forgeArtifact>
        """
        let writtenFiles = files(parse(input, chunkSize: 1))
        XCTAssertEqual(writtenFiles.map(\.0), ["a.ts", "b.ts"])
        XCTAssertEqual(writtenFiles.map(\.1), ["const a = 1", "const b = 2"])
    }

    func testStripsWrappingMarkdownCodeFence() {
        // Local models often wrap file bodies in ```tsx … ``` despite instructions.
        let input = """
        <forgeArtifact id="x" title="X">
        <forgeAction type="file" filePath="src/App.tsx">
        ```tsx
        export default function App() { return <div>hi</div> }
        ```
        </forgeAction>
        </forgeArtifact>
        """
        for chunkSize in [1, 5, .max] {
            let written = files(parse(input, chunkSize: chunkSize))
            XCTAssertEqual(written.count, 1)
            let contents = written.first?.1 ?? ""
            XCTAssertFalse(contents.contains("```"), "fence not stripped (chunk \(chunkSize)): \(contents)")
            XCTAssertEqual(contents, "export default function App() { return <div>hi</div> }")
        }
    }

    func testFinishFlushesPartialFileOnCancel() {
        // User cancels mid-stream: the file body opened + streamed, but the closing
        // </forgeAction> never arrived. finish() must still emit a fileClose with
        // the partial content rather than silently losing the file.
        let input = """
        <forgeArtifact id="x" title="X">
        <forgeAction type="file" filePath="src/App.tsx">export default function App() {
          return <div>partial
        """
        for chunk in [Int.max, 1, 7] {
            let written = files(parse(input, chunkSize: chunk))
            XCTAssertEqual(written.count, 1, "chunk \(chunk): partial file should be flushed")
            XCTAssertEqual(written.first?.0, "src/App.tsx", "chunk \(chunk)")
            XCTAssertEqual(written.first?.1,
                           "export default function App() {\n  return <div>partial",
                           "chunk \(chunk): partial content preserved")
        }
    }

    func testFinishDropsPartialLineReplace() {
        // A half-streamed line-replace must NOT be applied — a partial SEARCH/REPLACE
        // would corrupt the target file. finish() drops it (no fileClose).
        let input = """
        <forgeArtifact id="x" title="X">
        <forgeAction type="line-replace" filePath="src/App.tsx">
        <<<<<<< SEARCH
        const a = 1
        """
        let written = files(parse(input, chunkSize: 1))
        XCTAssertTrue(written.isEmpty, "partial line-replace must not be applied")
    }

    // MARK: - Fuzz / edge cases (A6)

    /// Exhaustively feed the sample at EVERY chunk size 1…len. This stresses the
    /// suffix-holdback at every possible split point of every delimiter — the
    /// result must be identical regardless of where chunks break.
    func testEveryChunkBoundaryParsesIdentically() {
        for size in 1...sample.count {
            let events = parse(sample, chunkSize: size)
            let written = files(events)
            XCTAssertEqual(written.count, 1, "chunk \(size): exactly one file")
            XCTAssertEqual(written.first?.0, "src/App.tsx", "chunk \(size)")
            let c = written.first?.1 ?? ""
            XCTAssertTrue(c.contains("export default function App()"), "chunk \(size)")
            XCTAssertTrue(c.contains("</not-a-real-close>"), "chunk \(size)")
            XCTAssertFalse(c.contains("forgeAction"), "chunk \(size): no tag leak")
            XCTAssertEqual(inlineActions(events),
                           [.addDependency(package: "clsx"), .start(command: "npm run dev")],
                           "chunk \(size)")
        }
    }

    /// Stream cut off right after the artifact opens: artifactOpen is emitted, but
    /// finish() must not crash or fabricate a file.
    func testUnterminatedArtifactOpenAtEOF() {
        let events = parse("<forgeArtifact id=\"x\" title=\"X\">", chunkSize: 3)
        let opens = events.filter { if case .artifactOpen = $0 { return true }; return false }.count
        XCTAssertEqual(opens, 1)
        XCTAssertTrue(files(events).isEmpty)
    }

    /// A fragment that is only the START of the open marker at EOF is surfaced as
    /// text, never silently swallowed.
    func testPartialOpenMarkerAtEOFBecomesText() {
        let events = parse("hello <forgeArti", chunkSize: 1)
        let text = events.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined()
        XCTAssertEqual(text, "hello <forgeArti")
        XCTAssertTrue(files(events).isEmpty)
    }

    /// TSX generics, comparisons, and a LITERAL `<forgeArtifact>` inside the body
    /// survive verbatim — only `</forgeAction>` closes a file body.
    func testJSXAndLiteralTagsInBodySurvive() {
        let input = """
        <forgeArtifact id="x" title="X">
        <forgeAction type="file" filePath="src/App.tsx">
        function id<T,>(x: T): T { return x }
        const ok = 2 < 3 && 5 > 1
        // a literal <forgeArtifact> and </div> survive
        </forgeAction>
        </forgeArtifact>
        """
        for chunk in [1, 7, Int.max] {
            let written = files(parse(input, chunkSize: chunk))
            XCTAssertEqual(written.count, 1, "chunk \(chunk)")
            let c = written.first?.1 ?? ""
            XCTAssertTrue(c.contains("function id<T,>(x: T): T"), "chunk \(chunk)")
            XCTAssertTrue(c.contains("2 < 3 && 5 > 1"), "chunk \(chunk)")
            XCTAssertTrue(c.contains("<forgeArtifact>"), "chunk \(chunk): literal tag kept verbatim")
        }
    }

    /// An empty file body yields a fileClose with empty contents (not dropped).
    func testEmptyFileBody() {
        let input = "<forgeArtifact id=\"x\" title=\"X\"><forgeAction type=\"file\" filePath=\"a.ts\"></forgeAction></forgeArtifact>"
        for chunk in [1, Int.max] {
            let written = files(parse(input, chunkSize: chunk))
            XCTAssertEqual(written.map(\.0), ["a.ts"], "chunk \(chunk)")
            XCTAssertEqual(written.first?.1, "", "chunk \(chunk)")
        }
    }

    /// Randomized fuzz: feed adversarial strings built from delimiter-ish fragments
    /// at random chunk sizes. The parser must never crash, hang, or fail to
    /// terminate — output correctness isn't asserted, only robustness.
    func testFuzzRandomInputNeverCrashes() {
        let fragments = ["<forgeArtifact", "</forgeArtifact>", "<forgeAction", "</forgeAction>",
                         " type=\"file\"", " filePath=\"a.tsx\"", "type=\"mcp\"", "<", ">", "/", "\"",
                         "\n", "  ", "x", "<<", "</", "Artifact", "storm", "id=", "</div>", "{x<y}"]
        var rng = SeededRNG(seed: 0xF0F0_1234)
        for _ in 0..<400 {
            let count = Int.random(in: 0...60, using: &rng)
            let s = (0..<count).map { _ in fragments.randomElement(using: &rng)! }.joined()
            let events = parse(s, chunkSize: Int.random(in: 1...11, using: &rng))
            // The contract: parse returns (no hang/crash). files() must also not crash.
            _ = files(events)
        }
    }

    /// A very large file body (~230 KB) is preserved byte-for-byte.
    func testHugeFileBodyPreserved() {
        let line = "const x = <Foo a={b < c} bar=\"baz\" />;\n"
        let body = String(repeating: line, count: 6000)
        let input = "<forgeArtifact id=\"x\" title=\"X\"><forgeAction type=\"file\" filePath=\"src/Big.tsx\">\(body)</forgeAction></forgeArtifact>"
        // The parser trims surrounding whitespace from a file body; compare trimmed
        // (this still catches any mid-content truncation in a 230 KB stream).
        let expected = body.trimmingCharacters(in: .whitespacesAndNewlines)
        for chunk in [4096, Int.max] {
            let written = files(parse(input, chunkSize: chunk))
            XCTAssertEqual(written.count, 1, "chunk \(chunk)")
            XCTAssertEqual(written.first?.1.trimmingCharacters(in: .whitespacesAndNewlines), expected,
                           "huge body preserved (chunk \(chunk))")
        }
    }
}

/// Deterministic xorshift PRNG so fuzz runs are reproducible across machines (A6).
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0xdead_beef : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
