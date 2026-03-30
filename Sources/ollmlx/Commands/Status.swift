import ArgumentParser
import Foundation
import OllmlxCore

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show raw daemon status as JSON"
    )

    func run() async throws {
        let client = ControlClient()

        let status: StatusResponse
        do {
            status = try await client.status()
        } catch is ControlClientError {
            printError("Error: daemon is not running. Start it with 'ollmlx serve'")
            throw ExitCode.failure
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(status)
        guard let json = String(data: data, encoding: .utf8) else {
            printError("Error: failed to encode status")
            throw ExitCode.failure
        }

        print(json)
    }
}
