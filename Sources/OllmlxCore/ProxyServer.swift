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
