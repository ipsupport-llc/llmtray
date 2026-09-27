"""Registry-driven embedder: one entry (JSON) -> tokenizer + MLX encoder + pooling.

Dependencies: mlx, numpy, tokenizers, safetensors-free (mx.load reads
safetensors). Everything model-specific comes from the registry entry.
"""
from __future__ import annotations

import glob
import hashlib
import json
import os
import time

import mlx.core as mx
import mlx.nn as nn
import numpy as np
from tokenizers import Tokenizer

from .gemma3_bidir import Gemma3BidirModel
from .xlmr import XLMRobertaModel

FAMILIES = {
    "xlm-roberta": XLMRobertaModel,
    "gemma3-bidir": Gemma3BidirModel,
}

DTYPES = {"float16": mx.float16, "bfloat16": mx.bfloat16, "float32": mx.float32}


class Embedder:
    def __init__(self, entry: dict, model_dir: str, dtype: str | None = None):
        t0 = time.perf_counter()
        self.entry = entry
        self.dir = model_dir
        cfg = json.load(open(os.path.join(model_dir, "config.json")))
        fam = FAMILIES[entry["family"]]
        self.model = fam(cfg)
        self.dtype = DTYPES[dtype or entry["weights"].get("compute_dtype", "float16")]

        files = sorted(glob.glob(os.path.join(model_dir, "model*.safetensors")))
        w = {}
        for f in files:
            w.update(mx.load(f))
        w = fam.sanitize(w)
        q = cfg.get("quantization") or entry["weights"].get("quantization")
        if q:
            # Quantize exactly the modules the checkpoint stores as quantized.
            nn.quantize(self.model, group_size=q["group_size"], bits=q["bits"],
                        class_predicate=lambda p, m: f"{p}.scales" in w)
        known = dict(nn.utils.tree_flatten(self.model.parameters()))
        missing = [k for k in known if k not in w]
        extra = [k for k in w if k not in known]
        if missing or extra:
            raise ValueError(f"weights mismatch: missing={missing[:5]} extra={extra[:5]}")
        # Float tensors (incl. quantization scales/biases) -> compute dtype; packed ints stay.
        w = {k: v.astype(self.dtype) if mx.issubdtype(v.dtype, mx.floating) else v for k, v in w.items()}
        self.model.load_weights(list(w.items()))
        # Optional sentence-transformers Dense heads (EmbeddingGemma).
        self.dense = []
        for d in entry.get("dense", []):
            dw = mx.load(os.path.join(model_dir, d["file"]))
            self.dense.append(dw["linear.weight"].astype(mx.float32))
        mx.eval(self.model.parameters(), self.dense)
        self.model.eval()

        tk = entry["tokenizer"]
        self.tok = Tokenizer.from_file(os.path.join(model_dir, tk.get("file", "tokenizer.json")))
        self.max_len = tk["max_length"]
        self.tok.enable_truncation(self.max_len)
        self.tok.no_padding()
        self.pad_id = tk["pad_id"]
        self.load_seconds = time.perf_counter() - t0

    # -- preprocessing -------------------------------------------------
    def prefix(self, kind: str) -> str:
        return self.entry.get("prefixes", {}).get(kind, "")

    def encode_ids(self, texts: list[str], kind: str) -> list[list[int]]:
        p = self.prefix(kind)
        return [e.ids for e in self.tok.encode_batch([p + t for t in texts])]

    # -- forward ---------------------------------------------------------
    def _forward(self, batch: list[list[int]]) -> mx.array:
        L = max(len(x) for x in batch)
        ids = np.full((len(batch), L), self.pad_id, dtype=np.int32)
        m = np.zeros((len(batch), L), dtype=np.int32)
        for i, x in enumerate(batch):
            ids[i, : len(x)] = x
            m[i, : len(x)] = 1
        padded = bool((m == 0).any())
        ids, m = mx.array(ids), mx.array(m)
        h = self.model(ids, m, padded)
        pool = self.entry["pooling"]
        if pool == "cls":
            v = h[:, 0].astype(mx.float32)
        elif pool == "mean":
            mf = m[..., None].astype(mx.float32)
            v = (h.astype(mx.float32) * mf).sum(1) / mf.sum(1)
        elif pool == "last":
            last = m.sum(1) - 1
            v = mx.take_along_axis(h, last[:, None, None], axis=1)[:, 0].astype(mx.float32)
        else:
            raise ValueError(pool)
        for W in self.dense:
            v = v @ W.T
        dim = self.entry.get("output_dim") or v.shape[-1]
        v = v[:, :dim]
        if self.entry.get("normalize", True):
            v = v / mx.maximum(mx.linalg.norm(v, axis=-1, keepdims=True), 1e-12)
        return v

    def embed_ids(self, seqs: list[list[int]], max_tokens: int | None = None, max_batch: int | None = None) -> np.ndarray:
        b = self.entry.get("batching", {})
        max_tokens = max_tokens or b.get("max_tokens_per_batch", 16384)
        max_batch = max_batch or b.get("max_batch", 32)
        order = sorted(range(len(seqs)), key=lambda i: -len(seqs[i]))
        out = [None] * len(seqs)
        i = 0
        while i < len(order):
            L = len(seqs[order[i]])  # longest first -> padded size of this batch
            n = max(1, min(max_batch, max_tokens // max(L, 1)))
            idx = order[i: i + n]
            v = self._forward([seqs[j] for j in idx])
            mx.eval(v)
            v = np.array(v)
            for k, j in enumerate(idx):
                out[j] = v[k]
            i += n
        return np.stack(out) if out else np.zeros((0, self.entry["dim"]), np.float32)

    def embed(self, texts: list[str], kind: str = "document", **kw) -> np.ndarray:
        return self.embed_ids(self.encode_ids(texts, kind), **kw)

    # -- load-time verification ------------------------------------------
    def verify(self, ref_path: str) -> float:
        """Embed the entry's reference texts, compare with stored vectors; return min cosine."""
        ref = json.load(open(ref_path))
        h = hashlib.sha256(json.dumps(ref["items"], ensure_ascii=False, sort_keys=True).encode()).hexdigest()
        want = self.entry["reference"]["sha256"]
        if h != want:
            raise ValueError(f"reference file checksum {h} != registry {want}")
        worst = 1.0
        for kind in ("query", "document"):
            items = [it for it in ref["items"] if it["kind"] == kind]
            if not items:
                continue
            got = self.embed([it["text"] for it in items], kind)
            for it, g in zip(items, got):
                r = np.frombuffer(bytes.fromhex(it["f16_hex"]), dtype=np.float16).astype(np.float32)
                c = float(g @ r / (np.linalg.norm(g) * np.linalg.norm(r)))
                if not np.isfinite(c):
                    return float("nan")  # min() would silently skip NaN
                worst = min(worst, c)
        return worst


def load_registry(path: str) -> dict:
    return {e["id"]: e for e in json.load(open(path))["embedders"]}
