import XCTest
@testable import ForgeKit

/// Live test against the local Ollama daemon (qwen2.5-coder:14b). Proves the
/// native /api/chat streaming + num_ctx path works. Gated behind
/// FORGE_RUN_INTEGRATION=1 (requires Ollama running with the model pulled).
final class OllamaProviderLiveTests: XCTestCase {
    func testStreamsTokensFromLocalModel() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FORGE_RUN_INTEGRATION"] == "1",
            "set FORGE_RUN_INTEGRATION=1 (and run Ollama) to run the live model test"
        )

        let provider = OllamaNativeProvider(modelID: "qwen2.5-coder:14b")
        let messages = [
            ChatMessage(role: .system, content: "You are terse. Reply with a single short sentence."),
            ChatMessage(role: .user, content: "Say hello to Forge."),
        ]

        var text = ""
        var sawDone = false
        for try await event in provider.stream(
            messages: messages,
            options: GenerationOptions(temperature: 0.1, numCtx: 32_768, maxTokens: 64)
        ) {
            switch event {
            case .token(let token): text += token
            case .reasoning: break
            case .done: sawDone = true
            }
        }

        XCTAssertTrue(sawDone, "expected a .done event")
        XCTAssertFalse(
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "expected non-empty streamed text"
        )
    }
}
