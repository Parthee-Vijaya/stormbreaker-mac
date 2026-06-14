import XCTest
@testable import ForgeKit

final class StreamWatchdogTests: XCTestCase {

    /// With no activity, the watchdog flags a timeout after the idle window.
    func testTimesOutWhenIdle() async {
        let watchdog = StreamWatchdog(idleTimeout: 0.05, pollInterval: .milliseconds(10))
        await watchdog.monitor()
        XCTAssertTrue(watchdog.didTimeout())
    }

    /// A finished stream stops the monitor WITHOUT a timeout.
    func testFinishStopsMonitorWithoutTimeout() async {
        let watchdog = StreamWatchdog(idleTimeout: 0.05, pollInterval: .milliseconds(10))
        watchdog.finish()
        await watchdog.monitor()
        XCTAssertFalse(watchdog.didTimeout())
    }

    /// Steady activity keeps the idle clock from ever crossing the timeout.
    func testTouchKeepsAlive() async {
        let watchdog = StreamWatchdog(idleTimeout: 0.2, pollInterval: .milliseconds(10))
        let monitor = Task { await watchdog.monitor() }
        // Touch faster than the idle window for a stretch longer than it.
        for _ in 0..<10 {
            watchdog.touch()
            try? await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertFalse(watchdog.didTimeout())
        watchdog.finish()
        await monitor.value
    }
}
