#!/bin/bash
# install_mlx_lm.sh — Bootstrap Python venv with mlx-lm and huggingface-hub[cli]
# Uses uv from astral.sh — never Homebrew.
# On success, prints the python path as the last line of stdout.

set -euo pipefail

VENV_DIR="$HOME/.ollmlx/venv"
UV_INSTALL="https://astral.sh/uv/install.sh"

echo "ollmlx bootstrap: setting up Python environment..."

# 1. Install uv if not already present
if ! command -v uv &>/dev/null; then
    echo "Installing uv package manager..."
    curl -LsSf "$UV_INSTALL" | sh
    # uv installs to ~/.local/bin by default
    export PATH="$HOME/.local/bin:$PATH"
fi

# Verify uv is available
if ! command -v uv &>/dev/null; then
    echo "ERROR: uv installation failed — uv not found in PATH" >&2
    exit 1
fi

echo "Using uv: $(command -v uv)"

# 2. Create venv if it doesn't exist or is broken
if [ ! -f "$VENV_DIR/bin/python" ]; then
    echo "Creating Python virtual environment at $VENV_DIR..."
    uv venv "$VENV_DIR"
fi

# Verify venv python works
if ! "$VENV_DIR/bin/python" --version &>/dev/null; then
    echo "Venv python is broken — recreating..."
    rm -rf "$VENV_DIR"
    uv venv "$VENV_DIR"
fi

# 3. Install mlx-lm and huggingface-hub[cli]
echo "Installing mlx-lm and huggingface-hub[cli]..."
uv pip install --python "$VENV_DIR/bin/python" mlx-lm "huggingface-hub[cli]"

# 4. Verify installations
if ! "$VENV_DIR/bin/python" -c "import mlx_lm" 2>/dev/null; then
    echo "ERROR: mlx-lm installation verification failed" >&2
    exit 1
fi

if [ ! -f "$VENV_DIR/bin/huggingface-cli" ]; then
    echo "ERROR: huggingface-cli not found at $VENV_DIR/bin/huggingface-cli" >&2
    exit 1
fi

echo "Bootstrap complete."
# Print the python path as the last line — the app captures this
echo "$VENV_DIR/bin/python"
