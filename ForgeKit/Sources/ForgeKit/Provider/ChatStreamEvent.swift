import Foundation

/// A single streamed event from a chat model, normalized across providers so
/// the agent loop and artifact parser never see provider-specific shapes.
/// Errors are surfaced by throwing from the `AsyncThrowingStream`, not as a case.
public enum ChatStreamEvent: Sendable {
    case token(String)
    /// Reasoning/"thinking" content from a reasoning model, surfaced separately
    /// from the answer. Emitted from structured provider fields (Ollama
    /// `message.thinking`, OpenAI-compatible `delta.reasoning_content`); inline
    /// `<think>…</think>` is split out later by `ReasoningSplitter`.
    case reasoning(String)
    case done(reason: String?, promptTokens: Int?, completionTokens: Int?)
}
