import AppKit
import Combine
import Sparkle
import SwiftUI
import OllmlxCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var bootstrapWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var pullModelWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    let updaterController: SPUStandardUpdaterController

    override init() {
        // Initialize Sparkle updater with automatic checking enabled
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent multiple instances — if another is already running, activate it and terminate self
        let bundleID = Bundle.main.bundleIdentifier!
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1, let existing = running.first(where: { $0 != .current }) {
            existing.activate()
            NSApplication.shared.terminate(nil)
            return
        }

        // Create the status bar item with brain SF Symbol
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "brain", accessibilityDescription: "ollmlx")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create the popover with MenuBarView
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 380)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(updater: updaterController.updater)
                .environmentObject(ServerManager.shared)
        )

        // Register sleep/wake notifications
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self,
            selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Update status item icon based on server state
        ServerManager.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateStatusIcon(state)
            }
            .store(in: &cancellables)

        // Listen for settings window requests from MenuBarView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettingsWindow),
            name: .openSettings,
            object: nil
        )

        // Listen for pull model window requests from MenuBarView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openPullModelWindow),
            name: .openPullModel,
            object: nil
        )

        // Check if bootstrap is needed (first launch or broken venv)
        checkBootstrap()

        // Auto-start daemon and proxy servers
        startDaemon()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Ensure popover window becomes key so it receives focus
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func handleSleep() {
        Task { @MainActor in
            await ServerManager.shared.stop()
        }
    }

    @objc private func handleWake() {
        let config = OllmlxConfig.shared
        guard config.autoResumeOnWake,
              let lastModel = config.lastActiveModel,
              !lastModel.isEmpty else { return }

        Task { @MainActor in
            try? await ServerManager.shared.start(model: lastModel)
        }
    }

    // MARK: - Daemon Auto-Start

    private func startDaemon() {
        Task { @MainActor in
            let daemon = DaemonServer()
            let daemonApp = daemon.buildApplication()
            Task.detached {
                try await daemonApp.run()
            }

            let proxy = ProxyServer.shared
            let proxyApp = proxy.buildApplication()
            Task.detached {
                try await proxyApp.run()
            }

            OllmlxLogger.shared.info("DaemonServer and ProxyServer started automatically")
        }
    }

    // MARK: - Settings Window

    @MainActor @objc private func openSettingsWindow() {
        // Close the popover first so it doesn't block
        popover.performClose(nil)

        // If settings window already open, just bring it to front
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(onDismiss: { [weak self] in
            self?.settingsWindow?.close()
            self?.settingsWindow = nil
        })
        .environmentObject(ServerManager.shared)

        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "ollmlx Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    // MARK: - Pull Model Window

    @MainActor @objc private func openPullModelWindow() {
        // Close the popover first
        popover.performClose(nil)

        // If pull window already open, just bring it to front
        if let existing = pullModelWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let view = ModelListView(onComplete: {})
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Pull Model"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 200))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        pullModelWindow = window
    }

    // MARK: - Bootstrap

    private func checkBootstrap() {
        let config = OllmlxConfig.shared
        let fm = FileManager.default

        // If configured path points to a valid binary, we're good
        if !config.pythonPath.isEmpty, fm.fileExists(atPath: config.pythonPath) {
            checkCLIInstall()
            return
        }

        // Config is empty or stale — check if the default venv python exists on disk
        let defaultPython = "\(config.venvPath)/bin/python"
        if fm.fileExists(atPath: defaultPython) {
            // Venv exists but config wasn't set — fix it and skip bootstrap
            config.pythonPath = defaultPython
            checkCLIInstall()
            return
        }

        showBootstrapWindow()
    }

    private func showBootstrapWindow() {
        var showBootstrap = true
        let bootstrapBinding = Binding<Bool>(
            get: { showBootstrap },
            set: { newValue in
                showBootstrap = newValue
                if !newValue {
                    self.bootstrapWindow?.close()
                    self.bootstrapWindow = nil
                }
            }
        )

        let view = BootstrapView(isPresented: bootstrapBinding) { [weak self] in
            // Bootstrap succeeded — now offer CLI install
            self?.checkCLIInstall()
        }

        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "ollmlx Setup"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 300))
        window.center()
        window.level = .floating // Ensure it appears above other windows in accessory mode
        window.makeKeyAndOrderFront(nil)
        // Bring the app to front for the setup window
        NSApplication.shared.activate(ignoringOtherApps: true)
        bootstrapWindow = window
    }

    private func checkCLIInstall() {
        guard CLIInstallView.shouldShow else { return }

        var showInstall = true
        let installBinding = Binding<Bool>(
            get: { showInstall },
            set: { newValue in
                showInstall = newValue
                if !newValue {
                    self.bootstrapWindow?.close()
                    self.bootstrapWindow = nil
                }
            }
        )

        let view = CLIInstallView(isPresented: installBinding)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Install CLI"
        window.styleMask = [.titled, .closable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        bootstrapWindow = window
    }

    // MARK: - Status Icon

    private func updateStatusIcon(_ state: ServerState) {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        let color: NSColor?

        switch state {
        case .running:
            symbolName = "brain.fill"
            color = .systemGreen
        case .starting, .downloading:
            symbolName = "brain"
            color = .systemOrange
        case .stopping:
            symbolName = "brain"
            color = .systemOrange
        case .error:
            symbolName = "brain"
            color = .systemRed
        case .stopped:
            symbolName = "brain"
            color = nil
        }

        // Use withSymbolConfiguration for reliable menubar tinting
        if let color,
           let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ollmlx"),
           let tinted = baseImage.withSymbolConfiguration(.init(paletteColors: [color])) {
            tinted.isTemplate = false // Disable template mode so the color renders
            button.image = tinted
        } else {
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ollmlx")
            image?.isTemplate = true
            button.image = image
        }
    }
}
