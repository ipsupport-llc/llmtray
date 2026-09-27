"""Bidirectional Gemma 3 text encoder on plain MLX (EmbeddingGemma-300m).

Mirrors transformers' Gemma3TextModel with use_bidirectional_attention=True:
full layers attend to every non-pad token, sliding layers to |i-j| < window.
The sentence-transformers Dense heads (2_Dense, 3_Dense) are loaded by the
caller as ``dense.N.weight`` and applied after pooling.
"""
from __future__ import annotations

import mlx.core as mx
import mlx.nn as nn


class RMSNorm(nn.Module):
    def __init__(self, dim: int, eps: float):
        super().__init__()
        self.weight = mx.zeros((dim,))
        self.eps = eps

    def __call__(self, x):
        # Gemma: x * (1 + w), computed in fp32.
        return mx.fast.rms_norm(x.astype(mx.float32), 1.0 + self.weight.astype(mx.float32), self.eps).astype(x.dtype)


class Attention(nn.Module):
    def __init__(self, c: dict, sliding: bool):
        super().__init__()
        h, self.nh, self.nkv, self.hd = c["hidden_size"], c["num_attention_heads"], c["num_key_value_heads"], c["head_dim"]
        self.q_proj = nn.Linear(h, self.nh * self.hd, bias=False)
        self.k_proj = nn.Linear(h, self.nkv * self.hd, bias=False)
        self.v_proj = nn.Linear(h, self.nkv * self.hd, bias=False)
        self.o_proj = nn.Linear(self.nh * self.hd, h, bias=False)
        self.q_norm = RMSNorm(self.hd, c["rms_norm_eps"])
        self.k_norm = RMSNorm(self.hd, c["rms_norm_eps"])
        self.scale = c["query_pre_attn_scalar"] ** -0.5
        self.sliding = sliding
        base = c.get("rope_local_base_freq", 10000.0) if sliding else c.get("rope_theta", 1e6)
        self.rope = nn.RoPE(self.hd, traditional=False, base=base)

    def __call__(self, x, mask):
        B, L, _ = x.shape
        q = self.q_norm(self.q_proj(x).reshape(B, L, self.nh, self.hd)).transpose(0, 2, 1, 3)
        k = self.k_norm(self.k_proj(x).reshape(B, L, self.nkv, self.hd)).transpose(0, 2, 1, 3)
        v = self.v_proj(x).reshape(B, L, self.nkv, self.hd).transpose(0, 2, 1, 3)
        q, k = self.rope(q), self.rope(k)
        o = mx.fast.scaled_dot_product_attention(q, k, v, scale=self.scale, mask=mask)
        return self.o_proj(o.transpose(0, 2, 1, 3).reshape(B, L, -1))


class MLP(nn.Module):
    def __init__(self, c: dict):
        super().__init__()
        h, i = c["hidden_size"], c["intermediate_size"]
        self.gate_proj = nn.Linear(h, i, bias=False)
        self.up_proj = nn.Linear(h, i, bias=False)
        self.down_proj = nn.Linear(i, h, bias=False)

    def __call__(self, x):
        return self.down_proj(nn.gelu_approx(self.gate_proj(x)) * self.up_proj(x))


class Layer(nn.Module):
    def __init__(self, c: dict, sliding: bool):
        super().__init__()
        e = c["rms_norm_eps"]
        self.sliding = sliding
        self.self_attn = Attention(c, sliding)
        self.mlp = MLP(c)
        self.input_layernorm = RMSNorm(c["hidden_size"], e)
        self.post_attention_layernorm = RMSNorm(c["hidden_size"], e)
        self.pre_feedforward_layernorm = RMSNorm(c["hidden_size"], e)
        self.post_feedforward_layernorm = RMSNorm(c["hidden_size"], e)

    def __call__(self, x, mask):
        x = x + self.post_attention_layernorm(self.self_attn(self.input_layernorm(x), mask))
        return x + self.post_feedforward_layernorm(self.mlp(self.pre_feedforward_layernorm(x)))


class Gemma3BidirModel(nn.Module):
    def __init__(self, c: dict):
        super().__init__()
        self.config = c
        self.embed_tokens = nn.Embedding(c["vocab_size"], c["hidden_size"])
        types = c.get("layer_types") or [
            "full_attention" if (i + 1) % c.get("_sliding_window_pattern", 6) == 0 else "sliding_attention"
            for i in range(c["num_hidden_layers"])
        ]
        self.layers = [Layer(c, t == "sliding_attention") for t in types]
        self.norm = RMSNorm(c["hidden_size"], c["rms_norm_eps"])
        # transformers' Gemma3TextConfig: with bidirectional attention the window is
        # split around the token, sliding_window // 2 + 1 (512 -> 257), |i - j| < 257.
        sw = c["sliding_window"]
        self.window = sw // 2 + 1 if c.get("use_bidirectional_attention") else sw

    def __call__(self, ids, mask, padded: bool = True):
        x = self.embed_tokens(ids)
        # HF casts sqrt(hidden) to the weight dtype before multiplying.
        x = x * mx.array(self.config["hidden_size"] ** 0.5, dtype=x.dtype)
        L = ids.shape[1]
        keys = mask[:, None, None, :] > 0 if padded else mx.array(True)
        full = keys if padded else None
        sliding = full
        if L > self.window:
            i = mx.arange(L)
            band = mx.abs(i[:, None] - i[None, :]) < self.window
            sliding = keys & band[None, None] if padded else band
        for layer in self.layers:
            x = layer(x, sliding if layer.sliding else full)
        return self.norm(x)

    @staticmethod
    def sanitize(weights: dict) -> dict:
        out = {}
        for k, v in weights.items():
            if k.startswith("model."):
                k = k[len("model."):]
            out[k] = v
        return out
