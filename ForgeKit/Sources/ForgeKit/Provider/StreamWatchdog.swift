import Foundation

/// Guards a streaming HTTP response against two failure modes that a plain
/// `for try await line in bytes` loop does NOT handle:
///
///  1. **User cancel during a stall.** Swift `Task` cancellation does not
///     reliably interrupt `URLSession.AsyncBytes` while it is blocked waiting
///     for the next byte — e.g. when a local model (LM Studio / Ollama) stops
///     emitting tokens but keeps the connection open with keep-alives. Holding
///     the underlying `URLSessionDataTask` lets us force-cancel it so the read
///     unblocks immediately.
///  2. **Unattended stall.** If no data arrives for `idleTimeout`, the watchdog
///     cancels the connection itself, so a hung turn fails cleanly (surfaced as
///     a timeout) instead of spinning forever.
///
/// `@unchecked Sendable`: all mutable state is serialized behind `lock`.
final class StreamWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var dataTask: URLSessionDataTask?
    private var lastActivity = Date()
    private var timedOut = false
    private var finished = false

    let idleTimeout: TimeInterval
    private let pollInterval: Duration

    /// 90s of *no data at all* is a safe stall signal: reasoning models still
    /// stream their thinking, and inter-token gaps on local models are far
    /// shorter — so this only fires when the model has genuinely hung.
    /// `pollInterval` is how often `monitor()` re-checks (overridable for tests).
    init(idleTimeout: TimeInterval = 90, pollInterval: Duration = .seconds(5)) {
        self.idleTimeout = idleTimeout
        self.pollInterval = pollInterval
    }

    /// Record the in-flight data task and reset the idle clock.
    func attach(_ task: URLSessionDataTask) {
        lock.lock(); defer { lock.unlock() }
        dataTask = task
        lastActivity = Date()
    }

    /// Mark progress — call whenever a byte/line/event arrives.
    func touch() {
        lock.lock(); defer { lock.unlock() }
        lastActivity = Date()
    }

    /// Force-cancel the connection (user stop / stream teardown).
    func cancel() {
        lock.lock(); let task = dataTask; finished = true; lock.unlock()
        task?.cancel()
    }

    /// Mark normal completion so the watchdog stops without flagging a timeout.
    func finish() {
        lock.lock(); finished = true; lock.unlock()
    }

    func didTimeout() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }

    private enum Tick { case keepGoing, stop, timeout(URLSessionDataTask?) }

    /// One idle check. Synchronous so the `NSLock` never crosses an async
    /// boundary (forbidden in Swift 6's language mode).
    private func tick() -> Tick {
        lock.lock(); defer { lock.unlock() }
        if finished { return .stop }
        if Date().timeIntervalSince(lastActivity) > idleTimeout {
            timedOut = true
            return .timeout(dataTask)
        }
        return .keepGoing
    }

    /// Background loop: cancels the connection if it goes idle past the timeout.
    /// Returns when the stream finishes/cancels. Spawn it in a sibling `Task`.
    func monitor() async {
        while true {
            try? await Task.sleep(for: pollInterval)
            if Task.isCancelled { return }
            switch tick() {
            case .keepGoing: continue
            case .stop: return
            case .timeout(let task): task?.cancel(); return
            }
        }
    }

    /// Error to surface when the watchdog tripped (vs. a real transport error).
    static var timeoutError: ProviderError {
        .transport("Modellen holdt op med at svare (timeout). Prøv igen eller vælg en anden model.")
    }
}
