import ArgumentParser
import Foundation
import OllmlxCore

struct Ps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show currently running model"
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

        guard case .running(let model, let port) = status.state else {
            print("No models currently loaded.")
            return
        }

        // Ollama-style table
        let nameHeader = "NAME"
        let sizeHeader = "SIZE"
        let portHeader = "PORT"

        let nameWidth = max(nameHeader.count, model.count)

        let header = nameHeader.padding(toLength: nameWidth + 4, withPad: " ", startingAt: 0)
            + sizeHeader.padding(toLength: 12, withPad: " ", startingAt: 0)
            + portHeader
        print(header)

        // Get size from models list if available
        var sizeStr = "-"
        if let models = try? await client.models(),
           let found = models.first(where: { $0.repoID == model }) {
            let gb = Double(found.diskSize) / 1_073_741_824
            sizeStr = gb >= 1.0 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(found.diskSize) / 1_048_576)
        }

        let row = model.padding(toLength: nameWidth + 4, withPad: " ", startingAt: 0)
            + sizeStr.padding(toLength: 12, withPad: " ", startingAt: 0)
            + String(port)
        print(row)
    }
}
