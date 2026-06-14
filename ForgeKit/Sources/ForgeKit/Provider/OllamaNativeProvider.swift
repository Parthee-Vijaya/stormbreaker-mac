import Foundation

/// Local default provider. Uses Ollama's NATIVE `/api/chat` endpoint (NDJSON
/// stream) so the context window can be set via `options.num_ctx`. The
/// OpenAI-compatible `/v1` path CANNOT set context and silently truncates input
/// at ~2–4k tokens — which would make the agent quietly forget files.
public struct OllamaNativeProvider: ChatModel {
    let baseURL: URL
    let modelID: String

    public init(baseURL: URL = URL(string: "http://localhost:11434")!, modelID: String) {
        self.baseURL = baseURL
        self.modelID = modelID
    }

    public func stream(messages: [ChatMessage], options: GenerationOptions)
        -> AsyncThrowingStream<ChatStreamEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body = Request(
                        model: modelID,
                        messages: messages.map { .init(role: $0.role.rawValue, content: $0.content) },
                        stream: true,
                        options: .init(num_ctx: options.numCtx, temperature: options.temperature)
                    )
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try await ensureOK(response, bytes: bytes)

                    let decoder = JSONDecoder()
                    for try await line in SSELineReader(bytes) {
                        if Task.isCancelled { break }
                        guard !line.isEmpty, let data = line.data(using: .utf8),
                              let chunk = try? decoder.decode(Chunk.self, from: data) else { continue }
                        if let thinking = chunk.message?.thinking, !thinking.isEmpty {
                            continuation.yield(.reasoning(thinking))
                        }
                        if let content = chunk.message?.content, !content.isEmpty {
                            continuation.yield(.token(content))
                        }
                        if chunk.done == true {
                            continuation.yield(.done(
                                reason: chunk.done_reason,
                                promptTokens: chunk.prompt_eval_count,
                                completionTokens: chunk.eval_count))
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
        let options: Options
        struct Message: Encodable { let role: String; let content: String }
        struct Options: Encodable { let num_ctx: Int; let temperature: Double }
    }

    private struct Chunk: Decodable {
        struct Message: Decodable { let content: String?; let thinking: String? }
        let message: Message?
        let done: Bool?
        let done_reason: String?
        let prompt_eval_count: Int?
        let eval_count: Int?
    }
}
