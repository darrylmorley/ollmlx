import ArgumentParser
import Foundation
import OllmlxCore

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop the currently running model"
    )

    func run() async throws {
        let client = ControlClient()

        do {
            try await client.stop()
        } catch is ControlClientError {
            printError("Error: daemon is not running. Start it with 'ollmlx serve'")
            throw ExitCode.failure
        }

        print("Stopped.")
    }
}
