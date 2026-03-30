import Foundation
import Hummingbird

/// HTTP server for the control API on localhost:11435.
/// Serves five endpoints under /control/* for the CLI and menubar app.
public final class DaemonServer: Sendable {
    private let config: OllmlxConfig
    private let logger: OllmlxLogger

    public init(config: OllmlxConfig = .shared, logger: OllmlxLogger = .shared) {
        self.config = config
        self.logger = logger
    }

    /// Build and return the Hummingbird Application. Caller is responsible for running it.
    public func buildApplication() -> some ApplicationProtocol {
        let router = Router()
        let config = self.config
        let logger = self.logger

        // MARK: - GET /control/status

        router.get("control/status") { _, _ -> Response in
            let state = await ServerManager.shared.state
            let status = StatusResponse(
                state: state,
                memoryUsage: nil,
                publicPort: config.publicPort,
                controlPort: config.controlPort,
                pythonPath: config.pythonPath.isEmpty ? nil : config.pythonPath
            )
            return try Self.jsonResponse(status)
        }

        // MARK: - POST /control/start

        router.post("control/start") { request, context -> Response in
            // Decode request body
            let body = try await request.body.collect(upTo: context.maxUploadSize)
            let startRequest = try JSONDecoder().decode(StartRequest.self, from: body)

            let model = startRequest.model

            // Check if already running — return 409
            let currentState = await ServerManager.shared.state
            if case .running = currentState {
                return try Self.errorResponse(status: .conflict, message: "Server is already running")
            }
            if case .starting = currentState {
                return try Self.errorResponse(status: .conflict, message: "Server is already starting")
            }

            // Validate model is cached
            guard ModelStore.shared.isModelCached(model) else {
                return try Self.errorResponse(
                    status: .notFound,
                    message: "Model not found in local cache: \(model)"
                )
            }

            // Start the server
            do {
                try await ServerManager.shared.start(model: model)
            } catch let error as ServerError {
                let statusCode: HTTPResponse.Status = switch error {
                case .alreadyRunning: .conflict
                case .modelNotFound: .notFound
                case .processDied, .timeout: .internalServerError
                }
                return try Self.errorResponse(status: statusCode, message: error.errorDescription ?? "Unknown error")
            }

            // Return updated status
            let state = await ServerManager.shared.state
            let status = StatusResponse(
                state: state,
                memoryUsage: nil,
                publicPort: config.publicPort,
                controlPort: config.controlPort,
                pythonPath: config.pythonPath.isEmpty ? nil : config.pythonPath
            )
            return try Self.jsonResponse(status)
        }

        // MARK: - POST /control/stop

        router.post("control/stop") { _, _ -> Response in
            await ServerManager.shared.stop()
            return Response(status: .noContent)
        }

        // MARK: - GET /control/models

        router.get("control/models") { _, _ -> Response in
            let models = ModelStore.shared.refreshCached()
            return try Self.jsonResponse(models)
        }

        // MARK: - POST /control/pull

        router.post("control/pull") { request, context -> Response in
            let body = try await request.body.collect(upTo: context.maxUploadSize)
            let pullRequest = try JSONDecoder().decode(PullRequest.self, from: body)

            let model = pullRequest.model
            logger.info("Starting pull for model: \(model)")

            let progressStream = ModelStore.shared.pull(model: model)

            // Return SSE response — each event is "data: <JSON>\n\n"
            // Final event is "data: {\"done\":true}\n\n"
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            headers[.cacheControl] = "no-cache"

            return Response(
                status: .ok,
                headers: headers,
                body: ResponseBody { writer in
                    let encoder = JSONEncoder()
                    do {
                        for try await progress in progressStream {
                            let jsonData = try encoder.encode(progress)
                            guard let jsonString = String(data: jsonData, encoding: .utf8) else { continue }
                            let sseEvent = "data: \(jsonString)\n\n"
                            try await writer.write(ByteBuffer(string: sseEvent))
                        }
                        // Send final done event
                        try await writer.write(ByteBuffer(string: "data: {\"done\":true}\n\n"))
                    } catch {
                        // Send error as SSE event before closing
                        let errorJSON = "{\"error\":\"\(error.localizedDescription)\"}"
                        try await writer.write(ByteBuffer(string: "data: \(errorJSON)\n\n"))
                    }
                    try await writer.finish(nil)
                }
            )
        }

        // Build the application
        let port = config.controlPort
        logger.info("DaemonServer will listen on 127.0.0.1:\(port)")

        return Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port))
        )
    }

    // MARK: - Helpers

    private static func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    private static func errorResponse(status: HTTPResponse.Status, message: String) throws -> Response {
        let error = ErrorBody(error: message)
        return try jsonResponse(error, status: status)
    }
}

// MARK: - Request / Response Types (internal to DaemonServer)

struct StartRequest: Decodable {
    let model: String
    let port: Int?
}

struct PullRequest: Decodable {
    let model: String
}

struct ErrorBody: Codable {
    let error: String
}
