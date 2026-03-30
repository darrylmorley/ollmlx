import AppKit
import ServiceManagement
import SwiftUI
import OllmlxCore

struct SettingsView: View {
    @EnvironmentObject var serverManager: ServerManager
    var onDismiss: (() -> Void)?

    // Local state bound to OllmlxConfig — persists immediately on change
    @State private var publicPort: String = ""
    @State private var controlPort: String = ""
    @State private var maxTokens: String = ""
    @State private var pythonPath: String = ""
    @State private var defaultModel: String = ""
    @State private var launchAtLogin: Bool = false
    @State private var autoResumeOnWake: Bool = false
    @State private var apiKeyText: String = ""
    @State private var allowExternalConnections: Bool = false

    // UI state
    @State private var showRestartWarning = false
    @State private var isDetectingPython = false
    @State private var detectError: String?
    @State private var mlxLMVersion: String?
    @State private var isUpdatingMLX = false
    @State private var ollamaShimEnabled = false
    @State private var ollamaShimWarning: String?
    @State private var apiKeySaveError: String?
    @State private var showAPIKey = false
    @State private var hfTokenText: String = ""
    @State private var showHFToken = false
    @State private var hfTokenSaveError: String?

    private let config = OllmlxConfig.shared
    private let ollamaShimPath = "/usr/local/bin/ollama"

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    serverSection
                    Divider()
                    modelSection
                    Divider()
                    pythonSection
                    Divider()
                    securitySection
                    Divider()
                    downloadsSection
                    Divider()
                    behaviourSection
                    Divider()
                    shimSection
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    onDismiss?()
                }
                .keyboardShortcut(.defaultAction)
                .padding(12)
            }
        }
        .frame(width: 480, height: 600)
        .onAppear(perform: loadSettings)
    }

    // MARK: - Server Section

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server")
                .font(.headline)

            HStack {
                Text("Public port")
                    .frame(width: 140, alignment: .leading)
                TextField("11434", text: $publicPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onChange(of: publicPort) { _, newValue in
                        if let port = Int(newValue), port > 0, port <= 65535 {
                            config.publicPort = port
                            showRestartWarning = true
                        }
                    }
            }

            HStack {
                Text("Control port")
                    .frame(width: 140, alignment: .leading)
                TextField("11435", text: $controlPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onChange(of: controlPort) { _, newValue in
                        if let port = Int(newValue), port > 0, port <= 65535 {
                            config.controlPort = port
                            showRestartWarning = true
                        }
                    }
            }

            HStack {
                Text("Max tokens")
                    .frame(width: 140, alignment: .leading)
                TextField("4096", text: $maxTokens)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onChange(of: maxTokens) { _, newValue in
                        if let tokens = Int(newValue), tokens > 0 {
                            config.maxTokens = tokens
                        }
                    }
            }

            if showRestartWarning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Port change requires a daemon restart to take effect.")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Button("Restart Now") {
                        restartDaemon()
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Model Section

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model")
                .font(.headline)

            HStack {
                Text("Default model")
                    .frame(width: 140, alignment: .leading)
                TextField("mlx-community/Llama-3.2-3B-Instruct-4bit", text: $defaultModel)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: defaultModel) { _, newValue in
                        config.defaultModel = newValue
                    }
            }
        }
    }

    // MARK: - Python Section

    private var pythonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Python / mlx-lm")
                .font(.headline)

            HStack {
                Text("Python path")
                    .frame(width: 140, alignment: .leading)
                TextField("~/.ollmlx/venv/bin/python", text: $pythonPath)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: pythonPath) { _, newValue in
                        config.pythonPath = newValue
                    }

                Button(action: detectPython) {
                    if isDetectingPython {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Detect")
                    }
                }
                .disabled(isDetectingPython)
            }

            if let error = detectError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Text("mlx-lm version")
                    .frame(width: 140, alignment: .leading)
                Text(mlxLMVersion ?? "Unknown")
                    .foregroundColor(.secondary)

                Button(action: updateMLXLM) {
                    if isUpdatingMLX {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Update")
                    }
                }
                .disabled(isUpdatingMLX || pythonPath.isEmpty)
            }
        }
    }

    // MARK: - Security Section

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Security")
                .font(.headline)

            HStack {
                Text("API key")
                    .frame(width: 140, alignment: .leading)
                if showAPIKey {
                    TextField("Optional — required for external access", text: $apiKeyText)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("Optional — required for external access", text: $apiKeyText)
                        .textFieldStyle(.roundedBorder)
                }
                Button(action: { showAPIKey.toggle() }) {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(showAPIKey ? "Hide API key" : "Show API key")
                Button("Save") {
                    saveAPIKey()
                }
                Button("Clear") {
                    clearAPIKey()
                }
            }

            if let error = apiKeySaveError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack(alignment: .top) {
                Toggle("Allow external connections", isOn: $allowExternalConnections)
                    .disabled(apiKeyIsEmpty)
                    .onChange(of: allowExternalConnections) { _, newValue in
                        if newValue && apiKeyIsEmpty {
                            allowExternalConnections = false
                            return
                        }
                        config.allowExternalConnections = newValue
                        showRestartWarning = true
                    }
            }

            if apiKeyIsEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("An API key must be set before external connections can be enabled. Without a key, anyone on your network could access the model.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 20)
            }
        }
    }

    // MARK: - Downloads Section

    private var downloadsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloads")
                .font(.headline)

            HStack {
                Text("HuggingFace token")
                    .frame(width: 140, alignment: .leading)
                if showHFToken {
                    TextField("Optional — enables faster downloads", text: $hfTokenText)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("Optional — enables faster downloads", text: $hfTokenText)
                        .textFieldStyle(.roundedBorder)
                }
                Button(action: { showHFToken.toggle() }) {
                    Image(systemName: showHFToken ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(showHFToken ? "Hide token" : "Show token")
                Button("Save") {
                    saveHFToken()
                }
                Button("Clear") {
                    clearHFToken()
                }
            }

            if let error = hfTokenSaveError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Text("Get a free token at huggingface.co/settings/tokens")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 140)
        }
    }

    // MARK: - Behaviour Section

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Behaviour")
                .font(.headline)

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    config.launchAtLogin = newValue
                    updateLoginItem(enabled: newValue)
                }

            Text("Requires the app to be in /Applications for login items to work.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 20)

            Toggle("Auto-resume model on wake", isOn: $autoResumeOnWake)
                .onChange(of: autoResumeOnWake) { _, newValue in
                    config.autoResumeOnWake = newValue
                }
        }
    }

    // MARK: - Ollama Shim Section

    private var shimSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compatibility")
                .font(.headline)

            Toggle("Install Ollama shim at /usr/local/bin/ollama", isOn: $ollamaShimEnabled)
                .onChange(of: ollamaShimEnabled) { _, newValue in
                    toggleOllamaShim(enable: newValue)
                }

            if let warning = ollamaShimWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(warning)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(.leading, 20)
            }

            Text("Creates a symlink so tools expecting the 'ollama' CLI will use ollmlx instead.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 20)
        }
    }

    // MARK: - Helpers

    private var apiKeyIsEmpty: Bool {
        config.apiKey == nil || config.apiKey?.isEmpty == true
    }

    private func loadSettings() {
        publicPort = String(config.publicPort)
        controlPort = String(config.controlPort)
        maxTokens = String(config.maxTokens)
        pythonPath = config.pythonPath
        defaultModel = config.defaultModel
        launchAtLogin = config.launchAtLogin
        autoResumeOnWake = config.autoResumeOnWake
        allowExternalConnections = config.allowExternalConnections

        // Show masked indicator if key exists, empty otherwise
        if let key = config.apiKey, !key.isEmpty {
            apiKeyText = key
        }

        // Load HF token
        if let token = Keychain.getHFToken(), !token.isEmpty {
            hfTokenText = token
        }

        // Check Ollama shim state
        checkOllamaShim()

        // Detect mlx-lm version
        detectMLXVersion()
    }

    private func saveAPIKey() {
        apiKeySaveError = nil
        let key = apiKeyText.trimmingCharacters(in: .whitespaces)
        do {
            try config.setAPIKey(key.isEmpty ? nil : key)
            if key.isEmpty && allowExternalConnections {
                allowExternalConnections = false
                config.allowExternalConnections = false
            }
        } catch {
            apiKeySaveError = "Failed to save API key: \(error.localizedDescription)"
        }
    }

    private func clearAPIKey() {
        apiKeySaveError = nil
        do {
            try config.setAPIKey(nil)
            apiKeyText = ""
            if allowExternalConnections {
                allowExternalConnections = false
                config.allowExternalConnections = false
            }
        } catch {
            apiKeySaveError = "Failed to clear API key: \(error.localizedDescription)"
        }
    }

    private func saveHFToken() {
        hfTokenSaveError = nil
        let token = hfTokenText.trimmingCharacters(in: .whitespaces)
        do {
            try Keychain.setHFToken(token.isEmpty ? nil : token)
        } catch {
            hfTokenSaveError = "Failed to save token: \(error.localizedDescription)"
        }
    }

    private func clearHFToken() {
        hfTokenSaveError = nil
        do {
            try Keychain.setHFToken(nil)
            hfTokenText = ""
        } catch {
            hfTokenSaveError = "Failed to clear token: \(error.localizedDescription)"
        }
    }

    private func detectPython() {
        isDetectingPython = true
        detectError = nil

        Task {
            let scriptPath = Bundle.main.path(forResource: "install_mlx_lm", ofType: "sh")
                ?? "\(config.venvPath)/../Scripts/install_mlx_lm.sh"

            // First check if venv python already exists and works
            let venvPython = "\(config.venvPath)/bin/python"
            let fm = FileManager.default

            if fm.fileExists(atPath: venvPython) {
                // Validate it works
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: venvPython)
                proc.arguments = ["--version"]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()

                do {
                    try proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 {
                        await MainActor.run {
                            pythonPath = venvPython
                            config.pythonPath = venvPython
                            isDetectingPython = false
                        }
                        return
                    }
                } catch {
                    // Fall through to script
                }
            }

            // Run install script if it exists
            if fm.fileExists(atPath: scriptPath) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/bash")
                proc.arguments = [scriptPath]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()

                do {
                    try proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0, fm.fileExists(atPath: venvPython) {
                        await MainActor.run {
                            pythonPath = venvPython
                            config.pythonPath = venvPython
                            isDetectingPython = false
                        }
                        return
                    }
                } catch {
                    // Fall through
                }
            }

            await MainActor.run {
                detectError = "Could not detect or install Python venv. Run Scripts/install_mlx_lm.sh manually."
                isDetectingPython = false
            }
        }
    }

    private func detectMLXVersion() {
        let venvPython = "\(config.venvPath)/bin/python"
        guard FileManager.default.fileExists(atPath: venvPython) else {
            mlxLMVersion = "Not installed"
            return
        }

        // Resolve uv path — macOS apps don't inherit the user's shell PATH,
        // so /usr/bin/env won't find ~/.local/bin/uv
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let uvCandidates = [
            "\(home)/.local/bin/uv",
            "/usr/local/bin/uv",
            "/opt/homebrew/bin/uv",
        ]
        guard let uvPath = uvCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            mlxLMVersion = "uv not found"
            return
        }

        Task {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: uvPath)
            proc.arguments = ["pip", "show", "mlx-lm", "--python", venvPython]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()

            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let version = output.split(separator: "\n")
                        .first { $0.hasPrefix("Version:") }
                        .map { String($0.dropFirst("Version:".count)).trimmingCharacters(in: .whitespaces) }
                    await MainActor.run {
                        mlxLMVersion = version ?? "Unknown"
                    }
                }
            } catch {
                await MainActor.run {
                    mlxLMVersion = "Error detecting"
                }
            }
        }
    }

    private func updateMLXLM() {
        isUpdatingMLX = true
        let pipPath = "\(config.venvPath)/bin/pip"

        Task {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pipPath)
            proc.arguments = ["install", "--upgrade", "mlx-lm"]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()

            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                // Ignore — version will show current state
            }

            detectMLXVersion()

            await MainActor.run {
                isUpdatingMLX = false
            }
        }
    }

    private func updateLoginItem(enabled: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enabled {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                // SMAppService may fail if app isn't in /Applications
                // Config is already updated — it will just not take effect until moved
            }
        }
    }

    private func checkOllamaShim() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: ollamaShimPath) else {
            ollamaShimEnabled = false
            ollamaShimWarning = nil
            return
        }

        // Check if it's a symlink pointing to ollmlx
        do {
            let destination = try fm.destinationOfSymbolicLink(atPath: ollamaShimPath)
            if destination.contains("ollmlx") {
                ollamaShimEnabled = true
                ollamaShimWarning = nil
            } else {
                // It's a symlink but not to ollmlx
                ollamaShimEnabled = false
                ollamaShimWarning = "A symlink exists at \(ollamaShimPath) pointing to \(destination). Remove it manually if you want to use the ollmlx shim."
            }
        } catch {
            // Not a symlink — real binary detected
            ollamaShimEnabled = false
            ollamaShimWarning = "A real Ollama binary is installed at \(ollamaShimPath). Enabling the shim would overwrite it. Remove the real binary first if you want to use ollmlx as an Ollama replacement."
        }
    }

    private func toggleOllamaShim(enable: Bool) {
        let fm = FileManager.default
        let ollmlxPath = "/usr/local/bin/ollmlx"

        if enable {
            // Check for existing real binary first
            if fm.fileExists(atPath: ollamaShimPath) {
                do {
                    _ = try fm.destinationOfSymbolicLink(atPath: ollamaShimPath)
                    // It's a symlink — safe to remove and replace
                    try fm.removeItem(atPath: ollamaShimPath)
                } catch {
                    // It's a real file — warn and revert
                    ollamaShimEnabled = false
                    ollamaShimWarning = "A real Ollama binary is installed at \(ollamaShimPath). Remove it manually before enabling the shim."
                    return
                }
            }

            do {
                try fm.createSymbolicLink(atPath: ollamaShimPath, withDestinationPath: ollmlxPath)
                ollamaShimWarning = nil
            } catch {
                ollamaShimEnabled = false
                ollamaShimWarning = "Failed to create symlink: \(error.localizedDescription). You may need to run with elevated permissions."
            }
        } else {
            // Remove the symlink
            do {
                let dest = try fm.destinationOfSymbolicLink(atPath: ollamaShimPath)
                if dest.contains("ollmlx") {
                    try fm.removeItem(atPath: ollamaShimPath)
                    ollamaShimWarning = nil
                }
            } catch {
                ollamaShimWarning = "Failed to remove symlink: \(error.localizedDescription)"
            }
        }
    }

    private func restartDaemon() {
        showRestartWarning = false
        Task { @MainActor in
            let wasRunning: String?
            if case .running(let model, _) = serverManager.state {
                wasRunning = model
            } else {
                wasRunning = nil
            }

            await serverManager.stop()

            if let model = wasRunning {
                try? await serverManager.start(model: model)
            }
        }
    }
}
