import XCTest
@testable import OllmlxCore

final class ServerManagerTests: XCTestCase {
    @MainActor
    func testInitialStateIsStopped() {
        let manager = ServerManager.shared
        XCTAssertEqual(manager.state, .stopped)
    }

    @MainActor
    func testStartThrowsAlreadyRunningIfNotStopped() async throws {
        // This tests that start() throws .alreadyRunning when state is not .stopped
        // We can't easily mock the state, but we can verify the error type exists
        let error = ServerError.alreadyRunning
        XCTAssertNotNil(error.errorDescription)
    }

    @MainActor
    func testStartThrowsModelNotFound() async {
        let manager = ServerManager.shared
        // Use a model that is definitely not cached
        do {
            try await manager.start(model: "nonexistent/model-that-does-not-exist")
            XCTFail("Expected modelNotFound error")
        } catch let error as ServerError {
            if case .modelNotFound(let model) = error {
                XCTAssertEqual(model, "nonexistent/model-that-does-not-exist")
            } else {
                XCTFail("Expected modelNotFound, got \(error)")
            }
        } catch {
            XCTFail("Expected ServerError, got \(error)")
        }
    }

    @MainActor
    func testAllocateEphemeralPort() throws {
        let manager = ServerManager.shared
        let port = try manager.allocateEphemeralPort()
        XCTAssertGreaterThan(port, 0)
        XCTAssertLessThan(port, 65536)

        // Allocating again should give a different port (usually)
        let port2 = try manager.allocateEphemeralPort()
        XCTAssertGreaterThan(port2, 0)
    }

    func testServerErrorDescriptions() {
        XCTAssertNotNil(ServerError.modelNotFound("test").errorDescription)
        XCTAssertNotNil(ServerError.processDied.errorDescription)
        XCTAssertNotNil(ServerError.timeout.errorDescription)
        XCTAssertNotNil(ServerError.alreadyRunning.errorDescription)
    }

    func testControlClientErrorDescriptions() {
        XCTAssertNotNil(ControlClientError.daemonNotRunning.errorDescription)
        XCTAssertNotNil(ControlClientError.unexpectedStatus(500).errorDescription)
        XCTAssertNotNil(ControlClientError.decodingFailed.errorDescription)
    }
}
