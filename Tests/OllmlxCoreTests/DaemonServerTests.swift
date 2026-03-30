import XCTest
import Hummingbird
import HummingbirdTesting
@testable import OllmlxCore

final class DaemonServerTests: XCTestCase {

    // Helper to create a DaemonServer with isolated config
    private func makeDaemonServer() -> DaemonServer {
        return DaemonServer()
    }

    // MARK: - GET /control/status

    func testGetStatusReturnsCurrentState() async throws {
        let daemon = makeDaemonServer()
        let app = daemon.buildApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/control/status", method: .get) { response in
                XCTAssertEqual(response.status, .ok)

                let body = response.body
                let status = try JSONDecoder().decode(StatusResponse.self, from: body)
                XCTAssertEqual(status.state, .stopped)
                XCTAssertEqual(status.publicPort, 11434)
                XCTAssertEqual(status.controlPort, 11435)
            }
        }
    }

    // MARK: - POST /control/stop

    func testPostStopReturns204() async throws {
        let daemon = makeDaemonServer()
        let app = daemon.buildApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/control/stop", method: .post) { response in
                XCTAssertEqual(response.status, .noContent)
            }
        }
    }

    // MARK: - POST /control/start — model not found

    func testPostStartReturns404ForMissingModel() async throws {
        let daemon = makeDaemonServer()
        let app = daemon.buildApplication()

        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"model":"nonexistent/model-xyz"}"#)
            try await client.execute(uri: "/control/start", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .notFound)

                let errorBody = try JSONDecoder().decode(ErrorBody.self, from: response.body)
                XCTAssertTrue(errorBody.error.contains("not found"))
            }
        }
    }

    // MARK: - GET /control/models

    func testGetModelsReturnsArray() async throws {
        let daemon = makeDaemonServer()
        let app = daemon.buildApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/control/models", method: .get) { response in
                XCTAssertEqual(response.status, .ok)

                // Should be a valid JSON array (may be empty)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let models = try decoder.decode([LocalModel].self, from: response.body)
                // We can't guarantee any models are cached, but the response should parse
                XCTAssertNotNil(models)
            }
        }
    }

    // MARK: - POST /control/pull — missing body

    func testPostPullReturns400ForInvalidBody() async throws {
        let daemon = makeDaemonServer()
        let app = daemon.buildApplication()

        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{}"#) // Missing "model" field
            try await client.execute(uri: "/control/pull", method: .post, body: body) { response in
                // Should fail to decode — Hummingbird returns 400 for decode errors
                XCTAssertTrue(
                    response.status == .badRequest || response.status == .internalServerError,
                    "Expected 400 or 500 for missing model field, got \(response.status)"
                )
            }
        }
    }

    // MARK: - POST /control/start — invalid JSON

    func testPostStartReturns400ForInvalidJSON() async throws {
        let daemon = makeDaemonServer()
        let app = daemon.buildApplication()

        try await app.test(.router) { client in
            let body = ByteBuffer(string: "not json")
            try await client.execute(uri: "/control/start", method: .post, body: body) { response in
                XCTAssertTrue(
                    response.status == .badRequest || response.status == .internalServerError,
                    "Expected 400 or 500 for invalid JSON, got \(response.status)"
                )
            }
        }
    }
}
