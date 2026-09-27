"""MLX vs reference: per-text cosine, token-id parity, retrieval ranking agreement.

usage: python parity.py <registry.json> <entry id> <model_dir> <data_dir> <ref.npz> [--dtype float16|bfloat16|float32] [--json out]
"""
import argparse
import json
import os
import sys
import time

import mlx.core as mx
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from embedder.core import Embedder, load_registry  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("registry"); ap.add_argument("entry"); ap.add_argument("model_dir")
ap.add_argument("data"); ap.add_argument("ref")
ap.add_argument("--dtype"); ap.add_argument("--json"); ap.add_argument("--label")
a = ap.parse_args()

mx.set_memory_limit(3 * 2**30)  # stay well under the chat model's share
entry = load_registry(a.registry)[a.entry]
e = Embedder(entry, a.model_dir, a.dtype)
ref = np.load(a.ref)
corpus = json.load(open(os.path.join(a.data, "corpus.json")))
retr = json.load(open(os.path.join(a.data, "retrieval.json")))

# tokenizer parity
ref_ids = json.loads(str(ref["ids"]))
my_ids = e.encode_ids([c["text"] for c in corpus], "document")
tok_mismatch = [i for i, (x, y) in enumerate(zip(ref_ids, my_ids)) if x != y]

mx.reset_peak_memory()
t0 = time.perf_counter()
doc = e.embed([c["text"] for c in corpus], "document")
dt = time.perf_counter() - t0
cos = np.sum(doc * ref["doc"], 1) / (np.linalg.norm(doc, axis=1) * np.linalg.norm(ref["doc"], axis=1))
rows = [{"id": c["id"], "lang": c["lang"], "tokens": c["tokens"], "cos": round(float(x), 6)} for c, x in zip(corpus, cos)]

rq, rd = e.embed([q["q"] for q in retr["queries"]], "query"), e.embed(retr["docs"], "document")
S, R = rq @ rd.T, ref["rq"] @ ref["rd"].T
top1 = np.mean(S.argmax(1) == R.argmax(1))
top3 = np.mean([set(np.argsort(-s)[:3]) == set(np.argsort(-r)[:3]) for s, r in zip(S, R)])
# Spearman rank correlation per query
def rank(x):
    r = np.empty_like(x); r[np.argsort(x)] = np.arange(len(x)); return r
sp = np.mean([np.corrcoef(rank(s), rank(r))[0, 1] for s, r in zip(S, R)])
hit_ref = np.mean([r.argmax() in q["rel"] for r, q in zip(R, retr["queries"])])
hit_mlx = np.mean([s.argmax() in q["rel"] for s, q in zip(S, retr["queries"])])
by = {}
for r in rows:
    k = "long(>1500)" if r["tokens"] > 1500 else r["lang"]
    by.setdefault(k, []).append(r["cos"])
res = {
    "label": a.label or f"{a.entry}:{e.dtype}",
    "entry": a.entry, "model_dir": os.path.basename(a.model_dir.rstrip("/")), "dtype": str(e.dtype),
    "load_s": round(e.load_seconds, 2), "embed_s": round(dt, 2), "peak_gb": round(mx.get_peak_memory() / 2**30, 3),
    "tokenizer_mismatches": tok_mismatch,
    "cos_min": round(float(cos.min()), 6), "cos_mean": round(float(cos.mean()), 6),
    "cos_min_by_group": {k: round(min(v), 6) for k, v in by.items()},
    "retrieval": {"top1_agree": float(top1), "top3_set_agree": float(top3), "spearman_mean": round(float(sp), 5),
                  "max_abs_score_diff": round(float(np.abs(S - R).max()), 5),
                  "hit@1_ref": float(hit_ref), "hit@1_mlx": float(hit_mlx)},
    "worst": sorted(rows, key=lambda r: r["cos"])[:3],
}
print(json.dumps(res, ensure_ascii=False))
if a.json:
    with open(a.json, "a") as f:
        f.write(json.dumps(res, ensure_ascii=False) + "\n")
