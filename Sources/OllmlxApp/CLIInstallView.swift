import AppKit
import SwiftUI
import OllmlxCore

/// Prompt shown after bootstrap completes, offering to install the CLI symlink.
/// Uses AppleScript authorization (standard macOS admin dialog) for privileged symlink creation.
/// Does NOT use the deprecated AuthorizationExecuteWithPrivileges C API.
struct CLIInstallView: View {
    @Binding var isPresented: Bool

    @State private var status: InstallStatus = .prompting
    @State private var errorMessage: String?

    private static let declinedKey = "cliInstallDeclined"
    private let symlinkPath = "/usr/local/bin/ollmlx"

    enum InstallStatus {
        case prompting
        case installing
        case succeeded
        case failed
    }

    /// Check if the user has already declined or the symlink exists.
    static var shouldShow: Bool {
        if UserDefaults.standard.bool(forKey: declinedKey) { return false }
        // Already installed?
        let fm = FileManager.default
        if fm.fileExists(atPath: "/usr/local/bin/ollmlx") { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)

            Text("Install CLI")
                .font(.title2)
                .fontWeight(.semibold)

            switch status {
            case .prompting:
                Text("Would you like to install the ollmlx command-line tool?\n\nThis creates a symlink at /usr/local/bin/ollmlx so you can use 'ollmlx' from any terminal. Your admin password will be required.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Button("Not Now") {
                        UserDefaults.standard.set(true, forKey: Self.declinedKey)
                        isPresented = false
                    }

                    Button("Install") {
                        installCLI()
                    }
                    .keyboardShortcut(.defaultAction)
                }

            case .installing:
                ProgressView()
                Text("Installing...")
                    .foregroundColor(.secondary)

            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.green)
                Text("CLI installed at /usr/local/bin/ollmlx")
                    .font(.body)
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)

            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.red)

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 16) {
                    Button("Skip") {
                        UserDefaults.standard.set(true, forKey: Self.declinedKey)
                        isPresented = false
                    }
                    Button("Retry") {
                        installCLI()
                    }
                }
            }
        }
        .padding(30)
        .frame(width: 400)
        .interactiveDismissDisabled(status == .installing)
    }

    private func installCLI() {
        status = .installing
        errorMessage = nil

        Task {
            // The CLI binary is bundled at Contents/MacOS/ollmlx-cli
            let cliPath = Bundle.main.bundlePath + "/Contents/MacOS/ollmlx-cli"

            // Use AppleScript to create the symlink with admin privileges.
            // This shows the standard macOS admin password dialog.
            let script = """
            do shell script "mkdir -p /usr/local/bin && ln -sf '\(cliPath)' '\(symlinkPath)'" with administrator privileges
            """

            var error: NSDictionary?
            let appleScript = NSAppleScript(source: script)
            let result = appleScript?.executeAndReturnError(&error)

            await MainActor.run {
                if result != nil && error == nil {
                    status = .succeeded
                } else {
                    status = .failed
                    if let error = error {
                        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                        if code == -128 {
                            // User cancelled the auth dialog
                            errorMessage = "Authorization cancelled. You can install the CLI later from Settings."
                        } else {
                            let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                            errorMessage = msg
                        }
                    } else {
                        errorMessage = "Failed to create symlink"
                    }
                }
            }
        }
    }
}
