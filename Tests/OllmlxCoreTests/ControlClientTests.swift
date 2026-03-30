import XCTest
import Hummingbird
import HummingbirdTesting
@testable import OllmlxCore

/// Tests for ControlClient connecting to DaemonServer.
/// Uses HummingbirdTesting to run DaemonServer in-process.
final class ControlClientTests: XCTestCase {

    // MARK: - Status

    func testStatusReturnsStoppedByDefault() async throws {
        let daemon = DaemonServer()
        let app = daemon.buildApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/control/status", method: .get) { response in
                XCTAssertEqual(response.status, .ok)

                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let status = try decoder.decode(StatusResponse.self, from: response.body)
                XCTAssertEqual(status.state, .stopped)
                XCTAssertEqual(status.publicPort, 11434)
                XCTAssertEqual(status.controlPort, 11435)
            }
        }
    }

    // MARK: - Models

    func testModelsReturnsArray() async throws {
        let daemon = DaemonServer()
        let app = daemon.buildApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/control/models", method: .get) { response in
                XCTAssertEqual(response.status, .ok)

                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let models = try decoder.decode([LocalModel].self, from: response.body)
                XCTAssertNotNil(models)
            }
        }
    }

    // MARK: - Stop

    func testStopReturns204() async throws {
        let daemon = DaemonServer()
        let app = daemon.buildApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/control/stop", method: .post) { response in
                XCTAssertEqual(response.status, .noContent)
            }
        }
    }

    // MARK: - Start with missing model

    func testStartWithMissingModelReturns404() async throws {
        let daemon = DaemonServer()
        let app = daemon.buildApplication()

        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"model":"nonexistent/model-xyz"}"#)
            try await client.execute(uri: "/control/start", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    // MARK: - Pull SSE format

    func testPullReturnsSSEStream() async throws {
        let daemon = DaemonServer()
        let app = daemon.buildApplication()

        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"model":"test/nonexistent-for-pull-test"}"#)
            try await client.execute(uri: "/control/pull", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .ok)

                let contentType = response.headers[.contentType]
                XCTAssertEqual(contentType, "text/event-stream")

                let responseString = String(buffer: response.body)
                let lines = responseString.split(separator: "\n", omittingEmptySubsequences: true)
                for line in lines {
                    XCTAssertTrue(line.hasPrefix("data: "),
                        "Each SSE line must start with 'data: ', got: \(line)")
                }
            }
        }
    }
}
