import XCTest
@testable import ForgeKit

/// Syntax classification tests (Part 3, phase 8). The patterns are shared by the
/// GUI highlighter and the TUI colorizer, so this pins their behaviour.
final class SyntaxRulesTests: XCTestCase {

    func testKeywordAndNumber() {
        let m = SyntaxRules.classify("const x = 42")
        XCTAssertEqual(m[0], .keyword)            // c of const
        XCTAssertEqual(m[4], .keyword)            // t of const
        XCTAssertEqual(m[6], nil)                 // x — plain identifier
        XCTAssertEqual(m[10], .number)            // 4
        XCTAssertEqual(m[11], .number)            // 2
    }

    func testTypeIsCapitalized() {
        let m = SyntaxRules.classify("let a: Foo")
        XCTAssertEqual(m[0], .keyword)            // let
        XCTAssertEqual(m[7], .type)               // F of Foo
        XCTAssertEqual(m[9], .type)
    }

    func testStringWins() {
        let m = SyntaxRules.classify("\"const\"")
        XCTAssertTrue(m.allSatisfy { $0 == .string })   // keyword inside a string stays string
    }

    func testCommentWinsLast() {
        let m = SyntaxRules.classify("// const 42")
        XCTAssertTrue(m.allSatisfy { $0 == .comment })  // everything in a comment is comment
    }

    func testPlainLine() {
        XCTAssertTrue(SyntaxRules.classify("foo.bar(baz)").allSatisfy { $0 == nil })
        XCTAssertEqual(SyntaxRules.classify(""), [])
    }
}
