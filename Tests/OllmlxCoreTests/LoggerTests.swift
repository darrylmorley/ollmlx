import XCTest
@testable import OllmlxCore

final class LoggerTests: XCTestCase {
    func testLoggerCreatesLogDirectory() {
        let logger = OllmlxLogger.shared
        // Writing should not crash
        logger.info("Test log message")
        logger.error("Test error message")
        logger.debug("Test debug message")

        // Verify log directory exists
        let config = OllmlxConfig.shared
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.logDirectory, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testLoggerWritesProcessOutput() {
        let logger = OllmlxLogger.shared
        let data = "Test process output\n".data(using: .utf8)!
        logger.writeProcessOutput(data)
        // Verify no crash — the actual content is written asynchronously
    }
}
