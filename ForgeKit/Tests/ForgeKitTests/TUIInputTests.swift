import XCTest
@testable import ForgeKit

/// KeyDecoder byte-fixture tests (Part 3, phase 4).
final class TUIInputTests: XCTestCase {

    private func decode(_ bytes: [UInt8]) -> [Key] {
        var d = KeyDecoder()
        return d.feed(bytes)
    }
    private func decode(_ s: String) -> [Key] { decode(Array(s.utf8)) }

    func testPrintableAndControls() {
        XCTAssertEqual(decode("a"), [.char("a")])
        XCTAssertEqual(decode("ab\r"), [.char("a"), .char("b"), .enter])
        XCTAssertEqual(decode("\t"), [.tab])
        XCTAssertEqual(decode("\n"), [.enter])
        XCTAssertEqual(decode([0x7F]), [.backspace])
        XCTAssertEqual(decode([0x03]), [.ctrl("c")])     // Ctrl-C
        XCTAssertEqual(decode([0x0B]), [.ctrl("k")])     // Ctrl-K
    }

    func testArrowsCSIandSS3() {
        XCTAssertEqual(decode("\u{1B}[A"), [.up])
        XCTAssertEqual(decode("\u{1B}[B"), [.down])
        XCTAssertEqual(decode("\u{1B}[C"), [.right])
        XCTAssertEqual(decode("\u{1B}[D"), [.left])
        XCTAssertEqual(decode("\u{1B}OA"), [.up])        // SS3 (application cursor mode)
    }

    func testNumberedKeys() {
        XCTAssertEqual(decode("\u{1B}[3~"), [.delete])
        XCTAssertEqual(decode("\u{1B}[5~"), [.pageUp])
        XCTAssertEqual(decode("\u{1B}[6~"), [.pageDown])
        XCTAssertEqual(decode("\u{1B}[H"), [.home])
        XCTAssertEqual(decode("\u{1B}[F"), [.end])
    }

    func testAltAndEscEsc() {
        XCTAssertEqual(decode("\u{1B}b"), [.alt("b")])
        XCTAssertEqual(decode([0x1B, 0x1B]).first, .escape)
    }

    func testLoneEscapeIsHeldThenFlushed() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x1B]), [])               // held — could be a sequence start
        XCTAssertTrue(d.isHoldingEscape)
        XCTAssertEqual(d.flush(), [.escape])             // idle → real Escape
    }

    func testSplitUTF8AcrossReads() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0xF0, 0x9F]), [])         // first half of 🚀 (F0 9F 9A 80)
        XCTAssertEqual(d.feed([0x9A, 0x80]), [.char("🚀")])
    }

    func testSplitCSIAcrossReads() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x1B, 0x5B]), [])         // ESC[ … incomplete
        XCTAssertEqual(d.feed([0x41]), [.up])            // …A completes it
    }

    func testBracketedPaste() {
        XCTAssertEqual(decode("\u{1B}[200~hello world\u{1B}[201~"), [.paste("hello world")])
        // a slash inside a paste must NOT be treated as a command trigger — it's payload
        XCTAssertEqual(decode("\u{1B}[200~/model\u{1B}[201~"), [.paste("/model")])
    }
}
