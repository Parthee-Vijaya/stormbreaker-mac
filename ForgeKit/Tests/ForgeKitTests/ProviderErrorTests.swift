import XCTest
@testable import ForgeKit

final class ProviderErrorTests: XCTestCase {
    /// Dogfood (gemma, too big for RAM): LM Studio returns a 400 with an OpenAI-style
    /// error body. The description must surface the human message, not raw JSON.
    func testHTTPErrorExtractsOpenAIStyleMessage() {
        let body = #"{"error":{"message":"Failed to load model \"gemma-4\": insufficient system resources.","type":"server_error"}}"#
        let desc = ProviderError.http(status: 400, body: body).description
        XCTAssertTrue(desc.contains("insufficient system resources"), desc)
        XCTAssertFalse(desc.contains(#"{"error""#), "raw JSON should not leak: \(desc)")
    }

    func testHTTPErrorTopLevelMessage() {
        let body = #"{"message":"model not found"}"#
        XCTAssertTrue(ProviderError.http(status: 404, body: body).description.contains("model not found"))
    }

    func testHTTPErrorFallsBackToNonJSONBody() {
        let desc = ProviderError.http(status: 500, body: "internal error, not json").description
        XCTAssertTrue(desc.contains("internal error, not json"))
    }
}
