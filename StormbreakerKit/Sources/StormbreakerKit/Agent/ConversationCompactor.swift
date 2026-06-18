import Foundation

/// Keeps a chat history within a token budget by summarizing the OLDEST turns into a
/// compact summary while keeping the most recent turns verbatim (opencode `/compact`).
///
/// Critical for local models, whose context windows are small — without this, a long
/// vibecoding session overflows the window and the build breaks. The summary is folded
/// in as a synthetic `user`(summary)+`assistant`(ack) pair so the message sequence stays
/// validly alternating for every provider (Anthropic requires user-first alternation).
public struct ConversationCompactor: Sendable {
    /// Compact once the history's estimated tokens exceed this.
    public var maxTokens: Int
    /// How many of the most-recent messages to keep verbatim (forced even, so the kept
    /// slice begins on a user turn).
    public var keepRecent: Int

    public init(maxTokens: Int = 6000, keepRecent: Int = 6) {
        self.maxTokens = maxTokens
        self.keepRecent = max(2, keepRecent - (keepRecent % 2))
    }

    public func needsCompaction(_ history: [ChatMessage]) -> Bool {
        history.count > keepRecent && Self.estimateTokens(history) > maxTokens
    }

    /// Summarize everything older than `keepRecent` via `summarize`, then return
    /// `[user(summary), assistant(ack)] + recent`. Returns the original history on a
    /// no-op (under budget / too short) or if the summarizer fails — never loses turns.
    public func compact(_ history: [ChatMessage],
                        summarize: @Sendable (String) async -> String?) async -> [ChatMessage] {
        guard needsCompaction(history) else { return history }
        let recent = Array(history.suffix(keepRecent))
        let old = Array(history.dropLast(keepRecent))
        guard !old.isEmpty else { return history }

        let transcript = old.map { m -> String in
            let who = m.role == .user ? "Bruger" : (m.role == .assistant ? "Assistent" : "System")
            return "\(who): \(m.content)"
        }.joined(separator: "\n\n")

        guard let raw = await summarize(transcript)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return history }

        return [
            ChatMessage(role: .user,
                        content: "Resumé af vores samtale indtil nu (komprimeret for at spare kontekst):\n\n\(raw)"),
            ChatMessage(role: .assistant, content: "Forstået — jeg bygger videre med det i tankerne."),
        ] + recent
    }

    /// Rough token estimate (≈ chars / 4), matching ContextBuilder's heuristic.
    public static func estimateTokens(_ history: [ChatMessage]) -> Int {
        history.reduce(0) { $0 + max(1, $1.content.count / 4) }
    }
}
