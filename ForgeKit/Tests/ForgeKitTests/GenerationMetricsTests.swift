import XCTest
@testable import ForgeKit

final class GenerationMetricsTests: XCTestCase {
    func testThroughputAndTotal() {
        let m = GenerationMetrics(promptTokens: 100, completionTokens: 300,
                                  timeToFirstTokenSeconds: 0.5, totalSeconds: 6)
        XCTAssertEqual(m.totalTokens, 400)
        XCTAssertEqual(m.tokensPerSecond, 50, accuracy: 0.001)   // 300 / 6
        XCTAssertEqual(m.timeToFirstTokenSeconds, 0.5)
    }

    func testZeroDurationIsSafe() {
        XCTAssertEqual(GenerationMetrics(completionTokens: 100, totalSeconds: 0).tokensPerSecond, 0)
        XCTAssertEqual(GenerationMetrics().tokensPerSecond, 0)
    }
}
