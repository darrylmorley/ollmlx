# ollmlx — Technical Implementation Plan

> Generated from `ollmlx-spec.md`  
> Target: Apple Silicon macOS 13+, Swift 5.9+, Xcode 15+

---

## 1. Project Structure

Single Xcode project, multi-target Swift Package. No monorepo needed — all targets share one repository and one `Package.swift`.

```
ollmlx/
├── ollmlx.xcodeproj/
├── Package.swift                  # SPM targets: OllmlxCore, OllmlxApp, ollmlx (CLI)
├── Sources/
│   ├── OllmlxCore/                # Shared framework — no AppKit/SwiftUI imports
│   │   ├── ServerManager.swift        # Process lifecycle + state machine (@MainActor)
│   │   ├── DaemonServer.swift         # Control API HTTP server on :11435
│   │   ├── ProxyServer.swift          # Reverse proxy :11434 → mlx_lm.server ephemeral port
│   │   ├── ModelStore.swift           # HF cache scanning + pull progress streams
│   │   ├── OllmlxConfig.swift         # UserDefaults-backed settings (no @AppStorage)
│   │   ├── APIClient.swift            # Thin async HTTP wrapper for /v1/* on :11434
│   │   ├── ControlClient.swift        # HTTP client for :11435 control API (used by CLI)
│   │   ├── REPL.swift                 # Interactive chat loop (used by `ollmlx run`)
│   │   ├── Logger.swift               # OSLog + file sink, log rotation at 50 MB
│   │   └── Keychain.swift             # Keychain read/write for optional API key
│   ├── OllmlxApp/                 # Menubar app target (AppKit + SwiftUI)
│   │   ├── OllmlxApp.swift            # @main, NSStatusItem, sleep/wake observers
│   │   ├── AppDelegate.swift          # NSApplicationDelegate — popover + notifications
│   │   ├── MenuBarView.swift          # Status indicator, model selector, start/stop
│   │   ├── ModelListView.swift        # Pull model sheet with live SSE progress
│   │   ├── SettingsView.swift         # Port, Python path, maxTokens, API key, shim
│   │   └── Assets.xcassets/
│   └── ollmlx/                    # CLI target (no AppKit)
│       ├── main.swift                 # ArgumentParser root command
│       └── Commands/
│           ├── Serve.swift
│           ├── Run.swift
│           ├── Pull.swift
│           ├── List.swift
│           ├── Show.swift
│           ├── Remove.swift
│           ├── Stop.swift
│           ├── Ps.swift
│           └── Status.swift
├── Scripts/
│   └── install_mlx_lm.sh          # Bootstraps uv + mlx-lm + huggingface_hub[cli] venv
├── ollmlx.entitlements            # Hardened runtime entitlements (see §9)
└── README.md
```

**Key structural rules:**
- `OllmlxCore` must have **zero** AppKit/SwiftUI imports — it must compile for CLI (non-main-actor) contexts
- App and CLI targets import `OllmlxCore`; they never import each other
- `@AppStorage` is forbidden in `OllmlxCore` — use raw `UserDefaults` via `OllmlxConfig`

---

## 2. Tech Stack Decisions

| Layer | Choice | Reason |
|---|---|---|
| Language | Swift 5.9+ | Required for macOS system APIs, `@MainActor`, `AsyncThrowingStream` |
| Package manager | Swift Package Manager | Native, no CocoaPods/Carthage complexity |
| CLI framework | `apple/swift-argument-parser` | Structured async commands, Ollama command parity |
| HTTP server (control API) | `swift-server/swift-nio` via `hummingbird` or raw `NWListener` | Lightweight, no server-side Swift framework needed for 5 endpoints |
| HTTP proxy | Swift `URLSession` + `NWListener` | Forward :11434 to ephemeral port; no third-party dep needed |
| LLM inference | `mlx-lm` (Python, external process) | Apple MLX framework; not available as a Swift library |
| Python bootstrap | `uv` | Faster than pip, no Homebrew dependency, reproducible venv |
| Model downloads | `huggingface-cli` (from venv) | Official HF tooling; avoids reimplementing large file download resumption |
| Settings persistence | `UserDefaults` | Cross-context safe (CLI + App); no database needed |
| API key storage | macOS Keychain (`Security.framework`) | Never store secrets in UserDefaults |
| Update framework | Sparkle 2 | De-facto standard for direct-distribution macOS apps |
| Logging | `OSLog` + file sink (`FileHandle`) | System-level visibility + persistent log at `~/.ollmlx/logs/server.log` |
| Minimum OS | macOS 13 (Ventura) | Required for `SMAppService.mainApp` (launch at login) |

---

## 3. Data Models / Types

All types live in `OllmlxCore` and are `Codable` for JSON serialisation over the control API.

### 3.1 `ServerState`

```swift
public enum ServerState: Equatable, Codable {
    case stopped
    case downloading(model: String, progress: Double)  // 0.0–1.0, nil until size known
    case starting(model: String)
    case running(model: String, port: Int)
    case stopping
    case error(String)
}
```

### 3.2 `LocalModel`

```swift
public struct LocalModel: Identifiable, Codable {
    public var id: String { repoID }
    public let repoID: String          // e.g. "mlx-community/Llama-3.2-3B-Instruct-4bit"
    public let diskSize: Int64         // bytes
    public let modifiedAt: Date
    public let quantisation: String?   // "4bit", "8bit", nil
    public let contextLength: Int?
}
```

Source: scanned from `~/.cache/huggingface/hub/models--mlx-community--*`

### 3.3 `HFModel`

```swift
public struct HFModel: Identifiable, Codable {
    public let id: String              // repoID
    public let downloads: Int
    public let tags: [String]
    public let lastModified: Date?
}
```

Source: `GET https://huggingface.co/api/models?author=mlx-community&sort=downloads`

### 3.4 `PullProgress`

```swift
public struct PullProgress: Codable {
    public let modelID: String
    public let bytesDownloaded: Int64
    public let bytesTotal: Int64?      // nil until HF reports size
    public var fraction: Double?       // computed: bytesDownloaded / bytesTotal
    public var description: String     // human-readable e.g. "42.1% (1.2 GB)"
}
```

### 3.5 `StatusResponse` (control API wire type)

```swift
public struct StatusResponse: Codable {
    public let state: ServerState
    public let memoryUsage: String?    // e.g. "4.2 GB" — parsed from mlx_lm stderr
    public let publicPort: Int
    public let controlPort: Int
    public let pythonPath: String?
}
```

### 3.6 `OllmlxConfig` (UserDefaults keys)

| Key | Type | Default |
|---|---|---|
| `pythonPath` | String | `""` (triggers bootstrap on first launch) |
| `defaultModel` | String | `"mlx-community/Llama-3.2-3B-Instruct-4bit"` |
| `publicPort` | Int | `11434` |
| `controlPort` | Int | `11435` |
| `maxTokens` | Int | `4096` |
| `launchAtLogin` | Bool | `false` |
| `autoResumeOnWake` | Bool | `false` |
| `lastActiveModel` | String? | `nil` |
| `allowExternalConnections` | Bool | `false` |
| `apiKey` | — | **Keychain only — never UserDefaults** |

### 3.7 Error types

```swift
public enum ServerError: Error {
    case modelNotFound(String)
    case processDied
    case timeout
    case alreadyRunning
}

public enum ControlClientError: Error {
    case daemonNotRunning           // Connection refused on :11435
    case unexpectedStatus(Int)
    case decodingFailed
}
```

---

## 4. API Contract

### 4.1 Control API — `localhost:11435` (daemon → CLI/App)

All responses are `Content-Type: application/json`. Errors: `{ "error": "..." }` with appropriate HTTP status.

| Method | Path | Request body | Response | Notes |
|---|---|---|---|---|
| `GET` | `/control/status` | — | `StatusResponse` | Current daemon state |
| `POST` | `/control/start` | `{ "model": String, "port"?: Int }` | `StatusResponse` | Validates model cache first; 409 if already running |
| `POST` | `/control/stop` | — | `204 No Content` | SIGINT → SIGKILL after 5s |
| `GET` | `/control/models` | — | `[LocalModel]` | Scans HF cache on each call |
| `POST` | `/control/pull` | `{ "model": String }` | SSE stream of `PullProgress` | Each event: `data: <PullProgress JSON>\n\n`; final event `data: {"done":true}` |

### 4.2 Public API — `localhost:11434` (clients → proxy → mlx_lm.server)

Pure transparent proxy — the daemon forwards all requests to the ephemeral `mlx_lm.server` port. No additional processing. Implements the OpenAI-compatible surface provided by `mlx_lm.server`:

| Method | Path | Notes |
|---|---|---|
| `GET` | `/v1/models` | Lists loaded model |
| `POST` | `/v1/chat/completions` | Streaming or non-streaming chat |
| `POST` | `/v1/completions` | Text completion |

When no model is running or during model switch: proxy returns `503 Service Unavailable`.  
When `apiKey` is set: proxy injects `Authorization: Bearer` check before forwarding.

### 4.3 `ControlClient` — Swift API (CLI uses this)

```swift
// OllmlxCore/ControlClient.swift
public final class ControlClient {
    public init(baseURL: String)

    public func status() async throws -> StatusResponse
    public func start(model: String, port: Int? = nil) async throws -> StatusResponse
    public func stop() async throws
    public func models() async throws -> [LocalModel]
    public func pull(model: String) -> AsyncThrowingStream<PullProgress, Error>
}
```

### 4.4 `APIClient` — Swift API (CLI `run` command uses this)

```swift
// OllmlxCore/APIClient.swift
public final class APIClient {
    public init(baseURL: String, apiKey: String? = nil)

    public func stream(model: String, prompt: String) -> AsyncThrowingStream<String, Error>
    public func chat(model: String, messages: [[String: String]]) async throws -> String
}
```

---

## 5. Environment Variables

This project has no `.env` file — it is a macOS desktop app with no server deployment. Configuration is entirely via:

- `UserDefaults` (non-sensitive settings)
- macOS Keychain (API key)
- Xcode build settings / `xcconfig` files for build-time configuration

### Build-time `xcconfig` values (for CI/distribution)

Create `Config/Release.xcconfig` and `Config/Debug.xcconfig`:

```
// Config/Shared.xcconfig
PRODUCT_BUNDLE_IDENTIFIER = com.yourname.ollmlx
SPARKLE_FEED_URL = https://your-cdn.example.com/ollmlx/appcast.xml
MARKETING_VERSION = 0.1.0
CURRENT_PROJECT_VERSION = 1

// Config/Debug.xcconfig
#include "Shared.xcconfig"
CONTROL_PORT_DEFAULT = 11435
PUBLIC_PORT_DEFAULT = 11434
```

These are referenced in `Info.plist` and accessed at runtime via `Bundle.main.infoDictionary`.

### Runtime paths (not configurable — always derived)

```
~/.ollmlx/venv/bin/python       # stored in UserDefaults as pythonPath after bootstrap
~/.ollmlx/venv/bin/huggingface-cli
~/.ollmlx/logs/server.log
~/.cache/huggingface/hub/       # HF model cache (standard HF path, not configurable)
/usr/local/bin/ollmlx           # CLI symlink (created by app on first launch)
/usr/local/bin/ollama           # Optional shim symlink
```

---

## 6. Dependency List

### Swift Package Manager (`Package.swift`)

```swift
dependencies: [
    // CLI argument parsing
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),

    // Lightweight HTTP server for control API on :11435
    // Option A — NIO-based, full featured:
    .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
    // Option B — if preferring minimal deps, use raw Network.framework (NWListener) — no SPM dep needed

    // Sparkle auto-update (App target only)
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
],
targets: [
    .target(
        name: "OllmlxCore",
        dependencies: [
            .product(name: "Hummingbird", package: "hummingbird"),  // or omit if using NWListener
        ]
    ),
    .target(
        name: "ollmlx",
        dependencies: [
            "OllmlxCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),
    .target(
        name: "OllmlxApp",
        dependencies: [
            "OllmlxCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ]
    ),
]
```

### Python (installed into `~/.ollmlx/venv` by `install_mlx_lm.sh`)

```
mlx-lm                   # inference server (mlx_lm.server)
huggingface_hub[cli]     # huggingface-cli for model downloads
```

### System / toolchain

| Tool | Where from | Purpose |
|---|---|---|
| Xcode 15+ | Mac App Store | Build toolchain |
| `uv` | `astral.sh/uv/install.sh` | Python venv bootstrap (runtime, not build-time) |
| Apple Developer ID cert | Apple Developer Portal | Codesigning + notarisation |
| Sparkle EdDSA key | `generate_keys` tool (Sparkle) | Update signing |

---

## 7. Implementation Phases

### Phase 1 — Core foundation (no UI, no CLI)
**Goal:** `OllmlxCore` compiles; `ServerManager` can spawn and kill `mlx_lm.server`

Completion criteria:
- [ ] `Package.swift` defines all three targets with correct dependencies
- [ ] `OllmlxConfig` reads/writes all keys via `UserDefaults`; API key reads/writes Keychain
- [ ] `Logger` writes to `~/.ollmlx/logs/server.log` with rotation at 50 MB
- [ ] `ServerManager.start(model:)` spawns `mlx_lm.server`, pipes stdout/stderr to log, transitions state machine correctly
- [ ] `ServerManager.stop()` sends SIGINT, waits 5s, falls back to SIGKILL
- [ ] `waitForServer()` polls `/v1/models`, fast-fails on `process.isRunning == false`
- [ ] `allocateEphemeralPort()` binds to port 0 and returns the OS-assigned port
- [ ] All `ServerError` cases are thrown correctly
- [ ] Unit tests: state transitions, SIGKILL fallback, timeout, process-died fast-fail

---

### Phase 2 — Control API daemon
**Goal:** `DaemonServer` serves all five `/control/*` endpoints on `:11435`

Completion criteria:
- [ ] `GET /control/status` returns `StatusResponse` reflecting current `ServerManager.state`
- [ ] `POST /control/start` validates model cache, starts server, returns updated status; 409 if already running
- [ ] `POST /control/stop` stops server, returns 204
- [ ] `GET /control/models` scans HF cache, returns `[LocalModel]`
- [ ] `POST /control/pull` streams `PullProgress` as SSE; final event `{"done":true}`
- [ ] `ModelStore.pull()` invokes `$VENV/bin/huggingface-cli` and parses progress output into `PullProgress`
- [ ] All endpoints return `{ "error": "..." }` with correct HTTP status on failure
- [ ] `ModelStore.isModelCached()` and `refreshCached()` correctly scan `~/.cache/huggingface/hub`

---

### Phase 3 — Proxy server
**Goal:** `:11434` transparently forwards to `mlx_lm.server`'s ephemeral port

Completion criteria:
- [ ] `ProxyServer` listens on `127.0.0.1:11434` (or `0.0.0.0` if `allowExternalConnections`)
- [ ] `setUpstream(port:)` atomically switches the target port (no dropped requests)
- [ ] During model switch / no upstream: returns `503 Service Unavailable`
- [ ] Optional API key check: if `OllmlxConfig.apiKey` is set, validates `Authorization: Bearer` header before forwarding; returns `401` on mismatch
- [ ] Streaming responses (`text/event-stream`) are forwarded correctly without buffering

---

### Phase 4 — CLI
**Goal:** All nine commands work against a running daemon

Completion criteria:
- [ ] `ControlClient` implements all five control API methods with correct error handling
- [ ] `ollmlx serve` — starts daemon (foreground mode; launchd registration is Phase 7)
- [ ] `ollmlx run <model> [prompt]` — starts model if stopped, streams tokens or enters REPL
- [ ] `ollmlx pull <model>` — SSE progress with `\r` line-overwrite (Ollama style)
- [ ] `ollmlx list` — tabular output of `LocalModel` list (NAME, SIZE, MODIFIED)
- [ ] `ollmlx show <model>` — metadata from `LocalModel`
- [ ] `ollmlx rm <model>` — removes HF cache directory, confirms before delete
- [ ] `ollmlx stop` — calls `/control/stop`
- [ ] `ollmlx ps` — Ollama-style table from `StatusResponse`
- [ ] `ollmlx status` — raw `StatusResponse` as pretty-printed JSON
- [ ] `REPL` — readline-style interactive loop, `>>>` prompt, `/bye` to exit
- [ ] All commands print a clear error and exit non-zero if daemon not running

---

### Phase 5 — Menubar app
**Goal:** Full menubar UI backed by live `ServerManager` state

Completion criteria:
- [ ] `OllmlxApp.swift` — sets activation policy to `.accessory`, no Dock icon
- [ ] `AppDelegate` — `NSStatusItem` with brain SF Symbol, click toggles popover
- [ ] `MenuBarView` — all seven elements: status indicator, active model, model selector, start/stop, pull sheet, port badge, logs link, settings link
- [ ] Status indicator — green (running), spinner (starting/downloading), grey (stopped), red (error)
- [ ] Model selector — dropdown from `ModelStore.cachedModels`; switching triggers stop → start with spinner overlay
- [ ] Pull model sheet — accepts HF repo ID, shows live `PullProgress` bar, dismisses on completion
- [ ] Port badge — tapping copies `localhost:11434` to clipboard
- [ ] Logs link — opens `~/.ollmlx/logs/server.log` in Console.app
- [ ] Sleep/wake — `willSleepNotification` calls `stop()`; `didWakeNotification` restarts if `autoResumeOnWake`

---

### Phase 6 — Settings
**Goal:** All settings persist and take effect immediately

Completion criteria:
- [ ] `SettingsView` — all fields: public port, control port, max tokens, Python path, default model, launch at login, auto-resume on wake, API key (masked), allow external connections, Ollama shim toggle
- [ ] Port changes require daemon restart — UI warns and offers to restart
- [ ] `allowExternalConnections` enforces API key presence — UI blocks enabling without a key set
- [ ] `launchAtLogin` uses `SMAppService.mainApp` on macOS 13+
- [ ] API key read/write goes through Keychain helper, never UserDefaults
- [ ] Python path — "Detect" button reruns `install_mlx_lm.sh` if path is invalid

---

### Phase 7 — Bootstrap and CLI installation
**Goal:** First-launch experience is smooth; CLI is accessible from terminal

Completion criteria:
- [ ] On first launch (empty `pythonPath`), app runs `install_mlx_lm.sh`, captures echoed path, stores in UserDefaults
- [ ] Progress shown in a modal sheet during bootstrap; error displayed if it fails
- [ ] App offers to symlink CLI to `/usr/local/bin/ollmlx` (with permission prompt via `AuthorizationExecuteWithPrivileges` or an SMJobBless helper)
- [ ] Optional Ollama shim — Settings toggle creates/removes `/usr/local/bin/ollama → /usr/local/bin/ollmlx`; shows warning if real Ollama detected

---

### Phase 8 — Polish and distribution
**Goal:** App is signed, notarised, and distributed via DMG with auto-update

Completion criteria:
- [ ] All required entitlements set in `ollmlx.entitlements` (see §9)
- [ ] App is codesigned with Apple Developer ID (hardened runtime)
- [ ] App is notarised via `notarytool`
- [ ] Sparkle 2 integrated — `appcast.xml` hosted on CDN, EdDSA key in `Info.plist`
- [ ] `mlx-lm` version shown in Settings with "Update" button (`uv pip install --upgrade mlx-lm`)
- [ ] DMG created with `create-dmg` or Xcode archive export
- [ ] README covers: requirements, installation, first-run, Ollama migration, CLI reference

---

## 8. CLAUDE.md

```markdown
# ollmlx — Agent Instructions

## Project overview
macOS menubar app + CLI for running local LLMs via mlx-lm on Apple Silicon.
Three targets: OllmlxCore (shared, no UI), OllmlxApp (menubar), ollmlx (CLI).

## Build
- Open `ollmlx.xcodeproj` in Xcode 15+
- Build target: `OllmlxApp` for the menubar app, `ollmlx` for the CLI
- Run `Scripts/install_mlx_lm.sh` once before testing to create the Python venv

## Critical rules

### Threading
- `ServerManager` is `@MainActor` — all state mutations happen on the main actor
- `OllmlxConfig` uses raw `UserDefaults` (not `@AppStorage`) so it can be read from CLI contexts
- CLI commands run in async contexts — use `Task { @MainActor in }` when touching `ServerManager` indirectly
- Never access `ServerManager.shared` from `OllmlxCore` background threads without `await`

### Target boundaries
- `OllmlxCore` must have ZERO AppKit/SwiftUI imports — it must compile as a CLI dependency
- The CLI target (`ollmlx`) must have ZERO AppKit imports
- Shared types (models, errors, config) belong in `OllmlxCore`
- `@AppStorage` is BANNED in OllmlxCore — use `OllmlxConfig` instead

### Security
- API key ALWAYS stored in Keychain via `Keychain.swift` — NEVER in UserDefaults
- Treat `allowExternalConnections = true` as requiring a non-nil API key — enforce in DaemonServer before binding to 0.0.0.0
- The proxy on :11434 must check the API key before forwarding, not after

### Process management
- Always send SIGINT first, wait 5 seconds, then SIGKILL — never go straight to SIGKILL
- `waitForServer()` must check `process.isRunning` on every poll iteration — fast-fail on process death
- `allocateEphemeralPort()` must bind, read, then close the socket before returning — never hardcode internal ports
- `ModelStore.pull()` must use `$VENV/bin/huggingface-cli` — never `huggingface-cli` from PATH

### Proxy
- `ProxyServer` must return 503 (not hang) when no upstream is set
- Streaming responses must be forwarded chunk-by-chunk — no full buffering
- `setUpstream(port:)` must be atomic — use a lock or actor to prevent race between old and new upstream

### Logging
- Use `OSLog` for structured daemon events
- Pipe `mlx_lm.server` stdout/stderr directly to the log file via `readabilityHandler`
- Rotate log at startup if `server.log` > 50 MB → rename to `server.log.1`, create fresh file
- Log directory: `~/.ollmlx/logs/` — create with `withIntermediateDirectories: true`

### CLI output style
- Mirror Ollama's output format exactly (table headers, `\r` progress overwrite, `pull complete` message)
- Use `fflush(stdout)` after every `print(terminator: "")` in streaming contexts
- Exit non-zero with a clear error message if daemon not running (connection refused on :11435)

## File naming
- Swift files: PascalCase matching the primary type they contain
- One primary type per file
- Commands in `Sources/ollmlx/Commands/` — one file per command

## What NOT to do
- Do not use `@AppStorage` anywhere in OllmlxCore
- Do not import AppKit in OllmlxCore or the CLI target
- Do not store the API key in UserDefaults
- Do not hardcode the internal mlx_lm.server port — always use ephemeral allocation
- Do not call `huggingface-cli` from PATH — always use the venv binary
- Do not buffer streaming proxy responses — forward chunks immediately
- Do not go straight to SIGKILL — always try SIGINT first with a 5-second grace period
- Do not allow external connections without an API key being set
- Do not use Homebrew in the bootstrap script — use uv from astral.sh
```

---

## 9. Entitlements Reference

`ollmlx.entitlements` (hardened runtime, direct distribution):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <!-- Required to spawn Python/MLX which uses JIT/unsigned memory -->
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <!-- HuggingFace downloads and localhost HTTP -->
    <key>com.apple.security.network.client</key>
    <true/>
    <!-- Listen on :11434 and :11435 -->
    <key>com.apple.security.network.server</key>
    <true/>
    <!-- Spawn external Python process outside the sandbox -->
    <key>com.apple.security.temporary-exception.sbpl</key>
    <string>(allow process-exec (literal "/bin/sh"))</string>
</dict>
</plist>
```

> ⚠️ `com.apple.security.cs.allow-unsigned-executable-memory` + process spawning = **Mac App Store ineligible**. Direct distribution (.dmg) only.

---

## 10. Key Implementation Gotchas

Captured directly from the spec to prevent the agent from rediscovering these the hard way:

1. **Python path** — never assume `/usr/bin/python3`. Always read from `OllmlxConfig.pythonPath`. If empty, trigger bootstrap.
2. **Token limit** — `mlx_lm`'s default is 512 tokens. Always pass `--max-tokens` (default 4096) to the server invocation.
3. **Model not cached = refuse to start** — `ServerManager.start()` must call `ModelStore.isModelCached()` before spawning. Throw `ServerError.modelNotFound` if false.
4. **Multiple models** — not supported in v1. `start()` returns `.alreadyRunning` if state is not `.stopped`. Do not implement side-by-side loading.
5. **`waitForServer()` process-death fast-fail** — check `process.isRunning` inside the polling loop, not just at the start. A model crash during startup should fail immediately, not after 120 seconds.
6. **`huggingface-cli` from venv** — `ModelStore.pull()` must resolve the binary as `"\(config.venvPath)/bin/huggingface-cli"`, not `"huggingface-cli"`.
7. **`@AppStorage` is main-thread only** — forbidden in `OllmlxCore`. Raw `UserDefaults` is safe from any thread.
8. **Sparkle key** — generate EdDSA key pair with `./bin/generate_keys`, embed public key in `Info.plist` as `SUPublicEDKey`. Never commit the private key.
9. **SBPL entitlement wording** — the exact string may need tuning per Apple notarisation feedback. Start with the literal path to `python` and iterate.
10. **Ollama shim warning** — before creating `/usr/local/bin/ollama`, check if a real Ollama binary exists there (not just a symlink to ollmlx). Show a warning modal if it does.
