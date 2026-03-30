# MLX Runner

A native macOS menubar app and CLI built on top of `mlx-lm`, providing an Ollama-like experience for running local LLMs on Apple Silicon.

---

## Architecture overview

```
┌─────────────────┐   ┌──────────────────────┐   ┌──────────────────────┐
│  Menubar app    │   │        CLI           │   │  Third-party clients │
│ Swift / SwiftUI │   │ Swift ArgumentParser │   │  OpenAI-compatible   │
└────────┬────────┘   └──────────┬───────────┘   └──────────┬───────────┘
         │                       │                           │
         └───────────────────────┼───────────────────────────┘
                                 ▼
              ┌──────────────────────────────────────────┐
              │            MLX Runner daemon             │
              │  Swift · launchd service · Unix socket   │
              │  HTTP on localhost:8080 · UserDefaults   │
              └──────────────────────┬───────────────────┘
                                     │
                                     ▼
                     ┌───────────────────────────────┐
                     │       Process manager         │
                     │  Spawns / monitors            │
                     │  mlx_lm.server via            │
                     │  Swift Process API            │
                     └───────────────┬───────────────┘
                                     │
                                     ▼
                          ┌─────────────────────┐
                          │   mlx_lm.server     │
                          │  Python · OpenAI    │
                          │  API · port 8080    │
                          └──────────┬──────────┘
                                     │
                    ┌────────────────┴─────────────────┐
                    ▼                                  ▼
     ┌──────────────────────────┐     ┌──────────────────────────┐
     │  MLX framework           │     │  ~/.cache/huggingface/   │
     │  (Apple Silicon)         │     │  hub                     │
     └──────────────────────────┘     └──────────────────────────┘
```

---

## Repository structure

```
MLXRunner/
├── MLXRunner.xcodeproj
├── Sources/
│   ├── MLXRunnerApp/          # Menubar app target
│   │   ├── MLXRunnerApp.swift     # @main, NSStatusItem setup
│   │   ├── MenuBarView.swift      # SwiftUI menu contents
│   │   ├── ModelListView.swift    # Browse / pull models
│   │   ├── SettingsView.swift     # Port, startup, Python path
│   │   └── Assets.xcassets
│   ├── MLXRunnerCore/         # Shared framework
│   │   ├── ServerManager.swift    # Owns the Process + state machine
│   │   ├── ModelStore.swift       # HF model list, download progress
│   │   ├── MLXConfig.swift        # Persisted settings
│   │   └── APIClient.swift        # Thin HTTP wrapper for /v1/*
│   └── mlxr/                  # CLI target
│       ├── main.swift             # Entry point
│       └── Commands/
│           ├── Serve.swift
│           ├── Run.swift
│           ├── Pull.swift
│           ├── List.swift
│           └── Stop.swift
├── Scripts/
│   └── install_mlx_lm.sh      # Bootstraps uv + mlx-lm into a venv
└── README.md
```

---

## The daemon: `ServerManager.swift`

This is the core of the whole thing. It wraps a `Foundation.Process` running `mlx_lm.server` and owns a state machine.

```swift
// MLXRunnerCore/ServerManager.swift
import Foundation
import Combine

public enum ServerState: Equatable {
    case stopped
    case starting(model: String)
    case running(model: String, port: Int)
    case stopping
    case error(String)
}

public final class ServerManager: ObservableObject {
    @Published public private(set) var state: ServerState = .stopped

    private var process: Process?
    private var stdoutPipe = Pipe()
    private var stderrPipe = Pipe()
    private let config: MLXConfig

    public init(config: MLXConfig = .shared) {
        self.config = config
    }

    public func start(model: String, port: Int = 8080) async throws {
        guard case .stopped = state else { return }
        state = .starting(model: model)

        let pythonPath = config.pythonPath  // e.g. ~/.venv/mlx/bin/python
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            "-m", "mlx_lm.server",
            "--model", model,
            "--host", "127.0.0.1",
            "--port", String(port)
        ]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.state = .stopped
            }
        }

        try process.run()
        self.process = process

        // Poll until /v1/models responds
        try await waitForServer(port: port)
        state = .running(model: model, port: port)
    }

    public func stop() async {
        state = .stopping
        process?.interrupt()
        process?.waitUntilExit()
        process = nil
        state = .stopped
    }

    private func waitForServer(port: Int, timeout: TimeInterval = 30) async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let _ = try? await URLSession.shared.data(from: url) { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ServerError.timeout
    }
}
```

---

## Python bootstrap

Rather than assuming any system Python, bundle a small install script and detect the venv at startup. `MLXConfig` stores the resolved Python path in `UserDefaults`. On first launch, the app runs this script and saves the result.

```bash
# Scripts/install_mlx_lm.sh
#!/bin/bash
set -e
VENV="$HOME/.mlxrunner/venv"

if ! command -v uv &>/dev/null; then
    brew install uv
fi

uv venv "$VENV" --python 3.12
uv pip install mlx-lm --python "$VENV/bin/python"
echo "$VENV/bin/python"
```

The Python venv lives at `~/.mlxrunner/venv` so it is completely isolated from the user's system Python and survives app updates.

---

## Menubar app

```swift
// MLXRunnerApp/MLXRunnerApp.swift
import SwiftUI

@main
struct MLXRunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No window — menubar only
        Settings { SettingsView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // hides from Dock

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "brain", accessibilityDescription: "MLX Runner")
        statusItem?.button?.action = #selector(togglePopover)
        statusItem?.button?.target = self

        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(ServerManager.shared)
        )
        popover.behavior = .transient
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
```

The popover `MenuBarView` shows:

- **Status indicator** — green dot = running, spinner = starting, gray = stopped
- **Model selector** — dropdown of locally cached models
- **Start / Stop** button
- **Pull model...** sheet that accepts a `mlx-community/` HuggingFace repo ID
- **Port** badge — tap to copy
- **Settings** link

---

## CLI (`mlxr`)

```swift
// mlxr/main.swift
import ArgumentParser

@main
struct MLXR: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mlxr",
        abstract: "MLX Runner — run local LLMs on Apple Silicon",
        subcommands: [Serve.self, Run.self, Pull.self, List.self, Stop.self, Status.self]
    )
}
```

```swift
// mlxr/Commands/Serve.swift
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start the inference server")

    @Option(name: .shortAndLong, help: "HuggingFace model ID or local path")
    var model: String = "mlx-community/Llama-3.2-3B-Instruct-4bit"

    @Option(name: .shortAndLong, help: "Port number")
    var port: Int = 8080

    @Flag(help: "Keep server in foreground (don't daemonise)")
    var foreground: Bool = false

    mutating func run() async throws {
        let manager = ServerManager.shared
        try await manager.start(model: model, port: port)
        print("✓ Server running at http://127.0.0.1:\(port)/v1")
        if foreground {
            // Block until Ctrl-C
            try await Task.sleep(nanoseconds: .max)
        }
    }
}

// mlxr/Commands/Run.swift — one-shot generate
struct Run: AsyncParsableCommand {
    @Option(name: .shortAndLong) var model: String = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    @Argument var prompt: String

    mutating func run() async throws {
        let client = APIClient(baseURL: "http://127.0.0.1:8080")
        for try await token in client.stream(model: model, prompt: prompt) {
            print(token, terminator: "")
            fflush(stdout)
        }
        print()
    }
}
```

### CLI command reference

| Command | Description |
|---|---|
| `mlxr serve --model <id>` | Start `mlx_lm.server` (daemonised by default) |
| `mlxr run "prompt"` | One-shot generate against running server |
| `mlxr pull <id>` | Pre-download a model from HF via `huggingface-cli` |
| `mlxr list` | Show locally cached models with disk sizes |
| `mlxr stop` | Stop the running server |
| `mlxr status` | Print current server state, model, and port |

---

## `MLXConfig` — shared settings

```swift
// MLXRunnerCore/MLXConfig.swift
public final class MLXConfig: ObservableObject {
    public static let shared = MLXConfig()

    @AppStorage("pythonPath")
    public var pythonPath: String = ""

    @AppStorage("defaultModel")
    public var defaultModel: String = "mlx-community/Llama-3.2-3B-Instruct-4bit"

    @AppStorage("serverPort")
    public var serverPort: Int = 8080

    @AppStorage("launchAtLogin")
    public var launchAtLogin: Bool = false

    @AppStorage("maxTokens")
    public var maxTokens: Int = 4096
}
```

`launchAtLogin` uses `ServiceManagement.framework` (`SMAppService.mainApp`) on macOS 13+.

---

## Model discovery

`ModelStore` hits the HF API to list `mlx-community` repos and scans the local cache:

```swift
// MLXRunnerCore/ModelStore.swift
public final class ModelStore: ObservableObject {
    @Published public var cachedModels: [LocalModel] = []
    @Published public var featuredModels: [HFModel] = []

    // Scans ~/.cache/huggingface/hub for mlx-community--* directories
    public func refreshCached() { ... }

    // Hits https://huggingface.co/api/models?author=mlx-community&sort=downloads
    public func fetchFeatured() async throws { ... }

    // Shells out to: huggingface-cli download <id>
    public func pull(_ modelID: String) -> AsyncThrowingStream<PullProgress, Error> { ... }
}
```

---

## Packaging

- **App bundle** — `MLXRunner.app` in `/Applications`, codesigned with your Apple Developer ID
- **CLI** — `mlxr` symlinked into `/usr/local/bin` by the app on first launch (with permission prompt)
- **Distribution** — direct `.dmg` download initially; Mac App Store is problematic due to sandboxing restrictions on spawning arbitrary Python processes

---

## Key decisions and gotchas

**Python path detection** — don't assume `/usr/bin/python3`. The app must find or create its own venv. Bundling a minimal Python inside the `.app` is an option but adds ~80 MB; the uv-bootstrap approach is cleaner.

**Process supervision** — `NSWorkspace` sleep/wake notifications should pause and resume the server gracefully, since `mlx_lm.server` will stall when the GPU suspends.

**Security** — the MLX LM server only implements basic security checks. Bind to `127.0.0.1` only by default; expose `0.0.0.0` as an opt-in setting only.

**Model switching** — `mlx_lm.server` holds the model in memory and cannot hot-swap it. The `ServerManager` must stop the old process and start a new one when the model changes. Show a loading state in the menubar during the transition.

**Token limit** — the default token limit of `mlx-lm` is 512, which is too restrictive for most tasks. Expose `--max-tokens` as a settings field and default it to `4096`.
