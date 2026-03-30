import ArgumentParser
import Foundation
import OllmlxCore

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the ollmlx daemon in the foreground"
    )

    func run() async throws {
        let config = OllmlxConfig.shared
        let logger = OllmlxLogger.shared

        print("Starting ollmlx daemon...")
        print("  Control API: http://127.0.0.1:\(config.controlPort)")
        print("  Public API:  http://127.0.0.1:\(config.publicPort)")
        print("Press Ctrl+C to stop.\n")

        // Start both servers concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Control API server on :11435
            group.addTask {
                let daemon = DaemonServer(config: config, logger: logger)
                let app = daemon.buildApplication()
                try await app.run()
            }

            // Proxy server on :11434
            group.addTask {
                let proxy = ProxyServer(config: config, logger: logger)
                let app = proxy.buildApplication()
                try await app.run()
            }

            try await group.next()
        }
    }
}
