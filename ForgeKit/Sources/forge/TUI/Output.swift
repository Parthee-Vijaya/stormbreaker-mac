import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Single-flush terminal output: a whole frame is composed into one byte buffer
/// and written with exactly one write(2) — never per-cell. Together with the
/// row-diff renderer (phase 2) this is what keeps the TUI flicker-free.
enum TUIOutput {
    static func emit(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { _ = write(STDOUT_FILENO, $0.baseAddress, $0.count) }
    }
    static func emit(_ string: String) { emit(Array(string.utf8)) }
}
