import Sparkle
import SwiftUI
import OllmlxCore

extension Notification.Name {
    static let openSettings = Notification.Name("com.ollmlx.openSettings")
    static let openPullModel = Notification.Name("com.ollmlx.openPullModel")
}

struct MenuBarView: View {
    @EnvironmentObject var serverManager: ServerManager
    var updater: SPUUpdater?
    @State private var cachedModels: [LocalModel] = []
    // Pull model and settings opened via AppDelegate as standalone NSWindow (not a sheet — sheets on popovers deadlock)

    @State private var selectedModel: String = ""
    @State private var isSwitchingModel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status indicator + model name
            statusRow

            Divider()

            // Model selector
            modelSelector

            // Start / Stop button
            startStopButton

            Divider()

            // Pull model — opens as standalone NSWindow via AppDelegate
            Button("Pull Model...") {
                NotificationCenter.default.post(name: .openPullModel, object: nil)
            }

            Divider()

            // Port badge
            portBadge

            // Logs link
            Button("View Logs") {
                openLogs()
            }

            // Settings link — opens as standalone NSWindow via AppDelegate
            Button("Settings...") {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }

            // Check for Updates
            if let updater {
                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            Divider()

            Button("Quit ollmlx") {
                Task { @MainActor in
                    await serverManager.stop()
                }
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
        .task {
            refreshModels()
        }
        .onChange(of: serverManager.state) { newState in
            // Sync the dropdown selection when the running model changes
            // (e.g. triggered externally via /api/chat or CLI)
            if case .running(let model, _) = newState {
                if selectedModel != model {
                    selectedModel = model
                }
            }
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        HStack(spacing: 8) {
            statusIndicator
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                if let subtitle = statusSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        ZStack {
            switch serverManager.state {
            case .running:
                Circle()
                    .fill(Color.green)
                    .frame(width: 10, height: 10)
            case .starting, .downloading, .stopping:
                ProgressView()
                    .controlSize(.small)
            case .error:
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
            case .stopped:
                Circle()
                    .fill(Color.gray)
                    .frame(width: 10, height: 10)
            }

            // Spinner overlay during model switch
            if isSwitchingModel {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var statusTitle: String {
        switch serverManager.state {
        case .running(let model, _):
            return model
        case .starting(let model):
            return "Starting \(model)..."
        case .downloading(let model, let progress):
            return "Downloading \(model) (\(Int(progress * 100))%)"
        case .stopping:
            return "Stopping..."
        case .error(let msg):
            return "Error: \(msg)"
        case .stopped:
            return "Stopped"
        }
    }

    private var statusSubtitle: String? {
        switch serverManager.state {
        case .running(_, let port):
            return "Port \(port)"
        default:
            return nil
        }
    }

    // MARK: - Model Selector

    private var modelSelector: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model")
                .font(.caption)
                .foregroundColor(.secondary)

            if cachedModels.isEmpty {
                Text("No models cached — pull one first")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Picker("", selection: selectedModelBinding) {
                    ForEach(cachedModels) { model in
                        Text(model.repoID).tag(model.repoID)
                    }
                }
                .labelsHidden()
            }
        }
    }

    private var selectedModelBinding: Binding<String> {
        Binding<String>(
            get: {
                // Show the running model if active, otherwise the user's selection
                if case .running(let model, _) = serverManager.state {
                    return model
                }
                return selectedModel.isEmpty ? (cachedModels.first?.repoID ?? "") : selectedModel
            },
            set: { newModel in
                // Only update the selection — don't start/stop the server
                selectedModel = newModel
            }
        )
    }

    // MARK: - Start / Stop

    private var startStopButton: some View {
        Group {
            switch serverManager.state {
            case .running:
                Button("Stop") {
                    Task { @MainActor in
                        await serverManager.stop()
                    }
                }
            case .starting, .downloading, .stopping:
                Button("Stop") {
                    Task { @MainActor in
                        await serverManager.stop()
                    }
                }
                .disabled(serverManager.state == .stopping)
            case .stopped, .error:
                Button("Start") {
                    startSelectedModel()
                }
                .disabled(cachedModels.isEmpty)
            }
        }
    }

    // MARK: - Port Badge

    private var portBadge: some View {
        Button(action: {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("localhost:11434", forType: .string)
        }) {
            HStack {
                Image(systemName: "network")
                Text("localhost:11434")
                    .font(.caption)
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
            }
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
    }

    // MARK: - Actions

    private func refreshModels() {
        cachedModels = ModelStore.shared.refreshCached()
        // Initialize selection if not yet set
        if selectedModel.isEmpty, let first = cachedModels.first {
            selectedModel = first.repoID
        }
    }

    private func startSelectedModel() {
        let model = selectedModel.isEmpty ? (cachedModels.first?.repoID ?? "") : selectedModel
        guard !model.isEmpty else { return }

        // If already running this model, nothing to do
        if case .running(let current, _) = serverManager.state, current == model {
            return
        }

        isSwitchingModel = true
        Task { @MainActor in
            // Stop first if a different model is running
            if case .running = serverManager.state {
                await serverManager.stop()
            }
            try? await serverManager.start(model: model)
            isSwitchingModel = false
        }
    }

    private func openLogs() {
        let logPath = OllmlxConfig.shared.logFilePath
        let url = URL(fileURLWithPath: logPath)
        NSWorkspace.shared.open(url)
    }
}
