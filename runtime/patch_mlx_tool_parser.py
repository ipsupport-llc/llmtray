"""Patch a pip-installed mlx_lm's tool_parsers/qwen3_coder.py so a
malformed/truncated tool-call parameter value can't crash the request
thread.

Found live: `_convert_param_value`'s object/array branch tries
`json.loads(param_value)` and, on failure, falls back to
`ast.literal_eval(param_value)` -- but that fallback is itself unguarded.
When a model emits a malformed or mid-generation-truncated parameter value
(the same failure mode server.py's ToolCallFormatter already handles
gracefully for its own parse step, logging "tool text was likely
truncated mid-generation" and dropping just that tool call), this second,
uncaught exception propagates all the way up through
BaseHTTPRequestHandler's request-handling thread and that request dies
with no response -- while the rest of the server keeps running fine
(each connection is its own thread), it's still an ungraceful, avoidable
crash for that one request.

Note this parser is applied to ANY model whose chat_template contains the
literal `<tool_call>\n<function=` tag format (see mlx_lm's
`_infer_tool_parser`), regardless of which model actually introduced that
convention -- it's a generic XML-tag/function-call format, not something
qwen3-coder-specific despite the module's name.

Usage:
    python poc/patch_mlx_tool_parser.py [path-to-qwen3_coder.py]
    # with no argument, patches whatever mlx_lm is importable in the current env
"""

from __future__ import annotations

import sys
from pathlib import Path

IMPORT_OLD = """import ast
import json
from typing import Any, Optional"""
IMPORT_NEW = """import ast
import json
import logging
from typing import Any, Optional"""

HELPER_MARKER = "def _safe_literal_eval("
HELPER_ANCHOR = """_obj_types = {"object", "array", "arr"}"""
HELPER_NEW = """_obj_types = {"object", "array", "arr"}


def _safe_literal_eval(value: str) -> Any:
    \"\"\"ast.literal_eval, but falls back to the raw string instead of
    raising. Model-generated tool-call parameter text can be malformed or
    truncated mid-generation; a parse failure here must not crash the
    request thread (json.loads failures a few lines up already ARE
    caught -- this closes the same gap for the literal_eval fallback).\"\"\"
    try:
        return ast.literal_eval(value)
    except (ValueError, SyntaxError) as e:
        logging.warning(
            f"Failed to parse tool-call parameter value ({type(e).__name__}: {e}) -- "
            f"falling back to the raw string; value was likely malformed or "
            f"truncated mid-generation."
        )
        return value"""

CALL_SITES_OLD = """            try:
                return json.loads(param_value)
            except json.JSONDecodeError:
                return ast.literal_eval(param_value)

        return ast.literal_eval(param_value)"""
CALL_SITES_NEW = """            try:
                return json.loads(param_value)
            except json.JSONDecodeError:
                return _safe_literal_eval(param_value)

        return _safe_literal_eval(param_value)"""


def find_qwen3_coder_py() -> Path:
    import mlx_lm.tool_parsers.qwen3_coder as m

    return Path(m.__file__)


def apply_patch(text: str, old: str, new: str, label: str, target: Path) -> tuple[str, bool]:
    if new in text:
        print(f"{target}: '{label}' already present")
        return text, False
    if old not in text:
        raise SystemExit(
            f"{target}: expected snippet for '{label}' not found -- "
            f"mlx_lm's qwen3_coder.py has likely changed shape upstream, patch needs updating"
        )
    print(f"{target}: applying '{label}'")
    return text.replace(old, new, 1), True


def main() -> None:
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else find_qwen3_coder_py()
    text = target.read_text()
    changed = False

    if HELPER_MARKER in text:
        print(f"{target}: already fully patched, nothing to do")
        return

    for old, new, label in (
        (IMPORT_OLD, IMPORT_NEW, "logging import"),
        (HELPER_ANCHOR, HELPER_NEW, "_safe_literal_eval helper"),
        (CALL_SITES_OLD, CALL_SITES_NEW, "call sites -> _safe_literal_eval"),
    ):
        text, did = apply_patch(text, old, new, label, target)
        changed = changed or did

    if changed:
        target.write_text(text)
    else:
        print(f"{target}: already fully patched, nothing to do")


if __name__ == "__main__":
    main()
