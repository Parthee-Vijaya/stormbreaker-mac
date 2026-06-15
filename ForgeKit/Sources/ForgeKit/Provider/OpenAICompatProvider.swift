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
            let watchdog = StreamWatchdog()
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
                        messages: messages.map {
                            .init(role: $0.role.rawValue, content: $0.content, images: $0.imageDataURLs)
                        },
                        stream: true,
                        temperature: options.temperature,
                        max_tokens: options.maxTokens,
                        stream_options: .init(include_usage: true))   // ask for a final usage chunk
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try await ensureOK(response, bytes: bytes)
                    watchdog.attach(bytes.task)
                    let monitor = Task { await watchdog.monitor() }
                    defer { monitor.cancel() }

                    let decoder = JSONDecoder()
                    var finishReason: String?
                    var promptTokens: Int?
                    var completionTokens: Int?
                    var emittedDone = false
                    for try await line in SSELineReader(bytes) {
                        if Task.isCancelled { break }
                        watchdog.touch()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            continuation.yield(.done(reason: finishReason ?? "stop",
                                                     promptTokens: promptTokens, completionTokens: completionTokens))
                            emittedDone = true
                            break
                        }
                        guard !payload.isEmpty, let data = payload.data(using: .utf8),
                              let chunk = try? decoder.decode(Chunk.self, from: data) else { continue }
                        if let reasoning = chunk.choices?.first?.delta.reasoningText, !reasoning.isEmpty {
                            continuation.yield(.reasoning(reasoning))
                        }
                        if let token = chunk.choices?.first?.delta.content, !token.isEmpty {
                            continuation.yield(.token(token))
                        }
                        if let usage = chunk.usage {
                            promptTokens = usage.prompt_tokens ?? promptTokens
                            completionTokens = usage.completion_tokens ?? completionTokens
                        }
                        // Capture the finish reason but keep reading: with
                        // include_usage on, a final usage-only chunk (empty
                        // choices) arrives before [DONE].
                        if let reason = chunk.choices?.first?.finish_reason, !reason.isEmpty {
                            finishReason = reason
                        }
                    }
                    if !emittedDone {
                        continuation.yield(.done(reason: finishReason ?? "stop",
                                                 promptTokens: promptTokens, completionTokens: completionTokens))
                    }
                    watchdog.finish()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: watchdog.didTimeout() ? StreamWatchdog.timeoutError : error)
                }
            }
            continuation.onTermination = { _ in task.cancel(); watchdog.cancel() }
        }
    }

    private struct Request: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let temperature: Double
        let max_tokens: Int
        let stream_options: StreamOptions?

        struct StreamOptions: Encodable { let include_usage: Bool }

        /// Encodes `content` as a plain string normally, or as the OpenAI
        /// multimodal parts array (`[{type:text}, {type:image_url}]`) when the
        /// message carries images — the format vision models expect.
        struct Message: Encodable {
            let role: String
            let content: String
            let images: [String]

            enum CodingKeys: String, CodingKey { case role, content }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(role, forKey: .role)
                if images.isEmpty {
                    try c.encode(content, forKey: .content)
                } else {
                    var parts: [ContentPart] = [.text(content)]
                    parts.append(contentsOf: images.map(ContentPart.imageURL))
                    try c.encode(parts, forKey: .content)
                }
            }
        }

        enum ContentPart: Encodable {
            case text(String)
            case imageURL(String)

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .text(let t):
                    try c.encode("text", forKey: .type)
                    try c.encode(t, forKey: .text)
                case .imageURL(let url):
                    try c.encode("image_url", forKey: .type)
                    try c.encode(ImageURL(url: url), forKey: .image_url)
                }
            }
            enum CodingKeys: String, CodingKey { case type, text, image_url }
            struct ImageURL: Encodable { let url: String }
        }
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
        struct Usage: Decodable {
            let prompt_tokens: Int?
            let completion_tokens: Int?
        }
        let choices: [Choice]?
        let usage: Usage?
    }
}
