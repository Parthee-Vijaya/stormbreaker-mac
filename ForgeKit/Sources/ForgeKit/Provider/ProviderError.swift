import Foundation

/// Failures from a chat-model provider.
public enum ProviderError: Error, Sendable, Equatable {
    case missingAPIKey(provider: String)
    case http(status: Int, body: String)
    case decoding(String)
    case transport(String)
}

extension ProviderError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingAPIKey(let provider):
            "Missing API key for \(provider). Set FORGE_CLOUD_API_KEY."
        case .http(let status, let body):
            "Model request failed (HTTP \(status)): \(Self.humanMessage(from: body))"
        case .decoding(let message):
            "Could not decode the model response: \(message)"
        case .transport(let message):
            "Network error talking to the model: \(message)"
        }
    }

    /// Pull the human message out of an OpenAI-style error body
    /// (`{"error":{"message":"…"}}`, also used by LM Studio/Ollama) so a beginner sees
    /// e.g. "Failed to load model … insufficient system resources" instead of raw JSON.
    /// Falls back to the trimmed body.
    static func humanMessage(from body: String) -> String {
        let fallback = String(body.prefix(300))
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return fallback }
        if let error = obj["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty {
            return String(message.prefix(300))
        }
        if let message = obj["message"] as? String, !message.isEmpty {
            return String(message.prefix(300))
        }
        return fallback
    }
}
