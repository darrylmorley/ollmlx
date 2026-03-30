import AppKit
import SwiftUI
import OllmlxCore

/// Pull model window — accepts a HF repo ID, shows live progress bar, closes on completion.
/// Opened as a standalone NSWindow via AppDelegate (not a sheet — sheets on popovers deadlock).
/// Consumes the SSE stream from ControlClient.pull(), not ModelStore directly.
struct ModelListView: View {
    var onComplete: () -> Void

    @State private var modelID = ""
    @State private var isPulling = false
    @State private var progress: Double = 0
    @State private var progressDescription = ""
    @State private var errorMessage: String?
    @State private var pullTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            Text("Pull Model")
                .font(.headline)

            TextField("Hugging Face repo ID (e.g. mlx-community/Llama-3.2-3B-Instruct-4bit)", text: $modelID)
                .textFieldStyle(.roundedBorder)
                .disabled(isPulling)

            if !isPulling && Keychain.getHFToken() == nil {
                Text("Add a HuggingFace token in Settings for faster downloads")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if isPulling {
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)

                    Text(progressDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Button("Cancel") {
                    pullTask?.cancel()
                    closeWindow()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isPulling ? "Pulling..." : "Pull") {
                    startPull()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(modelID.trimmingCharacters(in: .whitespaces).isEmpty || isPulling)
            }
        }
        .padding(20)
        .frame(width: 400)
        .frame(minHeight: 160)
    }

    private func closeWindow() {
        NSApplication.shared.keyWindow?.close()
    }

    private func startPull() {
        let model = modelID.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return }

        isPulling = true
        errorMessage = nil
        progress = 0
        progressDescription = "Starting download..."

        let client = ControlClient()

        pullTask = Task { @MainActor in
            do {
                let stream = client.pull(model: model)
                for try await pullProgress in stream {
                    if let fraction = pullProgress.fraction {
                        progress = fraction
                    }
                    if !pullProgress.description.isEmpty {
                        progressDescription = pullProgress.description
                    }
                }

                progress = 1.0
                progressDescription = "Pull complete"
                onComplete()
                // Dismiss after a brief moment
                try? await Task.sleep(nanoseconds: 500_000_000)
                closeWindow()
            } catch is CancellationError {
                // User cancelled
            } catch {
                errorMessage = error.localizedDescription
                isPulling = false
            }
        }
    }
}
