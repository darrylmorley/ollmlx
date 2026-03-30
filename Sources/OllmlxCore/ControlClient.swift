import Foundation

/// HTTP client for the daemon control API on localhost:11435.
/// Used by the CLI and menubar app to manage the server.
public final class ControlClient: Sendable {
    private let baseURL: String

    public init(baseURL: String = "http://127.0.0.1:11435") {
        self.baseURL = baseURL
    }

    // MARK: - GET /control/status

    public func status() async throws -> StatusResponse {
        let data = try await get(path: "/control/status")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(StatusResponse.self, from: data) else {
            throw ControlClientError.decodingFailed
        }
        return response
    }

    // MARK: - POST /control/start

    public func start(model: String) async throws -> StatusResponse {
        let body = try JSONEncoder().encode(["model": model])
        let data = try await post(path: "/control/start", body: body)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(StatusResponse.self, from: data) else {
            throw ControlClientError.decodingFailed
        }
        return response
    }

    // MARK: - POST /control/stop

    public func stop() async throws {
        _ = try await post(path: "/control/stop", body: nil)
    }

    // MARK: - GET /control/models

    public func models() async throws -> [LocalModel] {
        let data = try await get(path: "/control/models")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let models = try? decoder.decode([LocalModel].self, from: data) else {
            throw ControlClientError.decodingFailed
        }
        return models
    }

    // MARK: - POST /control/pull (SSE stream)

    public func pull(model: String) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try JSONEncoder().encode(["model": model])
                    guard let url = URL(string: "\(baseURL)/control/pull") else {
                        continuation.finish(throwing: ControlClientError.decodingFailed)
                        return
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.httpBody = body
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let session = URLSession(configuration: .ephemeral)
                    defer { session.invalidateAndCancel() }

                    let (asyncBytes, urlResponse) = try await session.bytes(for: request)

                    guard let httpResponse = urlResponse as? HTTPURLResponse else {
                        continuation.finish(throwing: ControlClientError.decodingFailed)
                        return
                    }

                    if httpResponse.statusCode != 200 {
                        continuation.finish(throwing: ControlClientError.unexpectedStatus(httpResponse.statusCode))
                        return
                    }

                    let decoder = JSONDecoder()

                    for try await line in asyncBytes.lines {
                        // SSE format: "data: <JSON>"
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst("data: ".count))

                        // Check for done event
                        if payload.contains("\"done\"") && payload.contains("true") {
                            break
                        }

                        // Check for error event
                        if payload.contains("\"error\"") {
                            continuation.finish(throwing: ControlClientError.decodingFailed)
                            return
                        }

                        guard let data = payload.data(using: .utf8),
                              let progress = try? decoder.decode(PullProgress.self, from: data) else {
                            continue
                        }

                        continuation.yield(progress)
                    }

                    continuation.finish()
                } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCannotConnectToHost {
                    continuation.finish(throwing: ControlClientError.daemonNotRunning)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - HTTP Helpers

    private func get(path: String) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw ControlClientError.decodingFailed
        }

        let (data, response) = try await makeRequest(url: url, method: "GET", body: nil)
        try validateResponse(response, data: data)
        return data
    }

    private func post(path: String, body: Data?) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw ControlClientError.decodingFailed
        }

        let (data, response) = try await makeRequest(url: url, method: "POST", body: body)
        try validateResponse(response, data: data)
        return data
    }

    private func makeRequest(url: URL, method: String, body: Data?) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as NSError where error.domain == NSURLErrorDomain &&
            (error.code == NSURLErrorCannotConnectToHost) {
            throw ControlClientError.daemonNotRunning
        }
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ControlClientError.decodingFailed
        }

        // 204 No Content is valid (e.g. /control/stop)
        if httpResponse.statusCode == 204 {
            return
        }

        // Check for error responses with JSON body
        if httpResponse.statusCode >= 400 {
            throw ControlClientError.unexpectedStatus(httpResponse.statusCode)
        }
    }
}
