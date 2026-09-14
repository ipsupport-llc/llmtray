# LLMTray

A native macOS menu bar app for running local LLMs with [mlx-lm](https://github.com/ml-explore/mlx-lm) on Apple Silicon — a proper interface instead of a shell script and a terminal tab.

<p align="center"><em>Screenshot coming soon</em></p>

**[Download the latest .dmg](https://github.com/ipsupport-llc/llmtray/releases/latest/download/LLMTray.dmg)** — unsigned build, so the first launch needs right-click → Open to clear Gatekeeper. Or build from source below.

## What it does

- **Start/stop `mlx_lm.server`** from the menu bar, against any model in your models folder (`~/.llmtray/models` by default, configurable in Settings — point it at `~/.lmstudio/models` to share models already downloaded via LM Studio).
- **Browse and download models from Hugging Face** right from the app — search, see file sizes, download with a real progress bar (speed, ETA, pause/resume), and a size check on every file so a truncated download doesn't quietly pass as "done."
- **Chat** against the running server (OpenAI-compatible `/v1/chat/completions`), with streamed `<think>` reasoning shown separately from the final answer, tok/s, and per-chat sampling settings (temperature/top-p/max tokens).
- **Menu bar icon reflects real state**: green + pulsing while anything is generating (this app's own chat *or* an external tool hitting the server directly), orange/red on real thermal pressure (`ProcessInfo.thermalState`), pulled independently so one signal never hides the other.
- **Live server log** in its own window, and a quick right-click menu (start/stop, quit) for when you don't need the full chat window.
- Runs a **pinned, patched `mlx-lm`** (see [`runtime/`](./runtime)) — two small, reversible patches on top of stock `mlx_lm.server`, with an in-app update check against PyPI.

## Requirements

- macOS 13+, Apple Silicon.
- Xcode command line tools (`swift build`) — no full Xcode project needed.
- Python 3 (for the one-time `mlx-lm` venv bootstrap in `runtime/`).

## Quick start

```bash
git clone https://github.com/ipsupport-llc/llmtray.git
cd llmtray

# One-time: create the mlx-lm venv and apply the runtime patches.
# Point this at any local model directory just to bootstrap the venv.
./runtime/run_server.sh ~/.llmtray/models/<publisher>/<model> --port 8765

# Build and run the app (Ctrl-C the command above first; the app drives
# the server itself from here on).
swift build
.build/debug/LLMTray
```

The app looks for models under `~/.llmtray/models/<publisher>/<model-name>/` by default (configurable in Settings; the layout matches LM Studio's own `~/.lmstudio/models`, so pointing it there works too) — either point it at models you already have, or use the in-app Hugging Face browser to pull one down.

## Why a patched mlx-lm?

Stock `mlx_lm.server` is missing a couple of things this app relies on:

- `--kv-bits` / `--kv-group-size` / `--quantized-kv-start` for KV-cache quantization (lets a bigger model's context fit in less memory).
- A crash-safety fix in the tool-call parser.

`runtime/run_server.sh` applies both patches idempotently against a pinned `mlx-lm` version (`runtime/mlx_lm_runtime.json`) — see the doc comment on `RuntimeManager.swift` for why the pin isn't auto-tracked to upstream's latest release.

## Architecture

```
Sources/LLMTray/
├── LLMTrayApp.swift       menu bar item, icon state, right-click menu, SIGTERM handling
├── ServerManager.swift    starts/stops mlx_lm.server, captures its log, busy detection
├── ChatClient.swift       OpenAI-compatible SSE streaming client
├── HFModelBrowser.swift   Hugging Face search + resumable downloads
├── RuntimeManager.swift   pinned mlx-lm version + patch reapplication
└── ...
runtime/
├── run_server.sh          self-contained venv bootstrap + patched server launcher
├── mlx_lm_runtime.json    pinned mlx-lm version
├── patch_mlx_server_kv.py
└── patch_mlx_tool_parser.py
```

## Status

Working daily driver on a MacBook Air M5. Not yet code-signed/notarized or packaged as a distributable `.app` — that's the next milestone (see [Actions](../../actions) for CI build checks).

## License

Apache 2.0 — see [LICENSE](./LICENSE).
