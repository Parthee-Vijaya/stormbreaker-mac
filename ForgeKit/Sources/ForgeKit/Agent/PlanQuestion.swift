import Foundation

/// A clarifying question the model asked during plan mode, rendered as tappable
/// option chips. Codable so it persists with the chat history.
public struct PlanQuestion: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let question: String
    public let options: [String]

    public init(id: String = UUID().uuidString, question: String, options: [String]) {
        self.id = id
        self.question = question
        self.options = options
    }
}

/// Extracts `<forgeQuestion>{json}</forgeQuestion>` blocks from a plan response.
/// The model emits `{"q":"…","options":["…","…"]}` (also tolerates `"question"`);
/// malformed blocks are skipped, and the blocks are stripped from the prose so
/// the chat shows clean text with the questions surfaced as chips.
public enum PlanQuestionParser {
    private static let open = "<forgeQuestion>"
    private static let close = "</forgeQuestion>"

    public static func extract(from text: String) -> (text: String, questions: [PlanQuestion]) {
        var remaining = Substring(text)
        var cleaned = ""
        var questions: [PlanQuestion] = []

        while let openRange = remaining.range(of: open) {
            cleaned += remaining[..<openRange.lowerBound]
            let afterOpen = remaining[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: close) else {
                // Unclosed block (e.g. stream cut off): keep the tail verbatim.
                cleaned += remaining[openRange.lowerBound...]
                remaining = Substring()
                break
            }
            if let question = decode(String(afterOpen[..<closeRange.lowerBound])) {
                questions.append(question)
            }
            remaining = afterOpen[closeRange.upperBound...]
        }
        cleaned += remaining
        return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), questions)
    }

    private static func decode(_ json: String) -> PlanQuestion? {
        struct Raw: Decodable { let q: String?; let question: String?; let options: [String]? }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let text = (raw.q ?? raw.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let options = (raw.options ?? []).filter { !$0.isEmpty }
        guard !text.isEmpty, !options.isEmpty else { return nil }
        return PlanQuestion(question: text, options: options)
    }
}
