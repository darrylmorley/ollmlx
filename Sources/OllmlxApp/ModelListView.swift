import SwiftUI
import OllmlxCore

/// Pull model sheet — accepts a HF repo ID, shows live progress bar, dismisses on completion.
/// Consumes the SSE stream from ControlClient.pull(), not ModelStore directly.
struct ModelListView: View {
    @Binding var isPresented: Bool
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
                    isPresented = false
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
                isPresented = false
            } catch is CancellationError {
                // User cancelled
            } catch {
                errorMessage = error.localizedDescription
                isPulling = false
            }
        }
    }
}
