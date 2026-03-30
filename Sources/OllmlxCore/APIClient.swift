import Foundation

/// HTTP client for the OpenAI-compatible API on localhost:11434.
/// Used by `ollmlx run` to stream chat completions.
public final class APIClient: Sendable {
    private let baseURL: String
    private let apiKey: String?

    public init(baseURL: String = "http://127.0.0.1:11434", apiKey: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// Stream chat completion tokens for a single user prompt.
    /// Returns an AsyncThrowingStream of text delta strings.
    public func stream(model: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        let messages = [["role": "user", "content": prompt]]
        return streamChat(model: model, messages: messages)
    }

    /// Stream chat completion tokens for a full message history.
    /// Returns an AsyncThrowingStream of text delta strings.
    public func streamChat(model: String, messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
                        continuation.finish(throwing: APIClientError.invalidURL)
                        return
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let apiKey {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }

                    let body: [String: Any] = [
                        "model": model,
                        "messages": messages,
                        "stream": true,
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let session = URLSession(configuration: .ephemeral)
                    defer { session.invalidateAndCancel() }

                    let (asyncBytes, urlResponse) = try await session.bytes(for: request)

                    guard let httpResponse = urlResponse as? HTTPURLResponse else {
                        continuation.finish(throwing: APIClientError.invalidResponse)
                        return
                    }

                    if httpResponse.statusCode != 200 {
                        continuation.finish(throwing: APIClientError.httpError(httpResponse.statusCode))
                        return
                    }

                    for try await line in asyncBytes.lines {
                        // SSE format: "data: <JSON>" or "data: [DONE]"
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst("data: ".count))

                        if payload == "[DONE]" {
                            break
                        }

                        guard let data = payload.data(using: .utf8) else { continue }
                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else {
                            continue
                        }

                        continuation.yield(content)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Non-streaming chat completion. Returns the full response text.
    public func chat(model: String, messages: [[String: String]]) async throws -> String {
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw APIClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIClientError.httpError(code)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw APIClientError.invalidResponse
        }

        return content
    }
}

public enum APIClientError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        }
    }
}
