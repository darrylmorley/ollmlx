import Foundation
import HTTPTypes
import Hummingbird

/// Reverse proxy on :11434 that forwards all requests to mlx_lm.server's ephemeral port.
///
/// - `setUpstream(port:)` atomically switches the target (actor-isolated, no data races)
/// - Returns 503 immediately when no upstream is set
/// - Validates API key before forwarding (if configured)
/// - Streams responses chunk-by-chunk — never buffers a full response
public final class ProxyServer: Sendable {
    public static let shared = ProxyServer()

    private let upstream: UpstreamState
    private let config: OllmlxConfig
    private let logger: OllmlxLogger

    public init(config: OllmlxConfig = .shared, logger: OllmlxLogger = .shared) {
        self.upstream = UpstreamState()
        self.config = config
        self.logger = logger
    }

    // MARK: - Upstream Management (actor-isolated, atomic)

    /// Set the upstream port after mlx_lm.server is ready. Atomic — safe to call during model switch.
    public func setUpstream(port: Int) async {
        await upstream.set(port: port)
        logger.info("Proxy upstream set to port \(port)")
    }

    /// Clear the upstream port (model stopping or switching). Subsequent requests get 503.
    public func clearUpstream() async {
        await upstream.clear()
        logger.info("Proxy upstream cleared — returning 503 for all requests")
    }

    /// Returns the current upstream port, or nil if unavailable.
    public func currentUpstreamPort() async -> Int? {
        await upstream.port
    }

    // MARK: - Application

    /// Build the Hummingbird Application that proxies all requests.
    public func buildApplication() -> some ApplicationProtocol {
        let router = Router()
        let upstreamState = self.upstream
        let config = self.config
        let logger = self.logger
        let modelStore = ModelStore.shared

        // Ollama-compatible API endpoints (registered before catch-all)
        router.get("api/tags") { request, context -> Response in
            if let authErr = Self.checkAPIKey(request: request, config: config) { return authErr }
            return Self.handleTags(modelStore: modelStore)
        }

        router.get("api/version") { request, context -> Response in
            Self.jsonOK(#"{"version":"0.1.0"}"#)
        }

        router.post("api/chat") { request, context -> Response in
            if let authErr = Self.checkAPIKey(request: request, config: config) { return authErr }
            return try await Self.handleOllamaChat(request: request, context: context, upstream: upstreamState, logger: logger)
        }

        router.post("api/generate") { request, context -> Response in
            if let authErr = Self.checkAPIKey(request: request, config: config) { return authErr }
            return try await Self.handleOllamaGenerate(request: request, context: context, upstream: upstreamState, logger: logger)
        }

        // Catch-all: forward every request to the upstream
        router.on("**", method: .get) { request, context in
            try await Self.proxyRequest(request: request, context: context, upstream: upstreamState, config: config, logger: logger)
        }
        router.on("**", method: .post) { request, context in
            try await Self.proxyRequest(request: request, context: context, upstream: upstreamState, config: config, logger: logger)
        }
        router.on("**", method: .put) { request, context in
            try await Self.proxyRequest(request: request, context: context, upstream: upstreamState, config: config, logger: logger)
        }
        router.on("**", method: .delete) { request, context in
            try await Self.proxyRequest(request: request, context: context, upstream: upstreamState, config: config, logger: logger)
        }
        router.on("**", method: .patch) { request, context in
            try await Self.proxyRequest(request: request, context: context, upstream: upstreamState, config: config, logger: logger)
        }
        router.on("**", method: .options) { request, context in
            try await Self.proxyRequest(request: request, context: context, upstream: upstreamState, config: config, logger: logger)
        }
        router.on("**", method: .head) { request, context in
            try await Self.proxyRequest(request: request, context: context, upstream: upstreamState, config: config, logger: logger)
        }

        let bindHost = config.allowExternalConnections ? "0.0.0.0" : "127.0.0.1"
        let port = config.publicPort
        logger.info("ProxyServer will listen on \(bindHost):\(port)")

        return Application(
            router: router,
            configuration: .init(address: .hostname(bindHost, port: port))
        )
    }

    // MARK: - Proxy Logic

    private static func proxyRequest(
        request: Request,
        context: some RequestContext,
        upstream: UpstreamState,
        config: OllmlxConfig,
        logger: OllmlxLogger
    ) async throws -> Response {
        // 1. API key check — validate BEFORE forwarding
        if let expectedKey = config.apiKey, !expectedKey.isEmpty {
            let authHeader = request.headers[.authorization]
            let expected = "Bearer \(expectedKey)"
            guard authHeader == expected else {
                return Self.errorResponse(status: .unauthorized, message: "Invalid or missing API key")
            }
        }

        // 2. Get upstream port — 503 immediately if none
        guard let port = await upstream.port else {
            return Self.errorResponse(status: .serviceUnavailable, message: "No model is currently running")
        }

        // 3. Build upstream URL
        let path = request.uri.string
        guard let upstreamURL = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            return Self.errorResponse(status: .internalServerError, message: "Failed to construct upstream URL")
        }

        // 4. Build upstream request
        var upstreamRequest = URLRequest(url: upstreamURL)
        upstreamRequest.httpMethod = String(request.method.rawValue)

        // Forward relevant headers (skip host, connection)
        for field in request.headers {
            let name = String(field.name)
            let lowerName = name.lowercased()
            if lowerName == "host" || lowerName == "connection" || lowerName == "transfer-encoding" {
                continue
            }
            upstreamRequest.setValue(String(field.value), forHTTPHeaderField: name)
        }

        // Collect request body if present
        let bodyData = try await request.body.collect(upTo: context.maxUploadSize)
        if bodyData.readableBytes > 0 {
            upstreamRequest.httpBody = Data(buffer: bodyData)
        }

        // 5. Execute request and stream response back
        // Use URLSession.bytes for chunk-by-chunk streaming
        let session = URLSession(configuration: .ephemeral)

        let (asyncBytes, urlResponse) = try await session.bytes(for: upstreamRequest)

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            session.invalidateAndCancel()
            return Self.errorResponse(status: .badGateway, message: "Invalid response from upstream")
        }

        // Build response headers
        var responseHeaders = HTTPFields()
        for (key, value) in httpResponse.allHeaderFields {
            guard let name = key as? String, let val = value as? String else { continue }
            let lowerName = name.lowercased()
            // Skip hop-by-hop headers
            if lowerName == "connection" || lowerName == "transfer-encoding" || lowerName == "content-length" {
                continue
            }
            responseHeaders[HTTPField.Name(lowerName)!] = val
        }

        let status = HTTPResponse.Status(code: httpResponse.statusCode)

        // Check if this is a streaming response
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        let isStreaming = contentType.contains("text/event-stream") || contentType.contains("ndjson")

        if isStreaming {
            // Stream chunk-by-chunk — never buffer the full response
            // Session must stay alive until the body closure finishes writing,
            // so invalidate inside the closure, not via defer on the outer scope.
            return Response(
                status: status,
                headers: responseHeaders,
                body: ResponseBody { writer in
                    defer { session.invalidateAndCancel() }
                    // Stream bytes in chunks
                    var buffer = Data()
                    let flushThreshold = 256 // Flush at SSE line boundaries or every N bytes

                    for try await byte in asyncBytes {
                        buffer.append(byte)
                        // Flush on newline (SSE events end with \n\n) or buffer threshold
                        if byte == UInt8(ascii: "\n") || buffer.count >= flushThreshold {
                            try await writer.write(ByteBuffer(data: buffer))
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    // Flush remaining
                    if !buffer.isEmpty {
                        try await writer.write(ByteBuffer(data: buffer))
                    }
                    try await writer.finish(nil)
                }
            )
        } else {
            // Non-streaming: collect full response, then clean up session
            defer { session.invalidateAndCancel() }
            var responseData = Data()
            for try await byte in asyncBytes {
                responseData.append(byte)
            }
            return Response(
                status: status,
                headers: responseHeaders,
                body: .init(byteBuffer: ByteBuffer(data: responseData))
            )
        }
    }

    // MARK: - Ollama API Compatibility

    /// Check API key, returning an error Response if invalid, or nil if OK.
    private static func checkAPIKey(request: Request, config: OllmlxConfig) -> Response? {
        guard let expectedKey = config.apiKey, !expectedKey.isEmpty else { return nil }
        let authHeader = request.headers[.authorization]
        let expected = "Bearer \(expectedKey)"
        guard authHeader == expected else {
            return errorResponse(status: .unauthorized, message: "Invalid or missing API key")
        }
        return nil
    }

    /// GET /api/tags — return cached models in Ollama format.
    private static func handleTags(modelStore: ModelStore) -> Response {
        let models = modelStore.refreshCached()
        let ollamaModels = models.map { model -> [String: Any] in
            let formatter = ISO8601DateFormatter()
            var details: [String: Any] = ["format": "mlx"]

            // Extract family from repo name (e.g., "Llama" from "mlx-community/Llama-3.2-3B-Instruct-4bit")
            let namePart = model.repoID.split(separator: "/").last.map(String.init) ?? model.repoID
            let family = namePart.split(separator: "-").first.map { String($0).lowercased() } ?? "unknown"
            details["family"] = family

            // Extract parameter size from name (e.g., "3B")
            if let range = namePart.range(of: #"\d+(\.\d+)?[BbMm]"#, options: .regularExpression) {
                details["parameter_size"] = String(namePart[range])
            }

            if let q = model.quantisation {
                details["quantization_level"] = q
            }

            return [
                "name": model.repoID,
                "model": model.repoID,
                "modified_at": formatter.string(from: model.modifiedAt),
                "size": model.diskSize,
                "digest": "",
                "details": details,
            ]
        }

        let result: [String: Any] = ["models": ollamaModels]
        guard let data = try? JSONSerialization.data(withJSONObject: result) else {
            return errorResponse(status: .internalServerError, message: "Failed to encode models")
        }
        return jsonOK(String(data: data, encoding: .utf8) ?? "{}")
    }

    /// Ensure the requested model is running, switching if necessary.
    /// Returns the upstream port to use, or nil if the model can't be started.
    private static func ensureModel(_ requestedModel: String, upstream: UpstreamState, logger: OllmlxLogger) async throws -> Int? {
        guard !requestedModel.isEmpty else { return await upstream.port }

        // Check current state on the main actor
        let currentModel: String? = await MainActor.run {
            if case .running(let model, _) = ServerManager.shared.state {
                return model
            }
            return nil
        }

        // If already running the requested model, return current port
        if let current = currentModel, current == requestedModel {
            return await upstream.port
        }

        // Model switch needed — stop current, start requested
        logger.info("Model switch requested: \(currentModel ?? "none") → \(requestedModel)")

        do {
            // ServerManager methods are @MainActor — await hops to main actor automatically
            await ServerManager.shared.stop()
            try await ServerManager.shared.start(model: requestedModel)

            // After start, the upstream port is set by ServerManager
            return await upstream.port
        } catch {
            logger.error("Model switch failed: \(error)")
            return nil
        }
    }

    /// POST /api/chat — translate Ollama chat request to OpenAI format, proxy, translate back.
    private static func handleOllamaChat(
        request: Request,
        context: some RequestContext,
        upstream: UpstreamState,
        logger: OllmlxLogger
    ) async throws -> Response {
        let bodyData = try await request.body.collect(upTo: context.maxUploadSize)
        guard bodyData.readableBytes > 0,
              let ollamaReq = try? JSONSerialization.jsonObject(with: Data(buffer: bodyData)) as? [String: Any] else {
            return errorResponse(status: .badRequest, message: "Invalid JSON body")
        }

        let model = ollamaReq["model"] as? String ?? ""
        let messages = ollamaReq["messages"] as? [[String: Any]] ?? []
        let stream = ollamaReq["stream"] as? Bool ?? true

        // Ensure the requested model is running (switch if needed)
        guard let port = try await ensureModel(model, upstream: upstream, logger: logger) else {
            return errorResponse(status: .serviceUnavailable, message: "Failed to start model: \(model)")
        }

        // Build OpenAI request
        var openAIReq: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream,
        ]
        if let options = ollamaReq["options"] as? [String: Any] {
            if let temp = options["temperature"] { openAIReq["temperature"] = temp }
            if let topP = options["top_p"] { openAIReq["top_p"] = topP }
            if let maxTokens = options["num_predict"] { openAIReq["max_tokens"] = maxTokens }
        }

        let openAIBody = try JSONSerialization.data(withJSONObject: openAIReq)

        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = openAIBody

        let session = URLSession(configuration: .ephemeral)

        if stream {
            let (asyncBytes, urlResponse) = try await session.bytes(for: urlRequest)
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                session.invalidateAndCancel()
                return errorResponse(status: .badGateway, message: "Invalid response from upstream")
            }

            if httpResponse.statusCode != 200 {
                defer { session.invalidateAndCancel() }
                var data = Data()
                for try await byte in asyncBytes { data.append(byte) }
                return errorResponse(
                    status: HTTPResponse.Status(code: httpResponse.statusCode),
                    message: String(data: data, encoding: .utf8) ?? "Upstream error"
                )
            }

            var responseHeaders = HTTPFields()
            responseHeaders[.contentType] = "application/x-ndjson"

            return Response(
                status: .ok,
                headers: responseHeaders,
                body: ResponseBody { writer in
                    defer { session.invalidateAndCancel() }
                    var lineBuffer = Data()
                    for try await byte in asyncBytes {
                        lineBuffer.append(byte)
                        guard byte == UInt8(ascii: "\n") else { continue }
                        guard let line = String(data: lineBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              line.hasPrefix("data: ") else {
                            lineBuffer.removeAll(keepingCapacity: true)
                            continue
                        }
                        let payload = String(line.dropFirst(6))
                        lineBuffer.removeAll(keepingCapacity: true)

                        if payload == "[DONE]" {
                            // Final message
                            let done: [String: Any] = [
                                "model": model,
                                "created_at": ISO8601DateFormatter().string(from: Date()),
                                "message": ["role": "assistant", "content": ""],
                                "done": true,
                            ]
                            if let data = try? JSONSerialization.data(withJSONObject: done) {
                                try await writer.write(ByteBuffer(data: data + Data("\n".utf8)))
                            }
                            break
                        }

                        guard let chunkData = payload.data(using: .utf8),
                              let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                              let choices = chunk["choices"] as? [[String: Any]],
                              let first = choices.first,
                              let delta = first["delta"] as? [String: Any] else { continue }

                        let content = delta["content"] as? String ?? ""
                        let ollamaChunk: [String: Any] = [
                            "model": model,
                            "created_at": ISO8601DateFormatter().string(from: Date()),
                            "message": ["role": "assistant", "content": content],
                            "done": false,
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: ollamaChunk) {
                            try await writer.write(ByteBuffer(data: data + Data("\n".utf8)))
                        }
                    }
                    try await writer.finish(nil)
                }
            )
        } else {
            // Non-streaming
            defer { session.invalidateAndCancel() }
            let (data, urlResponse) = try await session.data(for: urlRequest)
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                return errorResponse(status: .badGateway, message: "Invalid response from upstream")
            }

            if httpResponse.statusCode != 200 {
                return errorResponse(
                    status: HTTPResponse.Status(code: httpResponse.statusCode),
                    message: String(data: data, encoding: .utf8) ?? "Upstream error"
                )
            }

            guard let openAIResp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = openAIResp["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any] else {
                return errorResponse(status: .badGateway, message: "Unexpected upstream response format")
            }

            let ollamaResp: [String: Any] = [
                "model": model,
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "message": message,
                "done": true,
            ]
            guard let respData = try? JSONSerialization.data(withJSONObject: ollamaResp) else {
                return errorResponse(status: .internalServerError, message: "Failed to encode response")
            }
            return jsonOK(String(data: respData, encoding: .utf8) ?? "{}")
        }
    }

    /// POST /api/generate — translate Ollama generate request to OpenAI completions format.
    private static func handleOllamaGenerate(
        request: Request,
        context: some RequestContext,
        upstream: UpstreamState,
        logger: OllmlxLogger
    ) async throws -> Response {
        let bodyData = try await request.body.collect(upTo: context.maxUploadSize)
        guard bodyData.readableBytes > 0,
              let ollamaReq = try? JSONSerialization.jsonObject(with: Data(buffer: bodyData)) as? [String: Any] else {
            return errorResponse(status: .badRequest, message: "Invalid JSON body")
        }

        let model = ollamaReq["model"] as? String ?? ""
        let prompt = ollamaReq["prompt"] as? String ?? ""
        let stream = ollamaReq["stream"] as? Bool ?? true

        // Ensure the requested model is running (switch if needed)
        guard let port = try await ensureModel(model, upstream: upstream, logger: logger) else {
            return errorResponse(status: .serviceUnavailable, message: "Failed to start model: \(model)")
        }

        // mlx_lm.server supports /v1/chat/completions — use that with a single user message
        var openAIReq: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": stream,
        ]
        if let options = ollamaReq["options"] as? [String: Any] {
            if let temp = options["temperature"] { openAIReq["temperature"] = temp }
            if let topP = options["top_p"] { openAIReq["top_p"] = topP }
            if let maxTokens = options["num_predict"] { openAIReq["max_tokens"] = maxTokens }
        }

        let openAIBody = try JSONSerialization.data(withJSONObject: openAIReq)

        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = openAIBody

        let session = URLSession(configuration: .ephemeral)

        if stream {
            let (asyncBytes, urlResponse) = try await session.bytes(for: urlRequest)
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                session.invalidateAndCancel()
                return errorResponse(status: .badGateway, message: "Invalid response from upstream")
            }

            if httpResponse.statusCode != 200 {
                defer { session.invalidateAndCancel() }
                var data = Data()
                for try await byte in asyncBytes { data.append(byte) }
                return errorResponse(
                    status: HTTPResponse.Status(code: httpResponse.statusCode),
                    message: String(data: data, encoding: .utf8) ?? "Upstream error"
                )
            }

            var responseHeaders = HTTPFields()
            responseHeaders[.contentType] = "application/x-ndjson"

            return Response(
                status: .ok,
                headers: responseHeaders,
                body: ResponseBody { writer in
                    defer { session.invalidateAndCancel() }
                    var lineBuffer = Data()
                    for try await byte in asyncBytes {
                        lineBuffer.append(byte)
                        guard byte == UInt8(ascii: "\n") else { continue }
                        guard let line = String(data: lineBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              line.hasPrefix("data: ") else {
                            lineBuffer.removeAll(keepingCapacity: true)
                            continue
                        }
                        let payload = String(line.dropFirst(6))
                        lineBuffer.removeAll(keepingCapacity: true)

                        if payload == "[DONE]" {
                            let done: [String: Any] = [
                                "model": model,
                                "created_at": ISO8601DateFormatter().string(from: Date()),
                                "response": "",
                                "done": true,
                            ]
                            if let data = try? JSONSerialization.data(withJSONObject: done) {
                                try await writer.write(ByteBuffer(data: data + Data("\n".utf8)))
                            }
                            break
                        }

                        guard let chunkData = payload.data(using: .utf8),
                              let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                              let choices = chunk["choices"] as? [[String: Any]],
                              let first = choices.first,
                              let delta = first["delta"] as? [String: Any] else { continue }

                        let content = delta["content"] as? String ?? ""
                        let ollamaChunk: [String: Any] = [
                            "model": model,
                            "created_at": ISO8601DateFormatter().string(from: Date()),
                            "response": content,
                            "done": false,
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: ollamaChunk) {
                            try await writer.write(ByteBuffer(data: data + Data("\n".utf8)))
                        }
                    }
                    try await writer.finish(nil)
                }
            )
        } else {
            defer { session.invalidateAndCancel() }
            let (data, urlResponse) = try await session.data(for: urlRequest)
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                return errorResponse(status: .badGateway, message: "Invalid response from upstream")
            }

            if httpResponse.statusCode != 200 {
                return errorResponse(
                    status: HTTPResponse.Status(code: httpResponse.statusCode),
                    message: String(data: data, encoding: .utf8) ?? "Upstream error"
                )
            }

            guard let openAIResp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = openAIResp["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any] else {
                return errorResponse(status: .badGateway, message: "Unexpected upstream response format")
            }

            let content = message["content"] as? String ?? ""
            let ollamaResp: [String: Any] = [
                "model": model,
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "response": content,
                "done": true,
            ]
            guard let respData = try? JSONSerialization.data(withJSONObject: ollamaResp) else {
                return errorResponse(status: .internalServerError, message: "Failed to encode response")
            }
            return jsonOK(String(data: respData, encoding: .utf8) ?? "{}")
        }
    }

    private static func jsonOK(_ json: String) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: json)))
    }

    private static func errorResponse(status: HTTPResponse.Status, message: String) -> Response {
        let json = "{\"error\":\"\(message)\"}"
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(string: json))
        )
    }
}

// MARK: - UpstreamState Actor

/// Actor that holds the upstream port atomically.
/// All reads and writes are serialized — no data races during model switching.
actor UpstreamState {
    private(set) var port: Int?

    func set(port: Int) {
        self.port = port
    }

    func clear() {
        self.port = nil
    }
}
