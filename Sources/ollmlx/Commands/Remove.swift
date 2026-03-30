import ArgumentParser
import Foundation
import OllmlxCore

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove a model from the local cache"
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

        // Confirmation prompt — defaults to No on empty input
        print("Are you sure you want to remove \(found.repoID)? [y/N] ", terminator: "")
        fflush(stdout)

        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(),
              answer == "y" || answer == "yes" else {
            print("Cancelled.")
            return
        }

        // Remove the HF cache directory
        let hfCacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        let repoDir = hfCacheDir.appendingPathComponent(
            "models--\(found.repoID.replacingOccurrences(of: "/", with: "--"))"
        )

        do {
            try FileManager.default.removeItem(at: repoDir)
            print("Removed \(found.repoID)")
        } catch {
            printError("Error removing model: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}
