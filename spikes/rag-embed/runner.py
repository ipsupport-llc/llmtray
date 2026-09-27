"""Embed runner: a long-lived subprocess speaking JSON lines on stdin/stdout.

  python runner.py --registry registry.json --entry bge-m3 --model-dir DIR [--verify]

stdout carries protocol lines only (logs go to stderr). Protocol v1:

  runner -> {"event":"ready","protocol":1,"entry":..,"dim":..,"max_length":..,
             "load_ms":..,"verify_min_cos":..|null,"pid":..,"limits":{..}}
            {"event":"fatal","error":{..}}            (then exit 1)
  client -> {"id":"r1","op":"embed","kind":"query"|"document","texts":[..],"timeout_ms":30000}
  runner -> {"id":"r1","ok":true,"dim":1024,"count":n,"dtype":"f16",
             "vectors":"<base64, n*dim little-endian float16, row-major>",
             "tokens":[..],"truncated":[i..],"ms":..}
         or {"id":"r1","ok":false,"error":{"code":"bad_request|too_large|timeout|cancelled|internal","message":".."}}
  client -> {"id":"c1","op":"cancel","target":"r1"}   (no reply of its own; r1 answers "cancelled")
  client -> {"id":"p1","op":"ping"}  -> {"id":"p1","ok":true,"pong":true,"queue":n}
  client -> {"op":"shutdown"} or stdin EOF -> finish the current batch, fail queued requests, exit 0.

Requests are served one at a time in arrival order (one GPU). Timeouts and
cancellation are checked between batches (a batch is bounded by
max_tokens_per_batch, ~1-2 s at most), so a stuck kernel is the client's job:
it kills the process after timeout + grace. The runner exits when its parent
dies (ppid changes), so it never outlives the app.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import queue
import sys
import threading
import time

T_START = time.perf_counter()
ap = argparse.ArgumentParser()
ap.add_argument("--registry", required=True)
ap.add_argument("--entry", required=True)
ap.add_argument("--model-dir", required=True)
ap.add_argument("--dtype")
ap.add_argument("--verify", action="store_true")
ap.add_argument("--memory-limit-gb", type=float, default=3.0)
args = ap.parse_args()

LIMITS = {
    "max_line_bytes": 8 * 2**20,     # one request line
    "max_texts": 256,                # per request
    "max_text_chars": 200_000,       # per text (tokenizer truncates to max_length anyway)
    "max_request_tokens": 262_144,   # after tokenization/truncation
}

out_lock = threading.Lock()


def send(obj: dict) -> None:
    line = json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
    with out_lock:
        sys.stdout.write(line)
        sys.stdout.flush()


def log(*a) -> None:
    print("[embed-runner]", *a, file=sys.stderr, flush=True)


def err(rid, code, msg):
    send({"id": rid, "ok": False, "error": {"code": code, "message": msg}})


try:
    import mlx.core as mx
    import numpy as np

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from embedder.core import Embedder, load_registry

    mx.set_memory_limit(int(args.memory_limit_gb * 2**30))
    entry = load_registry(args.registry)[args.entry]
    emb = Embedder(entry, args.model_dir, args.dtype)
    vmin = None
    if args.verify:
        ref = os.path.join(os.path.dirname(os.path.abspath(args.registry)), entry["reference"]["file"])
        vmin = emb.verify(ref)
        if not vmin >= entry["reference"]["min_cosine"]:  # also rejects NaN (fp16 overflow)
            raise RuntimeError(f"reference check failed: min cosine {vmin:.5f} < {entry['reference']['min_cosine']}")
except Exception as ex:  # noqa: BLE001
    send({"event": "fatal", "error": {"code": "load_failed", "message": f"{type(ex).__name__}: {ex}"}})
    sys.exit(1)

requests: "queue.Queue[dict | None]" = queue.Queue()
cancelled: set[str] = set()
closing = threading.Event()  # stdin EOF / shutdown: stop at the next batch boundary
PARENT = os.getppid()


def reader() -> None:
    inp = sys.stdin.buffer
    while True:
        line = inp.readline(LIMITS["max_line_bytes"] + 1)
        if not line:
            break  # EOF
        if len(line) > LIMITS["max_line_bytes"] and not line.endswith(b"\n"):
            while True:  # drain the rest of the oversized line
                more = inp.readline(1 << 20)
                if not more or more.endswith(b"\n"):
                    break
            err(None, "too_large", f"request line exceeds {LIMITS['max_line_bytes']} bytes")
            continue
        try:
            msg = json.loads(line)
            assert isinstance(msg, dict)
        except Exception:  # noqa: BLE001
            err(None, "bad_request", "not a JSON object line")
            continue
        op = msg.get("op", "embed")
        if op == "cancel":
            cancelled.add(str(msg.get("target")))
        elif op == "ping":
            send({"id": msg.get("id"), "ok": True, "pong": True, "queue": requests.qsize()})
        elif op == "shutdown":
            break
        else:
            msg["_t"] = time.monotonic()
            requests.put(msg)
    closing.set()
    requests.put(None)


def watchdog() -> None:
    while True:
        time.sleep(1.0)
        if os.getppid() != PARENT:  # orphaned: the app died without closing stdin
            log("parent gone, exiting")
            os._exit(3)


def handle(msg: dict) -> None:
    rid = msg.get("id")
    if rid is None or msg.get("op", "embed") != "embed":
        return err(rid, "bad_request", "need id and op=embed")
    texts, kind = msg.get("texts"), msg.get("kind", "document")
    if kind not in ("query", "document") or not isinstance(texts, list) or not all(isinstance(t, str) for t in texts):
        return err(rid, "bad_request", "texts must be a list of strings, kind query|document")
    if len(texts) > LIMITS["max_texts"]:
        return err(rid, "too_large", f"more than {LIMITS['max_texts']} texts")
    if any(len(t) > LIMITS["max_text_chars"] for t in texts):
        return err(rid, "too_large", f"a text exceeds {LIMITS['max_text_chars']} characters")
    deadline = msg["_t"] + msg.get("timeout_ms", 60_000) / 1000
    t0 = time.perf_counter()
    seqs = emb.encode_ids(texts, kind)
    ntok = sum(map(len, seqs))
    if ntok > LIMITS["max_request_tokens"]:
        return err(rid, "too_large", f"{ntok} tokens > {LIMITS['max_request_tokens']}")
    # Same batching as Embedder.embed_ids, with deadline/cancel checks between batches.
    b = entry.get("batching", {})
    max_tokens, max_batch = b.get("max_tokens_per_batch", 16384), b.get("max_batch", 32)
    order = sorted(range(len(seqs)), key=lambda i: -len(seqs[i]))
    vecs = np.zeros((len(seqs), emb.entry.get("output_dim") or entry["dim"]), np.float16)
    i = 0
    while i < len(order):
        if rid in cancelled or closing.is_set():
            cancelled.discard(rid)
            return err(rid, "cancelled", "runner shutting down" if closing.is_set() else "cancelled by client")
        if time.monotonic() > deadline:
            return err(rid, "timeout", f"deadline passed after {i}/{len(seqs)} texts")
        n = max(1, min(max_batch, max_tokens // max(len(seqs[order[i]]), 1)))
        idx = order[i:i + n]
        v = emb._forward([seqs[j] for j in idx])
        mx.eval(v)
        vecs[idx] = np.array(v).astype(np.float16)
        i += n
    cancelled.discard(rid)
    send({"id": rid, "ok": True, "dim": vecs.shape[1], "count": len(texts), "dtype": "f16",
          "vectors": base64.b64encode(vecs.astype("<f2").tobytes()).decode(),
          "tokens": [len(s) for s in seqs],
          "truncated": [k for k, s in enumerate(seqs) if len(s) >= emb.max_len],
          "ms": round((time.perf_counter() - t0) * 1000, 1)})


threading.Thread(target=reader, daemon=True).start()
threading.Thread(target=watchdog, daemon=True).start()
send({"event": "ready", "protocol": 1, "entry": args.entry, "dim": entry["dim"], "max_length": emb.max_len,
      "load_ms": round((time.perf_counter() - T_START) * 1000), "verify_min_cos": vmin, "pid": os.getpid(),
      "limits": LIMITS})

while True:
    msg = requests.get()
    if msg is None:
        break
    if closing.is_set():
        err(msg.get("id"), "cancelled", "runner shutting down")
        continue
    try:
        handle(msg)
    except Exception as ex:  # noqa: BLE001
        err(msg.get("id"), "internal", f"{type(ex).__name__}: {ex}")
    mx.clear_cache()  # hand freed buffers back; the chat model shares the GPU
log("stdin closed, exiting")
sys.exit(0)
