import ArgumentParser
import Foundation
import OllmlxCore

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List locally available models"
    )

    func run() async throws {
        let client = ControlClient()

        let models: [LocalModel]
        do {
            models = try await client.models()
        } catch is ControlClientError {
            printError("Error: daemon is not running. Start it with 'ollmlx serve'")
            throw ExitCode.failure
        }

        if models.isEmpty {
            print("No models found locally.")
            return
        }

        // Ollama-style table: NAME, SIZE, MODIFIED
        let nameHeader = "NAME"
        let sizeHeader = "SIZE"
        let modifiedHeader = "MODIFIED"

        // Calculate column widths
        let nameWidth = max(nameHeader.count, models.map { $0.repoID.count }.max() ?? 0)
        let sizeWidth = max(sizeHeader.count, models.map { formatSize($0.diskSize).count }.max() ?? 0)

        let header = nameHeader.padding(toLength: nameWidth + 4, withPad: " ", startingAt: 0)
            + sizeHeader.padding(toLength: sizeWidth + 4, withPad: " ", startingAt: 0)
            + modifiedHeader
        print(header)

        let dateFormatter = RelativeDateTimeFormatter()
        dateFormatter.unitsStyle = .full

        for model in models {
            let name = model.repoID.padding(toLength: nameWidth + 4, withPad: " ", startingAt: 0)
            let size = formatSize(model.diskSize).padding(toLength: sizeWidth + 4, withPad: " ", startingAt: 0)
            let modified = dateFormatter.localizedString(for: model.modifiedAt, relativeTo: Date())
            print("\(name)\(size)\(modified)")
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}
