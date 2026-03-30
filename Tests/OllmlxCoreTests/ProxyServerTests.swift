import XCTest
import Hummingbird
import HummingbirdTesting
@testable import OllmlxCore

final class ProxyServerTests: XCTestCase {

    /// Save and restore the real Keychain API key so tests don't leak state.
    private var savedAPIKey: String?

    override func setUp() async throws {
        try await super.setUp()
        savedAPIKey = Keychain.getAPIKey()
        // Clear the Keychain so tests start with no API key
        try Keychain.setAPIKey(nil)
    }

    override func tearDown() async throws {
        // Restore original Keychain state
        try Keychain.setAPIKey(savedAPIKey)
        try await super.tearDown()
    }

    // MARK: - 503 when no upstream

    func testReturns503WhenNoUpstreamSet() async throws {
        let proxy = ProxyServer()
        let app = proxy.buildApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)

                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("No model is currently running"),
                    "503 response should explain that no model is running")
            }
        }
    }

    func testReturns503ForPostWhenNoUpstream() async throws {
        let proxy = ProxyServer()
        let app = proxy.buildApplication()

        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"model":"test"}"#)
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
            }
        }
    }

    // MARK: - API Key Validation

    func testReturns401WhenAPIKeyRequiredButMissing() async throws {
        // Set a key in Keychain for this test
        try Keychain.setAPIKey("test-secret-key-123")

        let proxy = ProxyServer()
        let app = proxy.buildApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized,
                    "Should return 401 when API key is required but not provided")

                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("Invalid or missing API key"))
            }
        }
    }

    func testReturns401WhenAPIKeyIsWrong() async throws {
        try Keychain.setAPIKey("correct-key")

        let proxy = ProxyServer()
        let app = proxy.buildApplication()

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/models",
                method: .get,
                headers: [.authorization: "Bearer wrong-key"]
            ) { response in
                XCTAssertEqual(response.status, .unauthorized,
                    "Should return 401 when API key doesn't match")
            }
        }
    }

    func testAPIKeyCheckHappensBeforeUpstreamCheck() async throws {
        // With an API key set but no upstream, we should get 401 (not 503)
        // This proves auth is checked BEFORE forwarding
        try Keychain.setAPIKey("my-secret")

        let proxy = ProxyServer()
        let app = proxy.buildApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized,
                    "API key check must happen before upstream check — should be 401, not 503")
            }
        }
    }

    func testPassesWithCorrectAPIKey() async throws {
        try Keychain.setAPIKey("my-secret")

        let proxy = ProxyServer()
        let app = proxy.buildApplication()

        try await app.test(.router) { client in
            // Correct key should pass auth but hit 503 (no upstream)
            try await client.execute(
                uri: "/v1/models",
                method: .get,
                headers: [.authorization: "Bearer my-secret"]
            ) { response in
                XCTAssertEqual(response.status, .serviceUnavailable,
                    "Correct API key should pass auth and reach upstream check (503)")
            }
        }
    }

    func testNoAPIKeyRequiredWhenNotConfigured() async throws {
        // Keychain cleared in setUp — requests should pass through to upstream check
        let proxy = ProxyServer()
        let app = proxy.buildApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                XCTAssertEqual(response.status, .serviceUnavailable,
                    "Without API key configured, should reach upstream check (503), not auth (401)")
            }
        }
    }

    // MARK: - Upstream State (Actor Atomicity)

    func testSetUpstreamAndClearUpstream() async throws {
        let proxy = ProxyServer()

        // Initially nil
        let initial = await proxy.currentUpstreamPort()
        XCTAssertNil(initial)

        // Set upstream
        await proxy.setUpstream(port: 54321)
        let afterSet = await proxy.currentUpstreamPort()
        XCTAssertEqual(afterSet, 54321)

        // Clear upstream
        await proxy.clearUpstream()
        let afterClear = await proxy.currentUpstreamPort()
        XCTAssertNil(afterClear)
    }

    func testUpstreamSwitchIsAtomic() async throws {
        let proxy = ProxyServer()

        // Simulate rapid model switching — set/clear/set in sequence
        await proxy.setUpstream(port: 10000)
        await proxy.clearUpstream()
        await proxy.setUpstream(port: 20000)

        let port = await proxy.currentUpstreamPort()
        XCTAssertEqual(port, 20000, "After switch, upstream should reflect the latest port")
    }

    // MARK: - All HTTP methods get 503

    func testAllHTTPMethodsReturn503WhenNoUpstream() async throws {
        let proxy = ProxyServer()
        let app = proxy.buildApplication()

        try await app.test(.router) { client in
            for method: HTTPRequest.Method in [.get, .post, .put, .delete, .patch, .head] {
                try await client.execute(uri: "/v1/test", method: method) { response in
                    XCTAssertEqual(response.status, .serviceUnavailable,
                        "\(method) should return 503 when no upstream is set")
                }
            }
        }
    }

    // MARK: - Proxy forwards to upstream

    func testSetUpstreamMakesPortAvailable() async throws {
        let proxy = ProxyServer()
        await proxy.setUpstream(port: 55555)
        let port = await proxy.currentUpstreamPort()
        XCTAssertEqual(port, 55555)
    }

    // MARK: - Error response format

    func testErrorResponseIsJSON() async throws {
        let proxy = ProxyServer()
        let app = proxy.buildApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                let contentType = response.headers[.contentType]
                XCTAssertEqual(contentType, "application/json",
                    "Error responses should be JSON")

                // Should be valid JSON
                let data = Data(buffer: response.body)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                XCTAssertNotNil(json?["error"], "Error response should have an 'error' field")
            }
        }
    }
}
