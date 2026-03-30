# ollmlx

Run local LLMs on Apple Silicon via [mlx-lm](https://github.com/ml-explore/mlx-examples/tree/main/llms/mlx_lm). Menubar app + CLI with OpenAI-compatible and Ollama-compatible APIs on `localhost:11434`.

## Requirements

- Apple Silicon Mac (M1 or later)
- macOS 14+
- Internet connection for first run (downloads uv, mlx-lm, and models from Hugging Face)

## Installation

### Homebrew (recommended)

```bash
brew tap darrylmorley/ollmlx
brew install --cask darrylmorley/ollmlx/ollmlx
```

### Manual

1. Download the latest `ollmlx-x.x.x.dmg` from the [releases page](https://github.com/darrylmorley/ollmlx/releases)
2. Drag `ollmlx.app` to `/Applications`
3. Launch from Applications or Spotlight

## First run

On first launch, ollmlx will:

1. **Bootstrap Python environment** — installs [uv](https://github.com/astral-sh/uv) and creates a venv at `~/.ollmlx/venv` with `mlx-lm` and `huggingface-hub`. A progress sheet shows the status. If something goes wrong, the error output is displayed with a Retry button. If a venv already exists at `~/.ollmlx/venv`, this step is skipped automatically.

2. **Offer to install the CLI** — creates a symlink at `/usr/local/bin/ollmlx` so you can use `ollmlx` from any terminal. Requires your admin password. You can skip this and install later from Settings.

## Usage

### Menubar app

The daemon starts automatically when the app launches — no manual setup needed. Click the brain icon in your menu bar to:

- See the current server status (green = running, grey = stopped, red = error)
- Select and switch models from your cached models
- Start / stop the server
- Pull new models from Hugging Face
- Copy `localhost:11434` to your clipboard
- Open server logs
- Access Settings
- Check for updates

### CLI

The daemon is started automatically by the menubar app. If you installed via Homebrew, the `ollmlx` CLI is available immediately in any terminal. If you want to run CLI-only without the app, start the daemon manually first:

```bash
ollmlx serve
```

Then use any command from a separate terminal:

| Command | Description |
|---|---|
| `ollmlx serve` | Start the daemon (control API on :11435, public API on :11434) |
| `ollmlx run <model> [prompt]` | Start a model and send a prompt, or enter interactive REPL |
| `ollmlx pull <model>` | Download a model from Hugging Face |
| `ollmlx list` | List locally cached models |
| `ollmlx show <model>` | Show model details (size, quantisation, context length) |
| `ollmlx rm <model>` | Remove a model from the local cache |
| `ollmlx stop` | Stop the currently running model |
| `ollmlx ps` | Show the running model (name, size, port) |
| `ollmlx status` | Print raw daemon status as JSON |

Examples:

```bash
# Pull and run a model (start the app first, or run `ollmlx serve` in a terminal)
ollmlx pull mlx-community/Llama-3.2-3B-Instruct-4bit
ollmlx run mlx-community/Llama-3.2-3B-Instruct-4bit "What is the capital of France?"

# Interactive chat
ollmlx run mlx-community/Llama-3.2-3B-Instruct-4bit
>>> What is quantum computing?
>>> /bye

# List cached models
ollmlx list

# Check what is running
ollmlx ps
```

## Ollama migration

ollmlx exposes both OpenAI-compatible (`/v1/chat/completions`, `/v1/models`) and Ollama-compatible (`/api/tags`, `/api/chat`, `/api/generate`) endpoints on the same default port as Ollama (`localhost:11434`). Any tool or client that works with Ollama should work with ollmlx without reconfiguration.

If an Ollama client requests a different model than the one currently running, ollmlx will automatically stop the current model and start the requested one.

> **Important:** Ollama and ollmlx both use port `11434`. Quit Ollama before launching ollmlx, or change one of the ports in Settings.

- **Open WebUI** — set the Ollama URL to `http://localhost:11434`. Model list and chat work natively via the Ollama API
- **Continue, Cursor, or other IDE plugins** — point them at `http://localhost:11434` (usually the default)
- **Python/JS clients** — any OpenAI-compatible client library works, just set the base URL to `http://localhost:11434/v1`

### Optional Ollama CLI shim

If you have scripts or tools that call the `ollama` binary directly, you can create a compatibility symlink from Settings → Compatibility → "Install Ollama shim". This creates `/usr/local/bin/ollama` pointing to `/usr/local/bin/ollmlx`.

If a real Ollama installation is detected at that path, the toggle will warn you and refuse to overwrite it.

## Building from source

```bash
# Clone the repository
git clone https://github.com/darrylmorley/ollmlx.git
cd ollmlx

# Build the CLI only
swift build --target ollmlx

# Build all targets (including the app framework)
swift build

# Run tests
swift test

# Build the app via Xcode — open the project,
# select the OllmlxApp scheme, and hit Cmd+R
open ollmlx.xcodeproj

# Create a signed DMG (requires Developer ID)
bash Scripts/build_dmg.sh
```

## Architecture

```
Sources/
  OllmlxCore/    Shared framework (no AppKit/SwiftUI) — server management,
                 proxy, control API, model store, config, logging
  OllmlxApp/     Menubar app (AppKit + SwiftUI) — status item, popover,
                 settings, bootstrap, Sparkle auto-update
  ollmlx/        CLI (ArgumentParser) — 9 commands against the control API
```

| Port | Purpose |
|---|---|
| 11434 | Public OpenAI-compatible + Ollama-compatible API (clients connect here) |
| 11435 | Internal control API (CLI and app only) |
| Ephemeral | mlx_lm.server internal port (allocated dynamically) |

## Known limitations

- **One model at a time** — v1 supports running a single model. Switching models stops the current one first. External clients (e.g. Open WebUI) can trigger model switches automatically via `/api/chat` or `/api/generate`.
- **Mac App Store not supported** — ollmlx requires `com.apple.security.cs.allow-unsigned-executable-memory` to spawn the Python/MLX process and `com.apple.security.temporary-exception.sbpl` for process execution outside the sandbox. These entitlements are incompatible with the Mac App Store. Distribution is via signed and notarised DMG only.
- **Apple Silicon only** — mlx-lm requires Apple Silicon (M1+). Intel Macs are not supported.
- **Ollama conflict** — ollmlx and Ollama cannot run simultaneously as both default to port 11434. Either quit Ollama first or change the port in Settings.

## License

MIT
