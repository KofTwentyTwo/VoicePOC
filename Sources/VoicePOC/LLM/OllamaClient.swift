import Foundation

/// Thin HTTP client for the Ollama local LLM server (http://localhost:11434).
///
/// Supports streaming (NDJSON) and non-streaming chat, plus a health check
/// that verifies the server is up and the target model is pulled.
///
/// Privacy: message content is never logged — only counts and model names.
public final class OllamaClient: Sendable {

    private let baseURL: URL
    private let defaultModel: String

    public init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        defaultModel: String = "gemma4:latest"
    ) {
        self.baseURL = baseURL
        self.defaultModel = defaultModel
    }

    // MARK: - Public types

    public struct Message: Sendable, Codable {
        public let role: String     // "system" | "user" | "assistant"
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    // MARK: - Private wire types

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
    }

    private struct ChatStreamChunk: Decodable {
        struct ChunkMessage: Decodable {
            let role: String
            let content: String
        }
        let model: String
        let message: ChunkMessage?
        let done: Bool
    }

    private struct TagsResponse: Decodable {
        struct ModelEntry: Decodable { let name: String }
        let models: [ModelEntry]
    }

    // MARK: - Health check

    /// Verify Ollama is reachable and the default model is available.
    ///
    /// Returns `false` if the server is unreachable or the model isn't pulled;
    /// throws only on unrecoverable protocol errors.
    public func healthCheck() async throws -> Bool {
        let url = baseURL.appendingPathComponent("api/tags")
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.0
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Log.state.warning("ollama healthCheck: non-200 response")
                return false
            }
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            let names = tags.models.map(\.name)
            let ok = names.contains(defaultModel)
            Log.state.info("ollama healthCheck: \(names.count) models pulled, default '\(defaultModel)' \(ok ? "found" : "MISSING")")
            return ok
        } catch {
            Log.state.warning("ollama healthCheck failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Streaming chat

    /// Stream response tokens from Ollama as they arrive (NDJSON line-by-line).
    ///
    /// Each yielded `String` is a token chunk. Accumulate them for the full response.
    public func chatStream(model: String? = nil, messages: [Message]) -> AsyncThrowingStream<String, Error> {
        let modelName = model ?? defaultModel
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = baseURL.appendingPathComponent("api/chat")
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body = ChatRequest(model: modelName, messages: messages, stream: true)
                    req.httpBody = try JSONEncoder().encode(body)

                    Log.state.info("ollama chat: model=\(modelName) messages=\(messages.count)")

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line + "\n" }
                        continuation.finish(throwing: OllamaError.httpError(http.statusCode, errBody))
                        return
                    }

                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }
                        do {
                            let chunk = try decoder.decode(ChatStreamChunk.self, from: lineData)
                            if let token = chunk.message?.content, !token.isEmpty {
                                continuation.yield(token)
                            }
                            if chunk.done { break }
                        } catch {
                            continuation.finish(throwing: OllamaError.decodingError("line: \(line) error: \(error)"))
                            return
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

    // MARK: - Non-streaming convenience

    /// Return the full assistant response as a single `String`.
    ///
    /// Internally consumes `chatStream` and joins all token chunks.
    public func chat(model: String? = nil, messages: [Message]) async throws -> String {
        var full = ""
        for try await chunk in chatStream(model: model, messages: messages) {
            full += chunk
        }
        return full
    }
}

// MARK: - Errors

public enum OllamaError: Error {
    case notReachable
    case modelNotAvailable(String)
    case httpError(Int, String)
    case decodingError(String)
}
