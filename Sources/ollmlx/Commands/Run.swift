import ArgumentParser
import Foundation
import OllmlxCore

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a model (start if needed) and optionally send a prompt"
    )

    @Argument(help: "Model name (e.g. mlx-community/Llama-3.2-3B-Instruct-4bit)")
    var model: String

    @Argument(help: "Optional prompt — if omitted, enters interactive REPL")
    var prompt: String?

    func run() async throws {
        let controlClient = ControlClient()
        let config = OllmlxConfig.shared
        let apiClient = APIClient(apiKey: config.apiKey)

        // Check daemon status and start model if needed
        let status: StatusResponse
        do {
            status = try await controlClient.status()
        } catch is ControlClientError {
            printError("Error: daemon is not running. Start it with 'ollmlx serve'")
            throw ExitCode.failure
        }

        // Start model if not already running
        switch status.state {
        case .running(let runningModel, _):
            if runningModel != model {
                print("Stopping \(runningModel)...")
                try await controlClient.stop()
                print("Starting \(model)...")
                _ = try await controlClient.start(model: model)
            }
        case .stopped:
            print("Starting \(model)...")
            _ = try await controlClient.start(model: model)
        case .starting:
            print("Model is starting, please wait...")
            // Poll until running
            try await waitForRunning(controlClient: controlClient)
        default:
            printError("Error: server is in unexpected state: \(status.state)")
            throw ExitCode.failure
        }

        if let prompt {
            // Single prompt mode — try streaming first, fall back to non-streaming
            do {
                let stream = apiClient.stream(model: model, prompt: prompt)
                for try await token in stream {
                    print(token, terminator: "")
                    fflush(stdout)
                }
                print()
            } catch {
                // Streaming failed (e.g. response parse error) — fall back to non-streaming
                let messages = [["role": "user", "content": prompt]]
                let response = try await apiClient.chat(model: model, messages: messages)
                print(response)
            }
        } else {
            // REPL mode
            let repl = REPL(model: model, client: apiClient)
            try await repl.run()
        }
    }

    private func waitForRunning(controlClient: ControlClient) async throws {
        for _ in 0..<240 { // 120 seconds at 0.5s intervals
            let s = try await controlClient.status()
            if case .running = s.state { return }
            if case .error(let msg) = s.state {
                printError("Error: \(msg)")
                throw ExitCode.failure
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        printError("Error: timed out waiting for model to start")
        throw ExitCode.failure
    }
}
