#!/usr/bin/env bash
# Launch our patched mlx_lm.server (adds --kv-bits/--kv-group-size/
# --quantized-kv-start and --model-alias, absent from stock mlx_lm.server)
# against a given model. Self-contained: creates its own venv on first run,
# (re)applies the server.py patch idempotently every run (so a
# `pip install -U mlx-lm` never silently drops it), then execs the server.
#
# --model-alias matters because many OpenAI-API clients (chat CLIs, agent
# tools) send whatever model name they have configured, not "default_model"
# -- without an alias, mlx_lm.server tries to fetch that name from the HF
# Hub and fails with a 401/404 instead of just using --model.
#
# Usage:
#   ./run_server.sh <model-path> [--port N] [--kv-bits N] [--kv-group-size N]
#       [--quantized-kv-start N] [--no-kv-quant] [--prefill-step-size N]
#       [--model-alias NAME ...]
#
# Examples:
#   ./run_server.sh ~/.lmstudio/models/local/nemotron-30b-mlx-3bit --model-alias n
#   ./run_server.sh ../models/nbit4-05-seq --port 8811 --kv-bits 8
#   ./run_server.sh ../models/nemotron-lightning-30b-ternary-06 --no-kv-quant
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${MLX_SERVER_VENV:-$SCRIPT_DIR/.mlx_server_venv}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <model-path> [--port N] [--kv-bits N] [--kv-group-size N] [--quantized-kv-start N] [--no-kv-quant] [--prefill-step-size N] [--model-alias NAME ...] [-- <extra mlx_lm.server args>]" >&2
  exit 1
fi

MODEL="$1"; shift

PORT=8765
KV_BITS=4
KV_GROUP_SIZE=64
QUANTIZED_KV_START=0
PREFILL_STEP_SIZE=128
MODEL_ALIASES=()
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --kv-bits) KV_BITS="$2"; shift 2 ;;
    --kv-group-size) KV_GROUP_SIZE="$2"; shift 2 ;;
    --quantized-kv-start) QUANTIZED_KV_START="$2"; shift 2 ;;
    --no-kv-quant) KV_BITS=""; shift 1 ;;
    --prefill-step-size) PREFILL_STEP_SIZE="$2"; shift 2 ;;
    --model-alias) MODEL_ALIASES+=("$2"); shift 2 ;;
    --) shift; EXTRA_ARGS+=("$@"); break ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -d "$VENV_DIR" ]]; then
  echo "--- creating venv at $VENV_DIR ---"
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --quiet --upgrade pip
fi

PINNED_VERSION="$(python3 -c "import json; print(json.load(open('$SCRIPT_DIR/mlx_lm_runtime.json'))['pinned_version'])")"
echo "--- ensuring mlx-lm==$PINNED_VERSION is installed (see mlx_lm_runtime.json) ---"
"$VENV_DIR/bin/pip" install --quiet "mlx-lm==$PINNED_VERSION"

echo "--- applying KV-cache-quant patch to server.py (idempotent) ---"
"$VENV_DIR/bin/python" "$SCRIPT_DIR/patch_mlx_server_kv.py"

echo "--- applying tool-call-parser crash-safety patch (idempotent) ---"
"$VENV_DIR/bin/python" "$SCRIPT_DIR/patch_mlx_tool_parser.py"

CMD=("$VENV_DIR/bin/mlx_lm.server" --model "$MODEL" --port "$PORT" --prefill-step-size "$PREFILL_STEP_SIZE")
if [[ -n "$KV_BITS" ]]; then
  CMD+=(--kv-bits "$KV_BITS" --kv-group-size "$KV_GROUP_SIZE" --quantized-kv-start "$QUANTIZED_KV_START")
fi
if [[ ${#MODEL_ALIASES[@]} -gt 0 ]]; then
  for alias in "${MODEL_ALIASES[@]}"; do
    CMD+=(--model-alias "$alias")
  done
fi
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  CMD+=("${EXTRA_ARGS[@]}")
fi

echo "--- launching: ${CMD[*]} ---"
exec "${CMD[@]}"
