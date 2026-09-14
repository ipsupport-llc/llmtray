"""Patch a pip-installed mlx_lm's server.py with independently-idempotent
additions (each safe to re-run after a fresh `pip install mlx-lm` wipes it):

1. --kv-bits/--kv-group-size/--quantized-kv-start flags, threaded into the
   stream_generate(...) call used to serve each request. Upstream
   mlx_lm.generate already supports KV-cache quantization end to end
   (mlx_lm/generate.py's stream_generate accepts these params directly) --
   server.py just never exposed them as CLI flags.

2. --model-alias NAME (repeatable) -- registers extra name(s) in
   ServerModelProvider's existing _model_map/_adapter_map/_draft_model_map
   (the same mechanism it already uses for "default_model") so a client that
   requests an arbitrary/unconfigured model name still gets routed to
   --model instead of mlx_lm trying to download it from the HF Hub.

3. GET /api/v0/models -- LM Studio's own REST API convention (distinct
   from the OpenAI-compatible /v1/models mlx_lm already serves). Some
   clients default to probing LM Studio's endpoint shape and 404 against
   stock mlx_lm.server. Aliased to the exact same handler as /v1/models
   (same OpenAI-shaped response, not a re-implementation of LM Studio's
   actual richer schema) -- enough to stop the 404s and hand back a
   usable model list.

4. Crash-safety for client-disconnect-mid-stream. handle_completion's
   generation loop has a try/finally (ctx.stop() always runs) but no
   except -- a client closing the connection mid-stream (Ctrl-C, timeout,
   navigated away) raises BrokenPipeError/ConnectionResetError from
   wfile.write, which propagates uncaught and crashes the request thread
   with a traceback (found live: `BrokenPipeError: [Errno 32] Broken
   pipe` from generate response streaming). The generation itself already
   completed its useful work by that point (GPU already spent the
   compute) -- just stop cleanly instead of crashing the thread.

Each patch is anchored on its own stable, untouched-by-the-other-patch
location in the file, so they can be applied in either order/combination.

Usage:
    python poc/patch_mlx_server_kv.py [path-to-server.py]
    # with no argument, patches whatever mlx_lm is importable in the current env
"""

from __future__ import annotations

import sys
from pathlib import Path

KV_IMPORT_OLD = """from ._version import __version__
from .generate import (
    BatchGenerator,
    SequenceStateMachine,
    stream_generate,
)"""
KV_IMPORT_NEW = """from ._version import __version__
from .generate import (
    DEFAULT_QUANTIZED_KV_START,
    BatchGenerator,
    SequenceStateMachine,
    stream_generate,
)"""

KV_CALL_OLD = """                prompt_progress_callback=progress,
                prefill_step_size=self.cli_args.prefill_step_size,
            ):"""
KV_CALL_NEW = """                prompt_progress_callback=progress,
                prefill_step_size=self.cli_args.prefill_step_size,
                kv_bits=self.cli_args.kv_bits,
                kv_group_size=self.cli_args.kv_group_size,
                quantized_kv_start=self.cli_args.quantized_kv_start,
            ):"""

KV_ARGS_OLD = """    parser.add_argument(
        "--use-default-chat-template",
        action="store_true",
        help="Use the default chat template",
    )"""
KV_ARGS_NEW = """    parser.add_argument(
        "--use-default-chat-template",
        action="store_true",
        help="Use the default chat template",
    )
    parser.add_argument(
        "--kv-bits",
        type=int,
        help="Number of bits for KV cache quantization. Defaults to no quantization.",
        default=None,
    )
    parser.add_argument(
        "--kv-group-size",
        type=int,
        help="Group size for KV cache quantization.",
        default=64,
    )
    parser.add_argument(
        "--quantized-kv-start",
        help="When --kv-bits is set, start quantizing the KV cache "
        "from this step onwards.",
        type=int,
        default=DEFAULT_QUANTIZED_KV_START,
    )"""

# Anchored on --trust-remote-code, which neither this nor the KV patch touch,
# so this applies cleanly whether or not the KV patch has already run.
ALIAS_ARGS_OLD = """    parser.add_argument(
        "--trust-remote-code",
        action="store_true",
        help="Enable trusting remote code for tokenizer",
    )"""
ALIAS_ARGS_NEW = """    parser.add_argument(
        "--trust-remote-code",
        action="store_true",
        help="Enable trusting remote code for tokenizer",
    )
    parser.add_argument(
        "--model-alias",
        action="append",
        default=None,
        help="Extra model name a client may request that should route to --model "
        "instead of mlx_lm trying to fetch it from the HF Hub. Repeatable.",
    )"""

ALIAS_MAP_OLD = """        self._model_map["default_model"] = self.cli_args.model
        self._adapter_map["default_model"] = self.cli_args.adapter_path
        self._draft_model_map["default_model"] = self.cli_args.draft_model"""
ALIAS_MAP_NEW = """        self._model_map["default_model"] = self.cli_args.model
        self._adapter_map["default_model"] = self.cli_args.adapter_path
        self._draft_model_map["default_model"] = self.cli_args.draft_model
        for _alias in (self.cli_args.model_alias or []):
            self._model_map[_alias] = self.cli_args.model
            self._adapter_map[_alias] = self.cli_args.adapter_path
            self._draft_model_map[_alias] = self.cli_args.draft_model"""

LMSTUDIO_MODELS_OLD = """        if self.path.startswith("/v1/models"):
            self.handle_models_request()
        elif self.path == "/health":"""
LMSTUDIO_MODELS_NEW = """        if self.path.startswith("/v1/models") or self.path.startswith("/api/v0/models"):
            self.handle_models_request()
        elif self.path == "/health":"""

DISCONNECT_SAFETY_OLD = """                self.wfile.write(response_json)
                self.wfile.flush()
        finally:
            ctx.stop()"""
DISCONNECT_SAFETY_NEW = """                self.wfile.write(response_json)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError) as e:
            logging.debug(f"Client disconnected mid-response, stopping generation: {e!r}")
        finally:
            ctx.stop()"""


def find_server_py() -> Path:
    import mlx_lm

    return Path(mlx_lm.__file__).parent / "server.py"


def apply_patch(text: str, old: str, new: str, label: str, target: Path) -> tuple[str, bool]:
    if new in text:
        print(f"{target}: '{label}' already present")
        return text, False
    if old not in text:
        raise SystemExit(
            f"{target}: expected snippet for '{label}' not found -- "
            f"mlx_lm's server.py has likely changed shape upstream, patch needs updating"
        )
    print(f"{target}: applying '{label}'")
    return text.replace(old, new, 1), True


def main() -> None:
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else find_server_py()
    text = target.read_text()
    changed = False

    if "--kv-bits" in text:
        print(f"{target}: kv-cache flags already present")
    else:
        for old, new, label in (
            (KV_IMPORT_OLD, KV_IMPORT_NEW, "kv-cache import"),
            (KV_CALL_OLD, KV_CALL_NEW, "kv-cache stream_generate call"),
            (KV_ARGS_OLD, KV_ARGS_NEW, "kv-cache argparse flags"),
        ):
            text, did = apply_patch(text, old, new, label, target)
            changed = changed or did

    text, did = apply_patch(text, ALIAS_ARGS_OLD, ALIAS_ARGS_NEW, "--model-alias argparse flag", target)
    changed = changed or did
    text, did = apply_patch(text, ALIAS_MAP_OLD, ALIAS_MAP_NEW, "--model-alias map wiring", target)
    changed = changed or did
    text, did = apply_patch(text, LMSTUDIO_MODELS_OLD, LMSTUDIO_MODELS_NEW, "/api/v0/models alias", target)
    changed = changed or did
    text, did = apply_patch(text, DISCONNECT_SAFETY_OLD, DISCONNECT_SAFETY_NEW, "client-disconnect crash safety", target)
    changed = changed or did

    if changed:
        target.write_text(text)
    else:
        print(f"{target}: already fully patched, nothing to do")


if __name__ == "__main__":
    main()
