import Foundation
import ForgeKit
#if canImport(Darwin)
import Darwin
#endif

/// Reads stdin off the main actor and yields decoded `Key`s. The blocking read(2)
/// runs in a detached task so the render loop never stalls. When a bare ESC is held
/// (could be a lone Escape or the start of a sequence), it polls 12ms for a
/// continuation; if none arrives it flushes the ESC as `.escape`.
struct StdinReader {
    func keys() -> AsyncStream<Key> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var decoder = KeyDecoder()
                var buf = [UInt8](repeating: 0, count: 4096)
                while !Task.isCancelled {
                    let n = buf.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                    if n <= 0 { break }
                    for key in decoder.feed(buf[0..<n]) { continuation.yield(key) }

                    // Disambiguate a held lone ESC: wait briefly for a continuation.
                    if decoder.isHoldingEscape {
                        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                        if poll(&pfd, 1, 12) == 0 {              // no more bytes within 12ms → real Escape
                            for key in decoder.flush() { continuation.yield(key) }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
