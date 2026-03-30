import Foundation
import OSLog

public final class OllmlxLogger: @unchecked Sendable {
    public static let shared = OllmlxLogger()

    private let osLog = OSLog(subsystem: "com.ollmlx", category: "daemon")
    private let config = OllmlxConfig.shared
    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.ollmlx.logger")
    private static let maxLogSize: UInt64 = 50 * 1024 * 1024 // 50 MB

    private init() {
        setupLogFile()
    }

    private func setupLogFile() {
        let fm = FileManager.default
        let logDir = config.logDirectory
        let logPath = config.logFilePath

        // Create log directory
        try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        // Rotate if needed
        if fm.fileExists(atPath: logPath),
           let attrs = try? fm.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? UInt64,
           size > Self.maxLogSize {
            let previousPath = config.previousLogFilePath
            try? fm.removeItem(atPath: previousPath)
            try? fm.moveItem(atPath: logPath, toPath: previousPath)
        }

        // Create log file if it doesn't exist
        if !fm.fileExists(atPath: logPath) {
            fm.createFile(atPath: logPath, contents: nil)
        }

        fileHandle = FileHandle(forWritingAtPath: logPath)
        fileHandle?.seekToEndOfFile()
    }

    // MARK: - Public API

    public func info(_ message: String) {
        os_log(.info, log: osLog, "%{public}@", message)
        writeToFile("INFO", message)
    }

    public func error(_ message: String) {
        os_log(.error, log: osLog, "%{public}@", message)
        writeToFile("ERROR", message)
    }

    public func debug(_ message: String) {
        os_log(.debug, log: osLog, "%{public}@", message)
        writeToFile("DEBUG", message)
    }

    /// Write raw process output (stdout/stderr from mlx_lm.server) to the log file
    public func writeProcessOutput(_ data: Data) {
        queue.async { [weak self] in
            self?.fileHandle?.write(data)
        }
    }

    /// Returns a FileHandle suitable for piping process stdout/stderr to the log
    public var logFileHandle: FileHandle? {
        fileHandle
    }

    // MARK: - Private

    private func writeToFile(_ level: String, _ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async { [weak self] in
            self?.fileHandle?.write(data)
        }
    }
}
