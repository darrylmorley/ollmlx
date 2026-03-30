import ArgumentParser
import Foundation
import OllmlxCore

struct Pull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pull a model from Hugging Face"
    )

    @Argument(help: "Model name (e.g. mlx-community/Llama-3.2-3B-Instruct-4bit)")
    var model: String

    func run() async throws {
        let client = ControlClient()

        // Verify daemon is running
        do {
            _ = try await client.status()
        } catch is ControlClientError {
            printError("Error: daemon is not running. Start it with 'ollmlx serve'")
            throw ExitCode.failure
        }

        print("pulling \(model)...")

        let stream = client.pull(model: model)
        var lastDescription = ""

        do {
            for try await progress in stream {
                let percent = progress.fraction.map { Int($0 * 100) } ?? 0
                let downloaded = formatBytes(progress.bytesDownloaded)
                let total = progress.bytesTotal.map { formatBytes($0) } ?? "?"

                let line: String
                if !progress.description.isEmpty && progress.description != lastDescription {
                    lastDescription = progress.description
                    line = "\(progress.description): \(percent)% (\(downloaded)/\(total))"
                } else {
                    line = "\(percent)% (\(downloaded)/\(total))"
                }

                // \r overwrite — Ollama style
                print("\r\(line)", terminator: "")
                fflush(stdout)
            }
        } catch {
            print()
            printError("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        print("\rpull complete                                        ")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1.0 {
            return String(format: "%.0f MB", mb)
        }
        let kb = Double(bytes) / 1024
        return String(format: "%.0f KB", kb)
    }
}
