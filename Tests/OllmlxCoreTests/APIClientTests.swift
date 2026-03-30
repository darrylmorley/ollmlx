import XCTest
@testable import OllmlxCore

/// Tests for APIClient and REPL types.
/// These are unit-level tests — we can't test streaming against a real mlx_lm.server
/// but we can verify initialization, URL construction, and error types.
final class APIClientTests: XCTestCase {

    func testAPIClientInitWithDefaults() {
        let client = APIClient()
        // Should not crash — default URL and no API key
        XCTAssertNotNil(client)
    }

    func testAPIClientInitWithAPIKey() {
        let client = APIClient(apiKey: "test-key-123")
        XCTAssertNotNil(client)
    }

    func testAPIClientInitWithCustomURL() {
        let client = APIClient(baseURL: "http://localhost:9999")
        XCTAssertNotNil(client)
    }

    func testAPIClientErrorDescriptions() {
        XCTAssertNotNil(APIClientError.invalidURL.errorDescription)
        XCTAssertNotNil(APIClientError.invalidResponse.errorDescription)
        XCTAssertNotNil(APIClientError.httpError(500).errorDescription)
        XCTAssertTrue(APIClientError.httpError(500).errorDescription!.contains("500"))
    }

    func testREPLInitialization() {
        let client = APIClient()
        let repl = REPL(model: "test-model", client: client)
        XCTAssertNotNil(repl)
    }

    func testControlClientErrorDescriptions() {
        XCTAssertNotNil(ControlClientError.daemonNotRunning.errorDescription)
        XCTAssertTrue(ControlClientError.daemonNotRunning.errorDescription!.contains("11435"))
        XCTAssertNotNil(ControlClientError.unexpectedStatus(404).errorDescription)
        XCTAssertNotNil(ControlClientError.decodingFailed.errorDescription)
    }
}
