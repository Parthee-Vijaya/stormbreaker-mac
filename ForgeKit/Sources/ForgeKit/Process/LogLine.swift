import Foundation

/// One line of output captured from a child process (dev server, installer, …).
///
/// ANSI escape codes are stripped before construction so the text is safe to
/// render directly in SwiftUI and to scan for error signatures.
public struct LogLine: Sendable, Identifiable, Hashable, Codable {
    public enum Stream: String, Sendable, Hashable, Codable {
        case stdout
        case stderr
    }

    public let id: UUID
    public let stream: Stream
    public let text: String
    public let date: Date

    public init(id: UUID = UUID(), stream: Stream, text: String, date: Date = Date()) {
        self.id = id
        self.stream = stream
        self.text = text
        self.date = date
    }
}
