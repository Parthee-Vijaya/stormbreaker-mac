import XCTest
@testable import ForgeKit

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

    private func inlineActions(_ events: [ParserEvent]) -> [ForgeAction] {
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
}
