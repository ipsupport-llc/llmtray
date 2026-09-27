# RAG spike 3/3: the embedder (throwaway)

For [ADR 0012](../../adr/0012-project-files-rag.md). Measured on the M5 (26 GB,
Metal limit 19.07 GB), macOS 27.2, mlx 0.32.2 (the app venv's version), Python 3.14.
Raw numbers are in `results/`; `run_all.sh` reproduces them.

## What is here

- `embedder/` — a registry-driven embedder on plain `mlx` + `tokenizers` + `numpy`
  (all already in the app's `mlx_server_venv`; no new dependency):
  `xlmr.py` (XLM-RoBERTa: bge-m3, multilingual-e5, USER-bge-m3, arctic-embed-l-v2),
  `gemma3_bidir.py` (bidirectional Gemma 3: EmbeddingGemma), `core.py` (loading,
  quantized checkpoints, prefixes, pooling cls/mean/last, Dense heads, normalization,
  token-budget batching, load-time reference check).
- `registry.json` + `reference/<id>.json` — the entry format and reference vectors.
- `runner.py` — the JSON-lines runner; `client_test.py` — the client-side test.
- `reference.py` (torch venv: sentence-transformers, FlagEmbedding), `parity.py`,
  `bench.py`, `make_corpus.py` (52 texts: ru/en/mixed/code, 3 to 12k tokens, and a
  16-doc / 12-query ru+en retrieval set), `make_reference.py`.

## Results (short)

| variant | min cos | mean cos | retrieval vs reference |
|---|---|---|---|
| bge-m3, mlx-community fp16, fp16 compute | 0.99998 | 0.999996 | top-1 12/12, top-3 sets 12/12, Spearman 1.0 |
| bge-m3, fp32 compute | 0.99994 | 0.99999 | identical |
| bge-m3, bf16 compute | 0.99917 | 0.99976 | top-1 12/12, Spearman 0.9985 |
| bge-m3 8-bit (mlx-community) | 0.99905 | 0.99967 | top-1 12/12, top-3 12/12 |
| bge-m3 4-bit (mlx-community) | **0.915** | 0.952 | top-3 9/12 — rejected |
| multilingual-e5-large-instruct fp16 | 0.999998 | 0.999999 | identical |
| EmbeddingGemma-300m fp32 / bf16 | 0.999998 / 0.99975 | | identical / top-3 11/12 |
| EmbeddingGemma-300m fp16 | NaN (overflow) | | the load check refuses it |

Reference: sentence-transformers 6.1 on CPU fp32 (transformers 5.17, torch 2.14);
FlagEmbedding `BGEM3FlagModel` dense agrees with it to 0.9999998.

bge-m3 fp16 throughput (400-token chunks): ~8-9.4k tokens/s at batch 1-32 (flat:
compute-bound from batch 1); 2k tokens 0.26 s, 4k 0.67 s, 8k 1.85 s (4.4k tok/s).
Peak 1.33-1.72 GB (weights 1.1 GB). 8-bit: 7.3-8.4k tok/s (slower), peak 0.75-1.26 GB.
Load 0.4-0.8 s warm; runner spawn -> first vector 0.76 s (page cache warm).
EmbeddingGemma bf16: ~16k tok/s, peak 1.47 GB; e5 fp16: ~10k tok/s.

Findings worth keeping:
- the BAAI `tokenizer.json` (old serialization) read with `tokenizers` differs from
  transformers 5 on trailing whitespace (an extra `▁` before `</s>`); the mlx-community
  `tokenizer.json` matches. Pin the tokenizer file by hash.
- mlx-community's model card shows *mean* pooling for bge-m3 — wrong, it is CLS.
- EmbeddingGemma's sliding window is `512 // 2 + 1 = 257` in each direction
  (transformers' bidirectional rule); with 512 the vectors drift to 0.988 past ~250
  tokens. The load check with a 400-token reference text catches it.
- `mlx-embeddings` would pull mlx-vlm, mlx-audio, opencv, scipy, fastapi, … (36
  packages) into the app venv for ~150 lines of model code.
