import ArgumentParser
import Foundation
import OllmlxCore

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show details about a local model"
    )

    @Argument(help: "Model name (e.g. mlx-community/Llama-3.2-3B-Instruct-4bit)")
    var model: String

    func run() async throws {
        let client = ControlClient()

        let models: [LocalModel]
        do {
            models = try await client.models()
        } catch is ControlClientError {
            printError("Error: daemon is not running. Start it with 'ollmlx serve'")
            throw ExitCode.failure
        }

        guard let found = models.first(where: { $0.repoID == model }) else {
            printError("Error: model '\(model)' not found in local cache")
            throw ExitCode.failure
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        print("  Model:         \(found.repoID)")
        print("  Size:          \(formatSize(found.diskSize))")
        print("  Modified:      \(dateFormatter.string(from: found.modifiedAt))")
        if let quant = found.quantisation {
            print("  Quantisation:  \(quant)")
        }
        if let ctx = found.contextLength {
            print("  Context:       \(ctx) tokens")
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
