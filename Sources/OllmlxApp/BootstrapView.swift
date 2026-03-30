import AppKit
import SwiftUI
import OllmlxCore

/// Modal sheet shown on first launch when Python venv needs to be set up.
/// Runs install_mlx_lm.sh from the app bundle and captures the python path.
struct BootstrapView: View {
    @Binding var isPresented: Bool
    var onComplete: () -> Void

    @State private var status: BootstrapStatus = .running
    @State private var statusMessage = "Setting up Python environment..."
    @State private var errorOutput = ""
    @State private var bootstrapTask: Task<Void, Never>?

    enum BootstrapStatus {
        case running
        case succeeded
        case failed
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)

            Text("Setting up ollmlx")
                .font(.title2)
                .fontWeight(.semibold)

            switch status {
            case .running:
                ProgressView()
                    .controlSize(.regular)
                Text(statusMessage)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.green)
                Text("Bootstrap complete!")
                    .font(.body)

            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.red)
                Text("Bootstrap failed")
                    .font(.body)
                    .foregroundColor(.red)

                if !errorOutput.isEmpty {
                    ScrollView {
                        Text(errorOutput)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 150)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                }

                Button("Retry") {
                    runBootstrap()
                }
            }

            if status == .succeeded {
                Button("Continue") {
                    isPresented = false
                    onComplete()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 420)
        .onAppear {
            runBootstrap()
        }
        .interactiveDismissDisabled(status == .running)
    }

    private func runBootstrap() {
        status = .running
        statusMessage = "Setting up Python environment..."
        errorOutput = ""

        bootstrapTask = Task {
            do {
                let pythonPath = try await executeBootstrapScript()
                await MainActor.run {
                    // Verify the path actually exists
                    if FileManager.default.fileExists(atPath: pythonPath) {
                        OllmlxConfig.shared.pythonPath = pythonPath
                        status = .succeeded
                        statusMessage = "Bootstrap complete!"
                    } else {
                        status = .failed
                        errorOutput = "Script completed but python not found at: \(pythonPath)"
                    }
                }
            } catch {
                await MainActor.run {
                    status = .failed
                    if errorOutput.isEmpty {
                        errorOutput = error.localizedDescription
                    }
                }
            }
        }
    }

    private func executeBootstrapScript() async throws -> String {
        // Find the script in the app bundle
        guard let scriptURL = Bundle.main.url(
            forResource: "install_mlx_lm",
            withExtension: "sh",
            subdirectory: "Scripts"
        ) else {
            throw BootstrapError.scriptNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Read stderr for progress updates
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                // Show the last meaningful line as status
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                if let last = lines.last {
                    statusMessage = String(last)
                }
                // Accumulate for error display
                errorOutput += text
            }
        }

        // Read stdout
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stderrHandle.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            throw BootstrapError.scriptFailed(exitCode: Int(process.terminationStatus))
        }

        // The last line of stdout is the python path
        guard let output = String(data: stdoutData, encoding: .utf8) else {
            throw BootstrapError.noPythonPath
        }

        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: true)

        guard let lastLine = lines.last else {
            throw BootstrapError.noPythonPath
        }

        return String(lastLine).trimmingCharacters(in: .whitespaces)
    }
}

enum BootstrapError: Error, LocalizedError {
    case scriptNotFound
    case scriptFailed(exitCode: Int)
    case noPythonPath

    var errorDescription: String? {
        switch self {
        case .scriptNotFound:
            return "Bootstrap script not found in app bundle"
        case .scriptFailed(let code):
            return "Bootstrap script exited with code \(code)"
        case .noPythonPath:
            return "Bootstrap script did not output a python path"
        }
    }
}
