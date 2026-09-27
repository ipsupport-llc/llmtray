"""Throughput / peak memory: ~400-token chunks at batch 1/8/16/32, and 8k-token inputs.

usage: python bench.py <registry.json> <entry id> <model_dir> <data_dir> [--dtype ..] [--json out]
"""
import argparse
import json
import os
import sys
import time

import mlx.core as mx

sys.path.insert(0, os.path.dirname(__file__))
from embedder.core import Embedder, load_registry  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("registry"); ap.add_argument("entry"); ap.add_argument("model_dir"); ap.add_argument("data")
ap.add_argument("--dtype"); ap.add_argument("--json"); ap.add_argument("--chunks", type=int, default=128)
ap.add_argument("--batches", default="1,8,16,32"); ap.add_argument("--long", type=int, default=8192)
a = ap.parse_args()
mx.set_memory_limit(3 * 2**30)

entry = load_registry(a.registry)[a.entry]
mx.reset_peak_memory()
e = Embedder(entry, a.model_dir, a.dtype)
weights_gb = mx.get_active_memory() / 2**30
corpus = json.load(open(os.path.join(a.data, "corpus.json")))
long_txt = "\n".join(c["text"] for c in corpus if c["tokens"] > 1500)
e.tok.no_truncation()  # the entry's truncation would cut the pool to max_length tokens
body = e.tok.encode(long_txt, add_special_tokens=False).ids
e.tok.enable_truncation(e.max_len)
assert len(body) >= a.chunks * 398, len(body)
cls, eos = e.encode_ids([""], "document")[0][:1], e.encode_ids([""], "document")[0][-1:]
chunks = [cls + body[i * 398:(i + 1) * 398] + eos for i in range(a.chunks)]
res = {"entry": a.entry, "dtype": str(e.dtype), "load_s": round(e.load_seconds, 2),
       "weights_gb": round(weights_gb, 3), "chunk_tokens": len(chunks[0]), "batch": {}}
e.embed_ids(chunks[:8], max_batch=8)  # warm-up (kernel compile)
for b in [int(x) for x in a.batches.split(",")]:
    mx.clear_cache(); mx.reset_peak_memory()
    n = len(chunks)  # same work for every batch size
    e.embed_ids(chunks[:b], max_batch=b, max_tokens=b * 400)  # warm this shape
    dts = []
    for _ in range(2):
        t0 = time.perf_counter()
        e.embed_ids(chunks, max_batch=b, max_tokens=b * 400)
        dts.append(time.perf_counter() - t0)
    dt = min(dts)
    res["batch"][b] = {"tok_s": round(n * len(chunks[0]) / dt), "chunks_s": round(n / dt, 1),
                       "peak_gb": round(mx.get_peak_memory() / 2**30, 3)}
    print(b, res["batch"][b], flush=True)
for L in (2048, 4096, a.long):
    L = min(L, e.max_len)
    seq = cls + body[: L - 2] + eos
    mx.clear_cache(); mx.reset_peak_memory()
    e.embed_ids([seq])  # warm
    t0 = time.perf_counter()
    reps = 3
    for _ in range(reps):
        e.embed_ids([seq])
    dt = (time.perf_counter() - t0) / reps
    res[f"single_{L}"] = {"tok_s": round(L / dt), "s": round(dt, 3), "peak_gb": round(mx.get_peak_memory() / 2**30, 3)}
    print(L, res[f"single_{L}"], flush=True)
print(json.dumps(res))
if a.json:
    with open(a.json, "a") as f:
        f.write(json.dumps(res) + "\n")
