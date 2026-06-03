# MLX Control

A native macOS menu bar app to manage your local [mlx-lm](https://github.com/ml-explore/mlx-lm) inference server — start, stop, monitor resources, and download models, all without touching the terminal.

[![build](https://github.com/wonsss/MLXControl/actions/workflows/build.yml/badge.svg)](https://github.com/wonsss/MLXControl/actions/workflows/build.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-orange)
![Swift 6](https://img.shields.io/badge/Swift-6-red)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

<!-- Add a screenshot of the menu bar popover here: -->
<!-- ![MLX Control](docs/screenshot.png) -->

## Features

- **Server control** — Start / Stop / Restart `mlx_lm.server` from the menu bar
- **Real-time monitoring** — MLX process RAM & CPU (accurate) + system GPU % / GPU mem (via ioreg, no sudo)
- **Mini sparkline graph** — GPU utilization history
- **Warm-up** — Pre-load the model into memory + measure tokens/sec
- **Model management** — Auto-detect installed MLX models from HuggingFace cache
- **Model search** — Search mlx-community on HuggingFace with size, description, and README
- **Model download** — Download any mlx-community model directly from the app
- **Model delete** — Remove a cached model with disk space preview
- **Resource alerts** — macOS notifications when RAM or free memory crosses a threshold
- **Copy endpoint** — One-click copy `http://127.0.0.1:8080/v1` for use in other tools
- **Login item toggle** — Auto-launch at login
- **Move to /Applications** — Prompted on first launch if running from elsewhere

## Requirements

| Requirement | Detail |
|---|---|
| macOS | 14.0 (Sonoma) or later |
| Hardware | Apple Silicon (M-series) — GPU monitoring via Metal/ioreg |
| mlx-lm | `pip install mlx-lm` or `uv tool install mlx-lm` |
| Models | At least one MLX model in `~/.cache/huggingface/hub/` |

## Installation

### Option A — Build from source (recommended, no Gatekeeper warning)

```bash
git clone https://github.com/wonsss/MLXControl.git
cd MLXControl
./build.sh          # builds + installs to /Applications
open /Applications/MLXControl.app
```

> Requires Xcode Command Line Tools: `xcode-select --install`

### Option B — Download pre-built (GitHub Releases)

1. Download `MLXControl.zip` from [Releases](https://github.com/wonsss/MLXControl/releases)
2. Unzip and move `MLXControl.app` to `/Applications`
3. **First launch**: right-click → Open (bypasses Gatekeeper unsigned-app warning)
   - Or run once: `xattr -dr com.apple.quarantine /Applications/MLXControl.app`

## Usage

1. Install `mlx-lm` and download at least one model:
   ```bash
   pip install mlx-lm
   python -m mlx_lm.manage --scan   # see what's cached
   ```
2. Click `⚡` in the menu bar
3. Select a model → **Start**
4. Once status shows **Up**, click **🔥 Warm** to pre-load the model
5. Point your AI agent (Hermes, Claude Code, Cursor, etc.) at `http://127.0.0.1:8080/v1`

## Logs

Server logs are written to `~/Library/Logs/MLXControl/mlx_server.log`.  
Click **📄** in the app to open them in Console.app.

## Notarization (for distributers)

If you have an Apple Developer Program membership and a "Developer ID Application"
certificate, you can distribute a notarized build:

```bash
# one-time: store Apple ID + app-specific password in the local Keychain
./notarize.sh --store-credentials

# build, sign, submit to Apple, and staple
./notarize.sh
```

This produces `MLXControl-notarized.zip` ready for GitHub Releases.
The credentials are stored in the local Keychain (never on the command line or in
git). Generate an app-specific password at [appleid.apple.com](https://appleid.apple.com)
→ Sign-In & Security → App-Specific Passwords. The Team ID is auto-detected from your
signing certificate.

## Security

- **No shell string interpolation** — all subprocess calls use `Process` with argument arrays
- **Path validation** — model delete validates the repo ID format and confines removal to the HuggingFace cache directory
- **Tool auto-detection** — `mlx_lm.server` and `hf` are located via PATH search, not hardcoded paths
- **No network access except** HuggingFace API (search/metadata) and the local inference server

## License

MIT — see [LICENSE](LICENSE)
