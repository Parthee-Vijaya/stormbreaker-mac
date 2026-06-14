import XCTest
@testable import ForgeKit

final class ReasoningSplitterTests: XCTestCase {

    /// Feed `full` in fixed-size chunks; return concatenated visible text + reasoning.
    private func split(_ full: String, chunk: Int) -> (text: String, reasoning: String) {
        let splitter = ReasoningSplitter()
        var text = "", reasoning = ""
        func collect(_ pieces: [ReasoningSplitter.Piece]) {
            for p in pieces {
                switch p {
                case .text(let t): text += t
                case .reasoning(let r): reasoning += r
                }
            }
        }
        var i = full.startIndex
        while i < full.endIndex {
            let e = full.index(i, offsetBy: chunk, limitedBy: full.endIndex) ?? full.endIndex
            collect(splitter.consume(String(full[i..<e])))
            i = e
        }
        collect(splitter.finish())
        return (text, reasoning)
    }

    func testPlainTextHasNoReasoning() {
        for chunk in [Int.max, 3, 1] {
            let (text, reasoning) = split("Just a normal answer.", chunk: chunk)
            XCTAssertEqual(text, "Just a normal answer.", "chunk \(chunk)")
            XCTAssertEqual(reasoning, "", "chunk \(chunk)")
        }
    }

    func testSplitsSingleThinkBlock() {
        let input = "Before<think>my reasoning</think>After"
        for chunk in [Int.max, 7, 3, 1] {
            let (text, reasoning) = split(input, chunk: chunk)
            XCTAssertEqual(text, "BeforeAfter", "chunk \(chunk)")
            XCTAssertEqual(reasoning, "my reasoning", "chunk \(chunk)")
        }
    }

    func testThinkAtStart() {
        let input = "<think>plan it out</think>The answer"
        for chunk in [Int.max, 4, 1] {
            let (text, reasoning) = split(input, chunk: chunk)
            XCTAssertEqual(text, "The answer", "chunk \(chunk)")
            XCTAssertEqual(reasoning, "plan it out", "chunk \(chunk)")
        }
    }

    func testStrayAngleBracketInJSXStaysText() {
        // A `<` that is NOT a <think> tag must pass through as visible text.
        let input = "return <div className=\"p-4\">Hi</div>"
        for chunk in [Int.max, 2, 1] {
            let (text, reasoning) = split(input, chunk: chunk)
            XCTAssertEqual(text, input, "chunk \(chunk)")
            XCTAssertEqual(reasoning, "", "chunk \(chunk)")
        }
    }

    func testMultilineReasoningPreserved() {
        let input = "<think>line one\nline two\nline three</think>done"
        let (text, reasoning) = split(input, chunk: 5)
        XCTAssertEqual(text, "done")
        XCTAssertEqual(reasoning, "line one\nline two\nline three")
    }

    func testUnterminatedThinkFlushesAsReasoning() {
        // Stream ends mid-think → the partial thinking is not dropped.
        let input = "ok<think>still thinking when the stream ends"
        let (text, reasoning) = split(input, chunk: 1)
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(reasoning, "still thinking when the stream ends")
    }
}
