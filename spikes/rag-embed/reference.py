"""Reference vectors with the official stack (sentence-transformers / FlagEmbedding, torch, CPU fp32).

usage: python reference.py <registry.json> <entry id> <model_dir> <data_dir> <out.npz> [--flag] [--convert <dir>]
Runs on CPU so the GPU stays free for the chat model.
"""
import json
import os
import sys
import time

import numpy as np
import torch
from sentence_transformers import SentenceTransformer

reg, eid, mdir, data, out = sys.argv[1:6]
entry = {e["id"]: e for e in json.load(open(reg))["embedders"]}[eid]
torch.set_num_threads(8)
corpus = json.load(open(os.path.join(data, "corpus.json")))
retr = json.load(open(os.path.join(data, "retrieval.json")))
pre = entry.get("prefixes", {})

m = SentenceTransformer(mdir, device="cpu", model_kwargs={"torch_dtype": torch.float32})
m.max_seq_length = entry["tokenizer"]["max_length"]
print(m, flush=True)


def enc(texts, kind):
    res = []
    for t in texts:  # batch 1: no padding effects, bounded memory for 8k inputs
        res.append(m.encode([pre.get(kind, "") + t], normalize_embeddings=True, convert_to_numpy=True)[0])
    return np.stack(res).astype(np.float32)


t0 = time.time()
doc = enc([c["text"] for c in corpus], "document")
qry = enc([c["text"] for c in corpus], "query") if pre.get("query") else doc
rq = enc([q["q"] for q in retr["queries"]], "query")
rd = enc(retr["docs"], "document")
# token ids as seen by the reference tokenizer (for tokenizer parity)
ids = [m.tokenizer(pre.get("document", "") + c["text"], truncation=True, max_length=m.max_seq_length)["input_ids"] for c in corpus]
print(f"reference done in {time.time() - t0:.1f}s", flush=True)
extra = {}
if "--flag" in sys.argv:
    from FlagEmbedding import BGEM3FlagModel
    fm = BGEM3FlagModel(mdir, use_fp16=False, devices="cpu")
    fl = []
    for c in corpus:
        fl.append(fm.encode([c["text"]], max_length=8192, batch_size=1)["dense_vecs"][0])
    extra["flag"] = np.stack(fl).astype(np.float32)
    print("flag vs st min cos", float(np.min(np.sum(extra["flag"] * doc, 1))), flush=True)
np.savez(out, doc=doc, qry=qry, rq=rq, rd=rd, ids=np.array(json.dumps(ids)), **extra)

if "--convert" in sys.argv:
    # Own HF-layout safetensors (fp32) from the original checkpoint -> MLX loads it directly.
    from safetensors.torch import save_file
    import shutil
    cdir = sys.argv[sys.argv.index("--convert") + 1]
    os.makedirs(cdir, exist_ok=True)
    sd = {k: v.contiguous() for k, v in m[0].auto_model.state_dict().items()}
    save_file(sd, os.path.join(cdir, "model.safetensors"))
    for f in ("config.json", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"):
        if os.path.exists(os.path.join(mdir, f)):
            shutil.copy(os.path.join(mdir, f), cdir)
    print("converted ->", cdir, len(sd), "tensors")
