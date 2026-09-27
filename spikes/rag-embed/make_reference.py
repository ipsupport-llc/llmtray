"""Write reference/<entry>.json (a few texts + official f16 vectors) and put its sha256 into the registry.

usage: python make_reference.py <registry.json> <entry id> <data_dir> <ref.npz>
The runner re-embeds these texts at load (--verify) and requires cosine >= reference.min_cosine.
"""
import hashlib
import json
import os
import sys

import numpy as np

reg_path, eid, data, refp = sys.argv[1:5]
reg = json.load(open(reg_path))
corpus = json.load(open(os.path.join(data, "corpus.json")))
retr = json.load(open(os.path.join(data, "retrieval.json")))
ref = np.load(refp)
pick_docs = [8, 1, 16, 23, 26, 38]           # ru, en, mixed, code (short), ru 400-tok, code 400-tok
pick_q = [0, 3, 5]
items = [{"kind": "document", "text": corpus[i]["text"], "f16_hex": ref["doc"][i].astype("<f2").tobytes().hex()} for i in pick_docs]
items += [{"kind": "query", "text": retr["queries"][i]["q"], "f16_hex": ref["rq"][i].astype("<f2").tobytes().hex()} for i in pick_q]
sha = hashlib.sha256(json.dumps(items, ensure_ascii=False, sort_keys=True).encode()).hexdigest()
out = os.path.join(os.path.dirname(reg_path), "reference", f"{eid}.json")
os.makedirs(os.path.dirname(out), exist_ok=True)
json.dump({"entry": eid, "produced_by": "sentence-transformers, torch CPU float32", "items": items}, open(out, "w"), ensure_ascii=False)
for e in reg["embedders"]:
    if e["reference"]["file"] == f"reference/{eid}.json":
        e["reference"]["sha256"] = sha
json.dump(reg, open(reg_path, "w"), ensure_ascii=False, indent=2)
print(out, sha, os.path.getsize(out), "bytes")
