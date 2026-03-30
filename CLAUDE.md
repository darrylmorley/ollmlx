# ollmlx — Agent Instructions

## Project overview

macOS menubar app + CLI for running local LLMs via `mlx-lm` on Apple Silicon.

Three targets share one repository:
- **OllmlxCore** — shared framework, no UI dependencies
- **OllmlxApp** — menubar app (AppKit + SwiftUI)
- **ollmlx** — CLI (ArgumentParser, no AppKit)

The daemon (`ServerManager`) spawns and monitors `mlx_lm.server` as a child process. The CLI and menubar app communicate with the daemon exclusively via HTTP on `localhost:11435`. The public OpenAI-compatible API is exposed on `localhost:11434` via a transparent proxy. Ollama-compatible endpoints (`/api/tags`, `/api/version`, `/api/chat`, `/api/generate`) are also served on `:11434` so clients like Open WebUI can connect natively.

Full implementation plan: `ollmlx-implementation-plan.md`

---

## Build

```bash
# Open in Xcode 15+
open ollmlx.xcodeproj

# Bootstrap Python venv (run once before testing)
bash Scripts/install_mlx_lm.sh

# Build CLI from terminal
swift build --target ollmlx

# Build all targets (SPM)
swift build

# Regenerate Xcode project after changing project.yml
xcodegen generate

# Release build with code signing
xcodebuild -scheme OllmlxApp -configuration Release \
  -destination "platform=macOS" \
  DEVELOPMENT_TEAM=M4RUJ7W6MP \
  build

# Build DMG for distribution
bash Scripts/build_dmg.sh
```

---

## Implementation phases

Work through phases in order. Do not start the next phase until all completion criteria for the current phase are checked off. Each phase is documented in full in `ollmlx-implementation-plan.md`.

1. **Core foundation** — OllmlxCore compiles; ServerManager spawns/kills mlx_lm.server
2. **Control API daemon** — DaemonServer serves all five `/control/*` endpoints on `:11435`
3. **Proxy server** — `:11434` transparently forwards to mlx_lm.server's ephemeral port
4. **CLI** — All nine commands work against a running daemon
5. **Menubar app** — Full menubar UI backed by live ServerManager state
6. **Settings** — All settings persist and take effect immediately
7. **Bootstrap and CLI installation** — First-launch experience; CLI symlink to `/usr/local/bin`
8. **Polish and distribution** — Codesigning, notarisation, Sparkle, DMG

---

## Distribution

| Field | Value |
|---|---|
| Bundle ID | `com.darrylmorley.ollmlx` |
| Team ID | `M4RUJ7W6MP` |
| Signing identity | `Developer ID Application: Darryl Morley (M4RUJ7W6MP)` |
| Sparkle feed | `https://github.com/darrylmorley/ollmlx/releases/latest/download/appcast.xml` |
| Sparkle EdDSA key | `m/WL9PKIyMMY1Nx5dL9RzE3GqA+3FlR6OiWTC1IyCfA=` |

Code signing is configured per-build-configuration in `project.yml`:
- **Debug**: `CODE_SIGN_STYLE: Automatic`, identity `-` (ad-hoc)
- **Release**: `CODE_SIGN_STYLE: Manual`, identity `Developer ID Application`

After editing `project.yml`, always run `xcodegen generate` to rebuild `ollmlx.xcodeproj`.

---

## Critical rules

### Threading

- `ServerManager` is `@MainActor` — all state mutations happen on the main actor
- `OllmlxConfig` uses raw `UserDefaults` (not `@AppStorage`) so it is safe to read from CLI contexts and background tasks
- CLI commands run in async contexts — use `Task { @MainActor in }` when touching `ServerManager` from a non-main-actor context
- Never access `ServerManager.shared` from background threads without `await`

### Target boundaries

- **`OllmlxCore` must have ZERO AppKit or SwiftUI imports** — it must compile as a CLI dependency
- **The CLI target must have ZERO AppKit imports**
- Shared types (models, errors, config) belong in `OllmlxCore`
- `@AppStorage` is **banned** in `OllmlxCore` — use `OllmlxConfig` instead

### App lifecycle

- **Single instance**: `applicationDidFinishLaunching` must check `NSRunningApplication.runningApplications(withBundleIdentifier:)` — if `count > 1`, activate the existing instance and terminate self
- **Daemon auto-start**: `DaemonServer` and `ProxyServer` are started automatically in `applicationDidFinishLaunching` via `Task.detached`
- **Bootstrap detection**: Check both `OllmlxConfig.pythonPath` AND the default venv path `~/.ollmlx/venv/bin/python` — if either exists on disk, skip bootstrap and set config
- **Settings window**: Always open as a standalone `NSWindow` via `AppDelegate` — **never** as a `.sheet()` on the NSPopover (sheets on popovers deadlock the entire app)
- **Model selector**: The dropdown only updates a `@State` selection — it must **never** call `ServerManager.start()`. Starting/switching happens only when the user clicks the Start button. `MenuBarView` uses `.onChange(of: serverManager.state)` to sync the selected model when external clients trigger a model switch

### Security

- API key **always** stored in Keychain via `Keychain.swift` — **never** in UserDefaults
- `allowExternalConnections = true` requires a non-nil API key — enforce in `DaemonServer` before binding to `0.0.0.0`
- The proxy on `:11434` must validate the API key **before** forwarding, not after

### Process management

- Always send SIGINT first, wait 5 seconds, then SIGKILL — never go straight to SIGKILL
- `waitForServer()` must check `process.isRunning` on **every** poll iteration — fast-fail immediately on process death, don't wait out the full 120-second timeout
- `allocateEphemeralPort()` must bind to port 0, read the assigned port, then close the socket before returning — never hardcode internal ports
- `ModelStore.pull()` must use `$VENV/bin/huggingface-cli` (with fallback to `$VENV/bin/hf`) — never `huggingface-cli` from PATH
- `ServerManager.start()` must call `ModelStore.isModelCached()` before spawning — throw `ServerError.modelNotFound` if the model is not in the local cache

### Proxy

- `ProxyServer` must return `503 Service Unavailable` (not hang) when no upstream is set
- Streaming responses (`text/event-stream`) must be forwarded chunk-by-chunk — no full response buffering
- `setUpstream(port:)` must be atomic — use a lock or actor to prevent races between old and new upstream
- Model switches are serialized by `ModelSwitchCoordinator` (actor) — concurrent API requests must never trigger parallel stop/start cycles
- **URLSession lifecycle**: For streaming responses, `session.invalidateAndCancel()` must be called inside the `ResponseBody` closure (via `defer`), **not** on the outer function scope — the function returns the `Response` before the body closure executes, so a `defer` on the outer scope kills the session mid-stream

### Ollama compatibility layer

- Ollama-compatible routes (`/api/tags`, `/api/version`, `/api/chat`, `/api/generate`) are registered on `ProxyServer` (**before** catch-all routes so they take priority)
- `/api/tags` reads from `ModelStore.refreshCached()` — does not need an upstream; `/api/version` is unauthenticated
- `/api/chat` and `/api/generate` translate Ollama request/response format to/from OpenAI `/v1/chat/completions` — both streaming (ndjson) and non-streaming
- `/api/chat` and `/api/generate` call `ensureModel()` before forwarding — if the requested model differs from the running model, it stops the current model and starts the requested one via `ServerManager`
- `ensureModel()` delegates to `ModelSwitchCoordinator` (actor) which serializes all switch operations: same-model requests coalesce onto the in-flight task; different-model requests cancel the current switch (last writer wins). A `while true` loop re-evaluates state after every `await` to handle actor reentrancy safely
- **Do not use `MainActor.run` with async closures** — it only accepts synchronous closures. Call `@MainActor` async methods directly with `await` from nonisolated contexts
- Ollama streaming responses use `application/x-ndjson` content type (one JSON object per line), not SSE

### Logging

- Use `OSLog` for structured daemon events
- Pipe `mlx_lm.server` stdout/stderr directly to the log file via `readabilityHandler`
- Rotate log at startup: if `server.log` exceeds 50 MB, rename to `server.log.1` and create a fresh file (one backup kept)
- Log directory: `~/.ollmlx/logs/` — always create with `withIntermediateDirectories: true`

### Model store

- `refreshCached()` must only return models from `mlx-community` — filter HF cache directories to `models--mlx-community--*`
- `pull()` must **not** pass `--quiet` to `huggingface-cli download` — it suppresses tqdm progress output needed for the progress bar

### macOS app environment

- macOS apps launched via Finder/LaunchServices do **not** inherit the user's shell PATH — `~/.local/bin`, `/opt/homebrew/bin` etc. are not available via `/usr/bin/env`
- When calling external tools like `uv` from the app, resolve the absolute path by checking known candidate locations (`~/.local/bin/uv`, `/usr/local/bin/uv`, `/opt/homebrew/bin/uv`)
- The venv Python path at `~/.ollmlx/venv/bin/python` is always an absolute path and works fine

### CLI output style

- Mirror Ollama's output format exactly (table headers, `\r` progress overwrite, `pull complete` message)
- Use `fflush(stdout)` after every `print(terminator: "")` in streaming contexts
- Exit non-zero with a clear error message if the daemon is not running (connection refused on `:11435`)

---

## File naming and structure

- Swift files: PascalCase matching the primary type they contain
- One primary type per file
- CLI commands live in `Sources/ollmlx/Commands/` — one file per command
- No file should import both AppKit and OllmlxCore types that are UI-agnostic — keep the dependency direction clean

---

## Ports

| Port | Purpose |
|---|---|
| `11434` | Public OpenAI-compatible + Ollama-compatible API (clients connect here) |
| `11435` | Internal daemon control API (CLI/app only) |
| Ephemeral | `mlx_lm.server` internal port, allocated dynamically |

---

## Key paths (runtime, not configurable)

```
~/.ollmlx/venv/bin/python           # stored in UserDefaults after bootstrap
~/.ollmlx/venv/bin/huggingface-cli  # primary HF CLI binary (fallback: ~/.ollmlx/venv/bin/hf)
~/.ollmlx/logs/server.log           # current log
~/.ollmlx/logs/server.log.1         # previous log (rotated)
~/.cache/huggingface/hub/           # HF model cache (only models--mlx-community--* are listed)
~/.local/bin/uv                     # uv binary (used for mlx-lm version detection)
/usr/local/bin/ollmlx               # CLI symlink (created by app on first launch)
/usr/local/bin/ollama               # optional shim symlink
```

---

## What NOT to do

- Do not use `@AppStorage` anywhere in `OllmlxCore`
- Do not import AppKit in `OllmlxCore` or the CLI target
- Do not store the API key in UserDefaults — Keychain only
- Do not hardcode the internal `mlx_lm.server` port — always use ephemeral allocation
- Do not call `huggingface-cli` from PATH — always use the venv binary (`huggingface-cli` or `hf` fallback)
- Do not buffer streaming proxy responses — forward chunks immediately
- Do not put `defer { session.invalidateAndCancel() }` on the outer scope of proxy handlers that return streaming `ResponseBody` closures
- Do not use `.sheet()` to present views from an NSPopover — it deadlocks the app
- Do not call `ServerManager.start()` from model selector onChange — only from explicit Start button or Ollama API model-switch logic
- Do not call `ServerManager.stop()`/`start()` directly from proxy route handlers — always go through `ModelSwitchCoordinator.ensureModel()` to prevent concurrent model-switch race conditions
- Do not use `/usr/bin/env` to find tools like `uv` from the macOS app — resolve absolute paths
- Do not send SIGKILL without trying SIGINT first and waiting 5 seconds
- Do not allow external connections without an API key being set
- Do not use Homebrew in the bootstrap script — use `uv` from `astral.sh`
- Do not move on to the next phase until all completion criteria for the current phase are met
- Do not implement multiple concurrent models — v1 supports one model at a time only
