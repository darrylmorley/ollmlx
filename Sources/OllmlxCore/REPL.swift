import Foundation

/// Interactive chat REPL used by `ollmlx run`.
/// Simple readLine() loop with streaming token output via APIClient.
public final class REPL: Sendable {
    private let model: String
    private let client: APIClient

    public init(model: String, client: APIClient) {
        self.model = model
        self.client = client
    }

    /// Run the interactive loop. Blocks until the user types /bye.
    public func run() async throws {
        var messages: [[String: String]] = []

        print(">>> \(model)")
        print("Type /bye to exit.\n")

        while true {
            print(">>> ", terminator: "")
            fflush(stdout)

            guard let line = readLine() else {
                // EOF (Ctrl+D)
                print()
                break
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "/bye" { break }

            messages.append(["role": "user", "content": trimmed])

            // Stream the response
            var responseText = ""
            let stream = client.streamChat(model: model, messages: messages)

            do {
                for try await token in stream {
                    print(token, terminator: "")
                    fflush(stdout)
                    responseText += token
                }
                print() // newline after response
            } catch {
                print("\nError: \(error.localizedDescription)")
                // Remove the failed user message
                messages.removeLast()
                continue
            }

            messages.append(["role": "assistant", "content": responseText])
        }
    }
}
