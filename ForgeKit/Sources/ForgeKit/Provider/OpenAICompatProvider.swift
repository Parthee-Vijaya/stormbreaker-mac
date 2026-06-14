import Foundation

/// OpenAI-compatible SSE provider. Serves NVIDIA NIM
/// (`https://integrate.api.nvidia.com/v1`), OpenAI, and any other
/// OpenAI-compatible endpoint — only the base URL, API key, and model id differ.
public struct OpenAICompatProvider: ChatModel {
    let baseURL: URL
    let apiKey: String?
    let modelID: String

    public init(baseURL: URL, apiKey: String?, modelID: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelID = modelID
    }

    public func stream(messages: [ChatMessage], options: GenerationOptions)
        -> AsyncThrowingStream<ChatStreamEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let apiKey, !apiKey.isEmpty {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    let body = Request(
                        model: modelID,
                        messages: messages.map { .init(role: $0.role.rawValue, content: $0.content) },
                        stream: true,
                        temperature: options.temperature,
                        max_tokens: options.maxTokens)
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try await ensureOK(response, bytes: bytes)

                    let decoder = JSONDecoder()
                    for try await line in SSELineReader(bytes) {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            continuation.yield(.done(reason: "stop", promptTokens: nil, completionTokens: nil))
                            break
                        }
                        guard !payload.isEmpty, let data = payload.data(using: .utf8),
                              let chunk = try? decoder.decode(Chunk.self, from: data) else { continue }
                        if let reasoning = chunk.choices.first?.delta.reasoningText, !reasoning.isEmpty {
                            continuation.yield(.reasoning(reasoning))
                        }
                        if let token = chunk.choices.first?.delta.content, !token.isEmpty {
                            continuation.yield(.token(token))
                        }
                        if let reason = chunk.choices.first?.finish_reason, !reason.isEmpty {
                            continuation.yield(.done(reason: reason, promptTokens: nil, completionTokens: nil))
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Request: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let temperature: Double
        let max_tokens: Int
        struct Message: Encodable { let role: String; let content: String }
    }

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                // Reasoning models expose thinking under different keys: DeepSeek /
                // NVIDIA NIM use `reasoning_content`, some gateways use `reasoning`.
                let reasoning_content: String?
                let reasoning: String?
                var reasoningText: String? { reasoning_content ?? reasoning }
            }
            let delta: Delta
            let finish_reason: String?
        }
        let choices: [Choice]
    }
}
