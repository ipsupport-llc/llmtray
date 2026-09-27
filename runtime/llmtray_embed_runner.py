# LLMTray's embed runner (adr/0012, Dense retrieval): a long-lived child
# speaking JSON lines, one per message, on stdin/stdout. Nothing is written
# to disk.
#
#   python3 llmtray_embed_runner.py --registry embedders.json --entry bge-m3 --model-dir DIR
#
# runner -> {"event":"ready","protocol":1,"entry":..,"dim":..,"max_length":..,
#            "load_ms":..,"verify_min_cos":..,"pid":..,"limits":{..}}
#        or {"event":"fatal","error":{"code":"load_failed"|"verify_failed","message":..}} (then exit 1)
# client -> {"id":"r1","op":"embed","kind":"query"|"document","texts":[..],"timeout_ms":30000}
# runner -> {"id":"r1","ok":true,"dim":1024,"count":n,"dtype":"f16",
#            "vectors":"<base64: n*dim little-endian float16, row-major>",
#            "tokens":[..],"truncated":[i..],"ms":..}
#        or {"id":"r1","ok":false,"error":{"code":"bad_request|too_large|timeout|cancelled|internal","message":..}}
# client -> {"id":"c1","op":"cancel","target":"r1"}   (no reply of its own; r1 answers "cancelled")
# client -> {"id":"p1","op":"ping"} -> {"id":"p1","ok":true,"pong":true,"queue":n}
# client -> {"op":"shutdown"}, or stdin EOF (the normal stop): the current
#           batch finishes, queued requests answer "cancelled", exit 0.
#
# Queries are served before queued documents, and between the batches of a
# document request: a search doesn't wait behind an index slice. Cancel and
# timeouts act at batch boundaries (<= max_tokens_per_batch, ~2 s at most),
# so a stuck kernel is the client's to handle: it kills the runner after
# timeout + grace. The runner exits within 0.1 s once its parent is gone.
import argparse
import base64
import collections
import json
import os
import sys
import threading
import time

T_START = time.perf_counter()
# The protocol gets its own copy of fd 1; fd 1 itself (and sys.stdout) then
# point at stderr, so nothing MLX or native code prints can land inside a
# protocol line.
protocol = os.fdopen(os.dup(1), "wb")
os.dup2(2, 1)
sys.stdout = sys.stderr

ap = argparse.ArgumentParser()
ap.add_argument("--registry", required=True)
ap.add_argument("--entry", required=True)
ap.add_argument("--model-dir", required=True)
ap.add_argument("--parent", type=int, default=os.getppid(), help="exit when this process is gone")
ap.add_argument("--memory-limit-gb", type=float, default=3.0)
ap.add_argument("--no-verify", action="store_true", help="skip the reference check (tests only)")
args = ap.parse_args()

LIMITS = {
    "max_line_bytes": 8 * 2**20,     # one request line
    "max_texts": 256,                # per request
    "max_text_chars": 200_000,       # per text (the tokenizer truncates to max_length anyway)
    "max_request_tokens": 262_144,   # after tokenization and truncation
    "max_queued": 64,                # requests waiting, both queues
    "max_queued_bytes": 64 * 2**20,  # their lines together
}
# Queries a document request serves at one batch boundary before it looks
# at its own deadline and cancel again.
INTERLEAVE = 8

out_lock = threading.Lock()


def send(obj: dict) -> None:
    line = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"
    with out_lock:
        protocol.write(line)
        protocol.flush()


def log(*a) -> None:
    print("[embed-runner]", *a, file=sys.stderr, flush=True)


def error(rid, code: str, message: str) -> None:
    send({"id": rid, "ok": False, "error": {"code": code, "message": message}})


def watchdog() -> None:
    # stdin EOF is the normal stop; this is for a parent that died holding the
    # pipe (a hung app, a grandparent that forked us). 0.1 s: the ADR's bound.
    while True:
        time.sleep(0.1)
        if os.getppid() != args.parent:
            os._exit(3)


threading.Thread(target=watchdog, daemon=True).start()

try:
    import mlx.core as mx
    import numpy as np

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from llmtray_embed.core import Embedder, load_entry

    mx.set_memory_limit(int(args.memory_limit_gb * 2**30))
    entry = load_entry(args.registry, args.entry)
    emb = Embedder(entry, args.model_dir)
except Exception as ex:  # noqa: BLE001
    send({"event": "fatal", "error": {"code": "load_failed", "message": f"{type(ex).__name__}: {ex}"}})
    sys.exit(1)

verify_min = None
if not args.no_verify:
    try:
        ref = entry["reference"]
        path = os.path.join(os.path.dirname(os.path.abspath(args.registry)), ref["file"])
        verify_min = emb.verify(path, ref["sha256"])
        ok = verify_min >= ref["min_cosine"]   # False for NaN too
    except Exception as ex:  # noqa: BLE001
        send({"event": "fatal", "error": {"code": "verify_failed", "message": f"{type(ex).__name__}: {ex}"}})
        sys.exit(1)
    if not ok:
        send({"event": "fatal", "error": {"code": "verify_failed",
              "message": f"reference check failed: min cosine {verify_min} < {entry['reference']['min_cosine']}"}})
        sys.exit(1)

# Two queues, queries first. The reader thread fills them; the main thread
# (the only one touching MLX) serves them.
cond = threading.Condition()
queries: "collections.deque[dict]" = collections.deque()
documents: "collections.deque[dict]" = collections.deque()
cancelled: set = set()
closing = threading.Event()


def reader() -> None:
    inp = sys.stdin.buffer
    while True:
        line = inp.readline(LIMITS["max_line_bytes"] + 1)
        if not line:
            break
        if len(line) > LIMITS["max_line_bytes"] and not line.endswith(b"\n"):
            while True:   # drain the rest of the oversized line
                more = inp.readline(1 << 20)
                if not more or more.endswith(b"\n"):
                    break
            error(None, "too_large", f"request line exceeds {LIMITS['max_line_bytes']} bytes")
            continue
        try:
            msg = json.loads(line)
            if not isinstance(msg, dict):
                raise ValueError
        except Exception:  # noqa: BLE001
            error(None, "bad_request", "not a JSON object line")
            continue
        op = msg.get("op", "embed")
        if op == "cancel":
            with cond:
                cancelled.add(str(msg.get("target")))
        elif op == "ping":
            with cond:
                n = len(queries) + len(documents)
            send({"id": msg.get("id"), "ok": True, "pong": True, "queue": n})
        elif op == "shutdown":
            break
        elif op == "embed":
            msg["_t"] = time.monotonic()
            msg["_bytes"] = len(line)
            with cond:
                waiting = list(queries) + list(documents)
                full = (len(waiting) >= LIMITS["max_queued"]
                        or sum(m["_bytes"] for m in waiting) + len(line) > LIMITS["max_queued_bytes"])
                if not full:
                    (queries if msg.get("kind") == "query" else documents).append(msg)
                    cond.notify()
            if full:
                error(msg.get("id"), "too_large", "the runner's queue is full")
        else:
            error(msg.get("id"), "bad_request", f"unknown op {op!r}")
    closing.set()
    with cond:
        cond.notify()


def take_query():
    with cond:
        return queries.popleft() if queries else None


def is_cancelled(rid) -> bool:
    with cond:
        if str(rid) in cancelled:
            cancelled.discard(str(rid))
            return True
    return False


def validate(msg: dict):
    """(texts, kind) or None after answering with the error."""
    rid = msg.get("id")
    if rid is None or not isinstance(rid, (str, int)):
        error(None, "bad_request", "a request needs an id")
        return None
    texts, kind = msg.get("texts"), msg.get("kind", "document")
    if kind not in ("query", "document") or not isinstance(texts, list) or not all(isinstance(t, str) for t in texts):
        error(rid, "bad_request", "texts must be a list of strings, kind query|document")
        return None
    if len(texts) > LIMITS["max_texts"]:
        error(rid, "too_large", f"more than {LIMITS['max_texts']} texts")
        return None
    if any(len(t) > LIMITS["max_text_chars"] for t in texts):
        error(rid, "too_large", f"a text exceeds {LIMITS['max_text_chars']} characters")
        return None
    timeout = msg.get("timeout_ms", 60_000)
    if not isinstance(timeout, (int, float)) or timeout <= 0:
        error(rid, "bad_request", "timeout_ms must be a positive number")
        return None
    return texts, kind


def handle(msg: dict, allow_interleave: bool) -> None:
    checked = validate(msg)
    if checked is None:
        return
    texts, kind = checked
    rid = msg["id"]
    deadline = msg["_t"] + msg.get("timeout_ms", 60_000) / 1000
    t0 = time.perf_counter()
    seqs = emb.encode_ids(texts, kind)
    ntok = sum(map(len, seqs))
    if ntok > LIMITS["max_request_tokens"]:
        return error(rid, "too_large", f"{ntok} tokens > {LIMITS['max_request_tokens']}")
    vecs = np.zeros((len(seqs), emb.dim), np.float16)
    done = 0
    for idx in emb.batches(seqs):
        # Queries that arrived meanwhile go first -- a bounded number, then
        # this request's own deadline and cancel are looked at again.
        for _ in range(INTERLEAVE if allow_interleave else 0):
            q = take_query()
            if q is None:
                break
            serve(q, allow_interleave=False)
        if is_cancelled(rid):
            return error(rid, "cancelled", "cancelled by the client")
        if closing.is_set():
            return error(rid, "cancelled", "the runner is shutting down")
        if time.monotonic() > deadline:
            return error(rid, "timeout", f"deadline passed after {done} of {len(seqs)} texts")
        vecs[idx] = emb.forward([seqs[j] for j in idx]).astype(np.float16)
        done += len(idx)
    is_cancelled(rid)   # a cancel that came too late is dropped
    if not np.isfinite(vecs).all():
        return error(rid, "internal", "the model produced non-finite values")
    send({"id": rid, "ok": True, "dim": int(vecs.shape[1]), "count": len(texts), "dtype": "f16",
          "vectors": base64.b64encode(vecs.astype("<f2").tobytes()).decode(),
          "tokens": [len(s) for s in seqs],
          "truncated": [k for k, s in enumerate(seqs) if len(s) >= emb.max_len],
          "ms": round((time.perf_counter() - t0) * 1000, 1)})


def serve(msg: dict, allow_interleave: bool = True) -> None:
    try:
        handle(msg, allow_interleave)
    except Exception as ex:  # noqa: BLE001
        error(msg.get("id"), "internal", f"{type(ex).__name__}: {ex}")


threading.Thread(target=reader, daemon=True).start()
send({"event": "ready", "protocol": 1, "entry": args.entry, "dim": emb.dim, "max_length": emb.max_len,
      "load_ms": round((time.perf_counter() - T_START) * 1000), "verify_min_cos": verify_min, "pid": os.getpid(),
      "limits": LIMITS})

while True:
    with cond:
        while not queries and not documents and not closing.is_set():
            cond.wait()
        if closing.is_set():
            pending = list(queries) + list(documents)
            queries.clear()
            documents.clear()
            msg = None
        else:
            msg = queries.popleft() if queries else documents.popleft()
            pending = []
    if msg is None:
        for m in pending:
            error(m.get("id"), "cancelled", "the runner is shutting down")
        break
    serve(msg)
    mx.clear_cache()   # hand freed buffers back: the chat model shares the GPU
log("stdin closed, exiting")
sys.exit(0)
