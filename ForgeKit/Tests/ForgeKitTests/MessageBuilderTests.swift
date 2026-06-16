import XCTest
@testable import ForgeKit

final class MessageBuilderTests: XCTestCase {
    // A11: errorTurn inlines the current contents of the failing files so the
    // repair turn edits the real code instead of guessing.
    func testErrorTurnInlinesFailingFiles() {
        let report = ErrorReport(items: [
            .init(source: .build, message: "Cannot find name 'foo'", file: "src/App.tsx", line: 12, code: "TS2304")
        ])
        let msg = MessageBuilder().errorTurn(report, files: [
            ("src/App.tsx", "export default function App() { return foo }")
        ])
        XCTAssertTrue(msg.content.contains("TS2304"), "keeps the error text")
        XCTAssertTrue(msg.content.contains("<file path=\"src/App.tsx\">"), "inlines the file")
        XCTAssertTrue(msg.content.contains("return foo"), "includes the file body")
    }

    // A11: with no files (or only missing ones), errorTurn stays the plain form.
    func testErrorTurnWithoutFilesHasNoFileBlock() {
        let report = ErrorReport(items: [.init(source: .runtime, message: "boom")])
        let plain = MessageBuilder().errorTurn(report)
        XCTAssertFalse(plain.content.contains("<file path="))
        let missing = MessageBuilder().errorTurn(report, files: [("src/Gone.tsx", nil)])
        XCTAssertFalse(missing.content.contains("<file path="), "missing files are skipped")
    }
}
