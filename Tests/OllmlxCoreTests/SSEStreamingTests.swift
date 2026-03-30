import XCTest
import Hummingbird
import HummingbirdTesting
@testable import OllmlxCore

/// Tests specifically validating SSE streaming behavior of /control/pull.
/// The pull endpoint MUST return proper Server-Sent Events format:
///   - Content-Type: text/event-stream
///   - Each event: "data: <JSON>\n\n"
///   - Final event: "data: {\"done\":true}\n\n"
/// It must NOT return a buffered JSON array.
final class SSEStreamingTests: XCTestCase {

    func testPullEndpointReturnsSSEContentType() async throws {
        let daemon = DaemonServer()
        let app = daemon.buildApplication()

        try await app.test(.router) { client in
            // Use a model that won't be found — the response will still be SSE format
            // with an error event, not a JSON object
            let body = ByteBuffer(string: #"{"model":"test/nonexistent-model-for-sse-test"}"#)
            try await client.execute(uri: "/control/pull", method: .post, body: body) { response in
                // Verify SSE content type
                XCTAssertEqual(response.status, .ok)

                let contentType = response.headers[.contentType]
                XCTAssertEqual(contentType, "text/event-stream",
                    "Pull endpoint must return text/event-stream, not application/json")
            }
        }
    }

    func testPullEndpointReturnsSSEFormattedEvents() async throws {
        let daemon = DaemonServer()
        let app = daemon.buildApplication()

        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"model":"test/nonexistent-model-for-sse-test"}"#)
            try await client.execute(uri: "/control/pull", method: .post, body: body) { response in
                // Read the full response body
                let responseString = String(buffer: response.body)

                // It must use SSE format: "data: ...\n\n" lines
                // NOT a JSON array like "[{...}, {...}]"
                XCTAssertFalse(responseString.hasPrefix("["),
                    "Pull endpoint must NOT return a JSON array — it must use SSE format")

                // Each line with content should start with "data: "
                let lines = responseString.split(separator: "\n", omittingEmptySubsequences: true)
                for line in lines {
                    XCTAssertTrue(line.hasPrefix("data: "),
                        "Each SSE event line must start with 'data: ', got: \(line)")
                }

                // Verify there's at least one data line (either progress, error, or done)
                XCTAssertFalse(lines.isEmpty,
                    "Pull endpoint must return at least one SSE event")
            }
        }
    }

    func testPullEndpointSSEEventsAreValidJSON() async throws {
        let daemon = DaemonServer()
        let app = daemon.buildApplication()

        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"model":"test/nonexistent-model-for-sse-test"}"#)
            try await client.execute(uri: "/control/pull", method: .post, body: body) { response in
                let responseString = String(buffer: response.body)
                let lines = responseString.split(separator: "\n", omittingEmptySubsequences: true)

                for line in lines {
                    let stripped = line.dropFirst("data: ".count)
                    let jsonString = String(stripped)

                    // Each data payload must be valid JSON
                    guard let data = jsonString.data(using: .utf8) else {
                        XCTFail("Could not convert SSE payload to data: \(jsonString)")
                        continue
                    }

                    do {
                        _ = try JSONSerialization.jsonObject(with: data)
                    } catch {
                        XCTFail("SSE event payload is not valid JSON: \(jsonString)")
                    }
                }
            }
        }
    }

    func testSSEDoneEventFormat() async throws {
        let daemon = DaemonServer()
        let app = daemon.buildApplication()

        try await app.test(.router) { client in
            // Pull a model that exists in cache (if any) or a nonexistent one
            // Either way, the stream should end with either a done event or error event
            let body = ByteBuffer(string: #"{"model":"test/nonexistent-model-for-sse-test"}"#)
            try await client.execute(uri: "/control/pull", method: .post, body: body) { response in
                let responseString = String(buffer: response.body)
                let lines = responseString.split(separator: "\n", omittingEmptySubsequences: true)

                // The last event should contain either "done" or "error"
                guard let lastLine = lines.last else {
                    XCTFail("No SSE events in response")
                    return
                }

                let payload = String(lastLine.dropFirst("data: ".count))
                let containsDone = payload.contains("\"done\"")
                let containsError = payload.contains("\"error\"")

                XCTAssertTrue(containsDone || containsError,
                    "Final SSE event must contain 'done' or 'error', got: \(payload)")
            }
        }
    }
}
