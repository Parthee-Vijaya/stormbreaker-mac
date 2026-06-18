import XCTest
@testable import StormbreakerKit

private final class Box: @unchecked Sendable { var value = "" }

final class ConversationCompactorTests: XCTestCase {
    private func turn(_ u: String, _ a: String) -> [ChatMessage] {
        [ChatMessage(role: .user, content: u), ChatMessage(role: .assistant, content: a)]
    }

    func testNoCompactionUnderBudget() async {
        let c = ConversationCompactor(maxTokens: 10_000, keepRecent: 6)
        let history = turn("hi", "hello")
        XCTAssertFalse(c.needsCompaction(history))
        let out = await c.compact(history) { _ in "SUMMARY" }
        XCTAssertEqual(out.count, history.count, "under budget → unchanged")
    }

    func testCompactsOldTurnsKeepsRecentVerbatim() async {
        var history: [ChatMessage] = []
        for i in 0..<6 { history += turn(String(repeating: "u\(i) ", count: 200), String(repeating: "a\(i) ", count: 200)) }
        let c = ConversationCompactor(maxTokens: 500, keepRecent: 4)
        XCTAssertTrue(c.needsCompaction(history))

        let box = Box()
        let out = await c.compact(history) { convo in box.value = convo; return "Brugeren bygger en app." }
        XCTAssertEqual(out.count, 6, "summary + ack + last 4 verbatim")
        XCTAssertEqual(out[0].role, .user)
        XCTAssertTrue(out[0].content.contains("Brugeren bygger en app."))
        XCTAssertEqual(out[1].role, .assistant)
        XCTAssertEqual(Array(out.suffix(4)), Array(history.suffix(4)), "recent kept verbatim")
        XCTAssertTrue(box.value.contains("u0"), "old turns were summarized")
        XCTAssertFalse(box.value.contains("u5 "), "recent turns NOT sent to the summarizer")
    }

    func testAlternationValidForAnthropic() async {
        var history: [ChatMessage] = []
        for i in 0..<5 { history += turn("u\(i)", "a\(i)") }
        let c = ConversationCompactor(maxTokens: 0, keepRecent: 4)   // force
        let out = await c.compact(history) { _ in "S" }
        for (i, m) in out.enumerated() {
            XCTAssertEqual(m.role, i % 2 == 0 ? .user : .assistant, "must alternate user/assistant from index \(i)")
        }
    }

    func testReturnsOriginalWhenSummarizerFails() async {
        var history: [ChatMessage] = []
        for i in 0..<6 { history += turn(String(repeating: "x", count: 400), String(repeating: "y", count: 400)) }
        let c = ConversationCompactor(maxTokens: 100, keepRecent: 4)
        let out = await c.compact(history) { _ in nil }
        XCTAssertEqual(out.count, history.count, "failure → keep full history, never lose turns")
    }
}
