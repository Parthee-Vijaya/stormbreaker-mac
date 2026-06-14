import XCTest
@testable import ForgeKit

final class PlanQuestionTests: XCTestCase {

    func testExtractsSingleQuestionAndStripsBlock() {
        let text = """
        Here's the plan.
        <forgeQuestion>{"q":"Which layout?","options":["Grid","List"]}</forgeQuestion>
        """
        let (cleaned, questions) = PlanQuestionParser.extract(from: text)
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].question, "Which layout?")
        XCTAssertEqual(questions[0].options, ["Grid", "List"])
        XCTAssertFalse(cleaned.contains("forgeQuestion"))
        XCTAssertTrue(cleaned.contains("Here's the plan."))
    }

    func testExtractsMultipleQuestions() {
        let text = """
        Plan body.
        <forgeQuestion>{"q":"A?","options":["1","2"]}</forgeQuestion>
        middle prose
        <forgeQuestion>{"q":"B?","options":["x","y","z"]}</forgeQuestion>
        """
        let (cleaned, questions) = PlanQuestionParser.extract(from: text)
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions[0].question, "A?")
        XCTAssertEqual(questions[1].options, ["x", "y", "z"])
        XCTAssertTrue(cleaned.contains("middle prose"))
        XCTAssertFalse(cleaned.contains("forgeQuestion"))
    }

    func testAcceptsQuestionAliasKey() {
        let text = #"<forgeQuestion>{"question":"Theme?","options":["Light","Dark"]}</forgeQuestion>"#
        let (_, questions) = PlanQuestionParser.extract(from: text)
        XCTAssertEqual(questions.first?.question, "Theme?")
    }

    func testMalformedBlockIsSkippedButStripped() {
        let text = "Before <forgeQuestion>not json</forgeQuestion> after"
        let (cleaned, questions) = PlanQuestionParser.extract(from: text)
        XCTAssertTrue(questions.isEmpty)
        XCTAssertFalse(cleaned.contains("forgeQuestion"))
        XCTAssertTrue(cleaned.contains("Before"))
        XCTAssertTrue(cleaned.contains("after"))
    }

    func testEmptyOptionsRejected() {
        let text = #"<forgeQuestion>{"q":"Q?","options":[]}</forgeQuestion>"#
        let (_, questions) = PlanQuestionParser.extract(from: text)
        XCTAssertTrue(questions.isEmpty)
    }

    func testNoBlocksLeavesTextUnchanged() {
        let text = "Just a plain plan with no questions."
        let (cleaned, questions) = PlanQuestionParser.extract(from: text)
        XCTAssertEqual(cleaned, text)
        XCTAssertTrue(questions.isEmpty)
    }

    func testUnclosedBlockKeptVerbatim() {
        // Stream cut off mid-block: don't lose the tail, don't crash.
        let text = "Plan… <forgeQuestion>{\"q\":\"incomplete"
        let (cleaned, questions) = PlanQuestionParser.extract(from: text)
        XCTAssertTrue(questions.isEmpty)
        XCTAssertTrue(cleaned.contains("Plan…"))
    }
}
