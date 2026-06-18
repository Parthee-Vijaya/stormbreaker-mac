import XCTest
@testable import StormbreakerKit

final class TodoItemTests: XCTestCase {
    func testParsesMarkers() {
        let items = TodoItem.parse("""
        [x] Done one
        [~] In progress
        [ ] Pending
        - [x] Bulleted done
        No marker line
        """)
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items[0].status, .done)
        XCTAssertEqual(items[0].text, "Done one")
        XCTAssertEqual(items[1].status, .active)
        XCTAssertEqual(items[2].status, .pending)
        XCTAssertEqual(items[3].status, .done)
        XCTAssertEqual(items[3].text, "Bulleted done")       // leading "- " bullet tolerated
        XCTAssertEqual(items[4].status, .pending)            // no marker → pending
        XCTAssertEqual(items[4].text, "No marker line")
    }

    func testSkipsBlankLines() {
        XCTAssertEqual(TodoItem.parse("\n[x] A\n\n\n[ ] B\n   \n").map(\.text), ["A", "B"])
    }

    func testEmptyBody() {
        XCTAssertTrue(TodoItem.parse("   \n  ").isEmpty)
    }

    func testFromProseDetectsMarkdownChecklist() {
        let prose = """
        Here's my plan:
        - [x] Scaffold the layout
        - [~] Build the hero
        - [ ] Wire the footer

        Now building it.
        """
        let items = try! XCTUnwrap(TodoItem.fromProse(prose))
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].status, .done)
        XCTAssertEqual(items[0].text, "Scaffold the layout")
        XCTAssertEqual(items[1].status, .active)
        XCTAssertEqual(items[2].status, .pending)
    }

    func testFromProseHandlesNumberedAndStars() {
        let items = try! XCTUnwrap(TodoItem.fromProse("1. [ ] One\n2. [x] Two\n* [ ] Three"))
        XCTAssertEqual(items.map(\.text), ["One", "Two", "Three"])
    }

    func testFromProseNilWithoutAChecklist() {
        XCTAssertNil(TodoItem.fromProse("Just regular prose with a stray [ ] bracket.\nNo list here."))
        XCTAssertNil(TodoItem.fromProse("- [ ] only one item"))   // needs >= 2
    }
}
