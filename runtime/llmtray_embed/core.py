"""Registry-driven embedder: one runtime/embedders.json entry -> tokenizer,
MLX encoder, pooling (adr/0012, Dense retrieval).

Only mlx, numpy and tokenizers -- all in the app's mlx_server_venv already.
Everything model-specific comes from the entry, never from a model card
(mlx-community's card for bge-m3 says mean pooling; it is CLS).
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


def forbidden(entry: dict, config: dict | None = None) -> str | None:
    """What makes an entry or its config a Qwen model (never used: the
    user's rule), else None. The Swift registry checks the same names."""
    src = entry.get("source", {})
    names = [entry.get("id"), entry.get("display_name"), entry.get("family"), src.get("repo"), src.get("upstream")]
    if config is not None:
        names += [config.get("model_type"), config.get("_name_or_path")] + list(config.get("architectures") or [])
    for n in names:
        if isinstance(n, str) and "qwen" in n.lower():
            return n
    return None


def referenced_files(entry: dict) -> list[str]:
    """Every file read from the model folder by name: each must be pinned
    in source.files (sha-checked by the app after the download)."""
    return (["config.json", entry.get("tokenizer", {}).get("file", "tokenizer.json")]
            + [d["file"] for d in entry.get("dense", [])])


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


class Embedder:
    def __init__(self, entry: dict, model_dir: str):
        t0 = time.perf_counter()
        self.entry = entry
        family = FAMILIES.get(entry["family"])
        if family is None:
            raise ValueError(f"unknown family {entry['family']!r}")
        with open(os.path.join(model_dir, "config.json")) as f:
            cfg = json.load(f)
        bad = forbidden(entry, cfg)
        if bad:
            raise ValueError(f"a Qwen model is never used ({bad!r})")
        self.model = family(cfg)
        self.dtype = DTYPES[entry["weights"].get("compute_dtype", "float16")]

        weights = {}
        # Only the pinned weights: a stray model*.safetensors in the folder
        # was never sha-checked.
        pinned = entry["source"]["files"]
        files = sorted(p for p in glob.glob(os.path.join(model_dir, "model*.safetensors"))
                       if os.path.basename(p) in pinned)
        if not files:
            raise FileNotFoundError("no pinned model*.safetensors in the model folder")
        for path in files:
            weights.update(mx.load(path))
        weights = family.sanitize(weights)
        q = entry["weights"].get("quantization") or cfg.get("quantization")
        if q:
            # Quantize exactly the modules the checkpoint stores as quantized.
            nn.quantize(self.model, group_size=q["group_size"], bits=q["bits"],
                        class_predicate=lambda p, m: f"{p}.scales" in weights)
        known = dict(nn.utils.tree_flatten(self.model.parameters()))
        missing = [k for k in known if k not in weights]
        extra = [k for k in weights if k not in known]
        if missing or extra:
            raise ValueError(f"weights don't match the family: missing={missing[:5]} extra={extra[:5]}")
        # Floats (quantization scales too) to the compute dtype; packed ints stay.
        weights = {k: v.astype(self.dtype) if mx.issubdtype(v.dtype, mx.floating) else v for k, v in weights.items()}
        self.model.load_weights(list(weights.items()))
        # Optional sentence-transformers Dense heads (EmbeddingGemma).
        self.dense = [mx.load(os.path.join(model_dir, d["file"]))["linear.weight"].astype(mx.float32)
                      for d in entry.get("dense", [])]
        mx.eval(self.model.parameters(), self.dense)
        self.model.eval()

        tk = entry["tokenizer"]
        self.tok = Tokenizer.from_file(os.path.join(model_dir, tk.get("file", "tokenizer.json")))
        self.max_len = tk["max_length"]
        self.tok.enable_truncation(self.max_len)
        self.tok.no_padding()
        self.pad_id = tk["pad_id"]
        b = entry.get("batching", {})
        self.max_tokens_per_batch = b.get("max_tokens_per_batch", 4096)
        self.max_batch = b.get("max_batch", 16)
        self.dim = entry.get("output_dim") or entry["dim"]
        self.load_seconds = time.perf_counter() - t0

    def encode_ids(self, texts: list[str], kind: str) -> list[list[int]]:
        prefix = self.entry.get("prefixes", {}).get(kind, "")
        return [e.ids for e in self.tok.encode_batch([prefix + t for t in texts])]

    def batches(self, seqs: list[list[int]]) -> list[list[int]]:
        """Index groups, longest first, each <= max_tokens_per_batch once
        padded (a longer text alone): the boundaries where cancel and
        timeouts act."""
        order = sorted(range(len(seqs)), key=lambda i: -len(seqs[i]))
        out, i = [], 0
        while i < len(order):
            longest = max(len(seqs[order[i]]), 1)
            n = max(1, min(self.max_batch, self.max_tokens_per_batch // longest))
            out.append(order[i:i + n])
            i += n
        return out

    def forward(self, batch: list[list[int]]) -> np.ndarray:
        L = max(len(x) for x in batch)
        ids = np.full((len(batch), L), self.pad_id, dtype=np.int32)
        mask = np.zeros((len(batch), L), dtype=np.int32)
        for i, x in enumerate(batch):
            ids[i, :len(x)] = x
            mask[i, :len(x)] = 1
        padded = bool((mask == 0).any())
        ids, mask = mx.array(ids), mx.array(mask)
        h = self.model(ids, mask, padded)
        pool = self.entry["pooling"]
        if pool == "cls":
            v = h[:, 0].astype(mx.float32)
        elif pool == "mean":
            m = mask[..., None].astype(mx.float32)
            v = (h.astype(mx.float32) * m).sum(1) / m.sum(1)
        elif pool == "last":
            last = mask.sum(1) - 1
            v = mx.take_along_axis(h, last[:, None, None], axis=1)[:, 0].astype(mx.float32)
        else:
            raise ValueError(f"unknown pooling {pool!r}")
        for W in self.dense:
            v = v @ W.T
        v = v[:, :self.dim]
        if self.entry.get("normalize", True):
            v = v / mx.maximum(mx.linalg.norm(v, axis=-1, keepdims=True), 1e-12)
        mx.eval(v)
        return np.array(v)

    def embed(self, texts: list[str], kind: str = "document") -> np.ndarray:
        seqs = self.encode_ids(texts, kind)
        out = np.zeros((len(seqs), self.dim), np.float32)
        for idx in self.batches(seqs):
            out[idx] = self.forward([seqs[j] for j in idx])
        return out

    def verify(self, reference_path: str, sha256: str) -> float:
        """Re-embeds the entry's reference texts and returns the lowest cosine
        against the stored vectors -- NaN if any is not finite (EmbeddingGemma
        overflows in fp16), so `>= min_cosine` fails for it."""
        if sha256_file(reference_path) != sha256:
            raise ValueError("reference vectors don't match the registry's checksum")
        with open(reference_path) as f:
            items = json.load(f)["items"]
        worst = 1.0
        for kind in ("query", "document"):
            chosen = [it for it in items if it["kind"] == kind]
            if not chosen:
                continue
            got = self.embed([it["text"] for it in chosen], kind)
            for it, g in zip(chosen, got):
                r = np.frombuffer(bytes.fromhex(it["f16_hex"]), dtype="<f2").astype(np.float32)
                c = float(g @ r / (np.linalg.norm(g) * np.linalg.norm(r)))
                if not np.isfinite(c):
                    return float("nan")   # min() would skip a NaN
                worst = min(worst, c)
        return worst


def load_entry(registry_path: str, entry_id: str) -> dict:
    with open(registry_path) as f:
        registry = json.load(f)
    for entry in registry["embedders"]:
        if entry["id"] == entry_id:
            bad = forbidden(entry)
            if bad:
                raise ValueError(f"a Qwen model is never used ({bad!r})")
            pinned = entry.get("source", {}).get("files", {})
            unpinned = [f for f in referenced_files(entry) if f not in pinned]
            if unpinned:
                raise ValueError(f"files not pinned in source.files: {unpinned}")
            return entry
    raise KeyError(f"no embedder {entry_id!r} in the registry")
