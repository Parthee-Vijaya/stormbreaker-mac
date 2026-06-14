import Foundation

/// Splits a streamed token sequence into visible answer text and reasoning,
/// peeling out inline `<think>…</think>` segments that most local reasoning
/// models (deepseek-r1, qwq, …) emit inside the normal content stream.
///
/// Robustness mirrors `StreamingArtifactParser`: acts only on fully-present
/// delimiters and holds back a short tail that could be the start of a `<think>`
/// or `</think>` split across chunks, so a stray `<` in JSX is never mistaken
/// for a tag. Structured provider reasoning (Ollama `thinking`, OpenAI
/// `reasoning_content`) bypasses this entirely — it arrives already separated.
///
/// Not thread-safe — drive it from a single task.
public final class ReasoningSplitter {
    public enum Piece: Equatable, Sendable {
        case text(String)        // visible answer / prose / artifact text
        case reasoning(String)   // content between <think> and </think>
    }

    private enum State { case outside, inThink }
    private var state: State = .outside
    private var buffer = ""

    private static let open = "<think>"
    private static let close = "</think>"

    public init() {}

    public func consume(_ token: String) -> [Piece] {
        buffer += token
        return drain(atEnd: false)
    }

    /// Flush at end of stream: any held tail (and an unterminated think block) is
    /// emitted as-is so nothing is silently dropped.
    public func finish() -> [Piece] {
        drain(atEnd: true)
    }

    private func drain(atEnd: Bool) -> [Piece] {
        var pieces: [Piece] = []
        var progressing = true
        while progressing {
            progressing = false
            switch state {
            case .outside:
                if let open = buffer.range(of: Self.open) {
                    let before = String(buffer[..<open.lowerBound])
                    if !before.isEmpty { pieces.append(.text(before)) }
                    buffer = String(buffer[open.upperBound...])
                    state = .inThink
                    progressing = true
                } else {
                    let hold = atEnd ? "" : longestSuffixPrefix(of: buffer, matching: Self.open)
                    let emit = String(buffer.dropLast(hold.count))
                    if !emit.isEmpty { pieces.append(.text(emit)) }
                    buffer = hold
                }
            case .inThink:
                if let close = buffer.range(of: Self.close) {
                    let inside = String(buffer[..<close.lowerBound])
                    if !inside.isEmpty { pieces.append(.reasoning(inside)) }
                    buffer = String(buffer[close.upperBound...])
                    state = .outside
                    progressing = true
                } else {
                    let hold = atEnd ? "" : longestSuffixPrefix(of: buffer, matching: Self.close)
                    let emit = String(buffer.dropLast(hold.count))
                    if !emit.isEmpty { pieces.append(.reasoning(emit)) }
                    buffer = hold
                }
            }
        }
        return pieces
    }

    /// Longest suffix of `buffer` that is a proper prefix of `needle` — the
    /// fragment to hold back so a delimiter split across chunks isn't missed.
    private func longestSuffixPrefix(of buffer: String, matching needle: String) -> String {
        var k = min(buffer.count, needle.count - 1)
        while k > 0 {
            let suffix = String(buffer.suffix(k))
            if needle.hasPrefix(suffix) { return suffix }
            k -= 1
        }
        return ""
    }
}
