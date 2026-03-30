import XCTest
@testable import OllmlxCore

final class OllmlxConfigTests: XCTestCase {
    func testDefaultValues() {
        let defaults = UserDefaults(suiteName: "com.ollmlx.test.\(UUID().uuidString)")!
        let config = OllmlxConfig(defaults: defaults)

        XCTAssertEqual(config.defaultModel, "mlx-community/Llama-3.2-3B-Instruct-4bit")
        XCTAssertEqual(config.publicPort, 11434)
        XCTAssertEqual(config.controlPort, 11435)
        XCTAssertEqual(config.maxTokens, 4096)
        XCTAssertFalse(config.launchAtLogin)
        XCTAssertFalse(config.autoResumeOnWake)
        XCTAssertFalse(config.allowExternalConnections)
        XCTAssertEqual(config.pythonPath, "")
        XCTAssertNil(config.lastActiveModel)
    }

    func testReadWrite() {
        let defaults = UserDefaults(suiteName: "com.ollmlx.test.\(UUID().uuidString)")!
        let config = OllmlxConfig(defaults: defaults)

        config.pythonPath = "/usr/bin/python3"
        XCTAssertEqual(config.pythonPath, "/usr/bin/python3")

        config.maxTokens = 8192
        XCTAssertEqual(config.maxTokens, 8192)

        config.lastActiveModel = "some-model"
        XCTAssertEqual(config.lastActiveModel, "some-model")

        config.lastActiveModel = nil
        XCTAssertNil(config.lastActiveModel)
    }
}
