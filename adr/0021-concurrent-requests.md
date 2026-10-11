# 0021 — Concurrent requests: several clients on one model at once

**Status: accepted** (2026-10-11, asked for by the user: "сделать параллельные запросы").

## Why

LLMTray serves one model to several clients at once -- its own chat tabs,
a coding agent, curl. The proxy forwards their requests concurrently, but
the runtime served them strictly one after another in every usual setup:
`mlx_lm.server` batched a request only with no `--kv-bits` (the Default
profile has KV 8-bit), no draft model (the Gemma 4 26B drafter) and no
MTP-served request (the Qwen 3.5 heads). A second client waited for the
whole of the first one's answer. `decodeConcurrency` was inert too: the
launch left the flag out at 1, so the runtime's 32 applied, and the
runtime takes the larger of it and the prompt batch (8) anyway.

## Decision

**In the runtime** (mlx-lm fork, ipsupport-llc/mlx-lm#34):

- **Batching with a quantized KV cache** (`BatchQuantizedKVCache`): the
  batch stores full-attention layers' keys and values quantized like the
  unbatched path does, so batching costs no extra memory over it. Sliding
  window layers stay full precision in a batch (bounded by the window); a
  quantized one from the unbatched path is dequantized to join. A batch
  quantizes from the first token (no `quantized_kv_start`).
- **Speculation by load**: a request the unbatched path would serve with
  an MTP head or a draft model runs alone while it's alone -- the fastest
  for one stream -- and in the batch without speculation when others run
  or wait. A draft model no longer makes the model unbatchable.
- **Handoff**: a speculative request running alone moves into the batch
  as soon as another request arrives; the client sees one continuous
  answer. A trimmable cache gives back its last token, fed again; a
  recurrent one (Qwen 3.5 / Nemotron) goes on from the nearest stored
  entry (the turn's own checkpoints), the rest fed again.
  `--no-batch-handoff` keeps a speculative request alone to its end.
- Image and seeded requests still run alone (their embeddings / random
  state), and a stop string spanning the handoff's seam isn't matched.

**In LLMTray**:

- `--decode-concurrency N` and `--prompt-concurrency min(N, 8)` are always
  passed (1 included); a profile's own `--decode-concurrency` in extra
  arguments wins.
- **Concurrent requests**, default 4 (profile field `decodeConcurrency`,
  1...16), cut by the GPU memory beside the weights and the margin --
  every running request holds its own context: under 2 GB one, under 4 GB
  at most two (`ServerLaunch.concurrentRequests`). A Default still holding
  the old built-in 1 follows the new default once
  (`llmtray.migrated.concurrentRequests`); a 1 set after stays.
- The setting says what it does (one alone at full speed, drafting
  included; several share each step; memory).
- Auto-tune measures 1/2/4/8 at once for real now, and keeps the fewest
  that reach 90% of the best total speed (`AutoTune.concurrencyChoice`):
  more only add memory for a few percent.
- The model card shows how many requests run when more than one does.

## Measured (2026-10-11, M5 26 GB, FrogNano 4B, MTP head, KV 8-bit)

| At once | Total tok/s | Each tok/s | Worst first token |
|---|---|---|---|
| 1 (MTP) | 54.7 | 54.7 | 0.05 s |
| 2 | 63.4 | 33 | 0.27 s |
| 4 | 106.8 | 28 | 0.33 s |

Gemma 4 26B (GPTQ) with its assistant drafter, KV 8-bit: alone 42.9
tok/s (drafter); 2 at once 50.8 total; 4 at once 73.8 total (19.5 each),
worst first token 0.46 s.

A request arriving while another answered with the MTP head started in
0.87 s (the handoff and its catch-up included) instead of waiting for the
other's 300 tokens; both answers ran on together at 31-33 tok/s.

## Verification

- Runtime: `tests/test_batch_quantized_kv.py` (cache round trips,
  filter/extend, layers made ready, batched vs unbatched greedy tokens,
  history from the unbatched path joining a batch),
  `tests/test_server_handoff.py` (alone speculative, a second request
  moves the first into the batch, the answer continuous at the seam).
- LLMTray: launch arguments (1 said, the prompt batch capped, the memory
  cuts, extra arguments win), the Default's one-time migration, the
  auto-tune choice.
