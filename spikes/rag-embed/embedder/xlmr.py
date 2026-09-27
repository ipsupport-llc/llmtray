"""XLM-RoBERTa encoder on plain MLX (bge-m3, multilingual-e5, USER-bge-m3, arctic-embed-l-v2).

Module names mirror the HF checkpoint keys (``embeddings.word_embeddings.weight``,
``encoder.layer.N.attention.self.query.weight``...), so an HF-layout safetensors
file (mlx-community conversions, or our own fp16/bf16 conversion) loads as-is.
Only ``mlx`` is needed.
"""
from __future__ import annotations

import math

import mlx.core as mx
import mlx.nn as nn


class Embeddings(nn.Module):
    def __init__(self, c: dict):
        super().__init__()
        h = c["hidden_size"]
        self.word_embeddings = nn.Embedding(c["vocab_size"], h)
        self.position_embeddings = nn.Embedding(c["max_position_embeddings"], h)
        self.token_type_embeddings = nn.Embedding(c.get("type_vocab_size", 1), h)
        self.LayerNorm = nn.LayerNorm(h, eps=c["layer_norm_eps"])
        self.pad = c.get("pad_token_id", 1)

    def __call__(self, ids: mx.array, mask: mx.array) -> mx.array:
        # RoBERTa positions: padding_idx + 1 + index among non-pad tokens.
        pos = mx.cumsum(mask, axis=1) * mask + self.pad
        x = self.word_embeddings(ids) + self.position_embeddings(pos)
        x = x + self.token_type_embeddings(mx.zeros_like(ids))
        return self.LayerNorm(x)


class SelfAttention(nn.Module):
    def __init__(self, c: dict):
        super().__init__()
        h = c["hidden_size"]
        self.n = c["num_attention_heads"]
        self.query = nn.Linear(h, h)
        self.key = nn.Linear(h, h)
        self.value = nn.Linear(h, h)


class DenseLN(nn.Module):
    def __init__(self, i: int, o: int, eps: float):
        super().__init__()
        self.dense = nn.Linear(i, o)
        self.LayerNorm = nn.LayerNorm(o, eps=eps)


class Attention(nn.Module):
    def __init__(self, c: dict):
        super().__init__()
        self.self = SelfAttention(c)
        self.output = DenseLN(c["hidden_size"], c["hidden_size"], c["layer_norm_eps"])


class Intermediate(nn.Module):
    def __init__(self, c: dict):
        super().__init__()
        self.dense = nn.Linear(c["hidden_size"], c["intermediate_size"])


class Layer(nn.Module):
    def __init__(self, c: dict):
        super().__init__()
        self.attention = Attention(c)
        self.intermediate = Intermediate(c)
        self.output = DenseLN(c["intermediate_size"], c["hidden_size"], c["layer_norm_eps"])

    def __call__(self, x: mx.array, attn_mask: mx.array) -> mx.array:
        B, L, H = x.shape
        sa = self.attention.self
        n = sa.n
        d = H // n
        q = sa.query(x).reshape(B, L, n, d).transpose(0, 2, 1, 3)
        k = sa.key(x).reshape(B, L, n, d).transpose(0, 2, 1, 3)
        v = sa.value(x).reshape(B, L, n, d).transpose(0, 2, 1, 3)
        a = mx.fast.scaled_dot_product_attention(q, k, v, scale=1.0 / math.sqrt(d), mask=attn_mask)
        a = a.transpose(0, 2, 1, 3).reshape(B, L, H)
        ao = self.attention.output
        x = ao.LayerNorm(x + ao.dense(a))
        h = nn.gelu(self.intermediate.dense(x))  # exact (erf) GELU, as HF "gelu"
        o = self.output
        return o.LayerNorm(x + o.dense(h))


class Encoder(nn.Module):
    def __init__(self, c: dict):
        super().__init__()
        self.layer = [Layer(c) for _ in range(c["num_hidden_layers"])]


class XLMRobertaModel(nn.Module):
    """Returns last hidden states (B, L, H). Pooling is done by the caller from config."""

    def __init__(self, c: dict):
        super().__init__()
        self.config = c
        self.embeddings = Embeddings(c)
        self.encoder = Encoder(c)

    def __call__(self, ids: mx.array, mask: mx.array, padded: bool = True) -> mx.array:
        x = self.embeddings(ids, mask)
        # (B, 1, 1, L) boolean key mask: padded keys never attended. Without padding
        # no mask at all: the unmasked SDPA path is ~20% faster on this M5.
        attn_mask = (mask[:, None, None, :] > 0) if padded else None
        for layer in self.encoder.layer:
            x = layer(x, attn_mask)
        return x

    @staticmethod
    def sanitize(weights: dict) -> dict:
        out = {}
        for k, v in weights.items():
            for p in ("roberta.", "model."):
                if k.startswith(p):
                    k = k[len(p):]
            if k.startswith("pooler.") or k.endswith("position_ids"):
                continue  # pooler head is unused by CLS/mean embedders
            out[k] = v
        return out
