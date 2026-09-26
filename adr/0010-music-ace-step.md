# 0010 — Music: ACE-Step 1.5 through mlx-audio

## Decision

`generate_music` runs ACE-Step 1.5 (MIT) through mlx-audio, pinned to a
commit of its `pc/add-ace` branch (`MusicManager.mlxAudioCommit`,
installed from a GitHub tarball: no git needed on the Mac). The runner,
`runtime/llmtray_music_runner.py`, has two modes, picked by `MusicModel`:

| `MusicModel` | DiT (HF) | planner | steps |
|---|---|---|---|
| `turbo` | `mlx-community/ACE-Step1.5-MLX-4bit` | LM 1.7B | 8 |
| `sft8bit` | `roman220220/ACE-Step1.5-sft-MLX-8bit` | none | 50 |
| `sftGPTQ4` | `roman220220/ACE-Step1.5-sft-MLX-gptq-4bit` | none | 50 |
| `sftBF16` | `roman220220/ACE-Step1.5-sft-MLX-bf16` | none | 50 |

The LM planner is the `acestep-5Hz-lm-1.7B` folder of the official
`ACE-Step/Ace-Step1.5` repo, downloaded only for turbo.

Two trade-offs, not a ranking: turbo's mix sounds fuller and more
finished; sft sings the lyrics far more clearly with the voice upfront.
Settings offers sft 8-bit first (by ear the same as bf16, c18d361), GPTQ
4-bit for a Mac short of memory.

Measurements: [acestep-quant FINDINGS][findings] (M5, 3 songs x 4 seeds,
Whisper WER against the requested lyrics, capped at 1 per track).

## Why

- **The planner prompt is reimplemented.** mlx-audio sends one user
  message with `# Instruction … # Lyrics … # Metas`; the LM was trained on
  a system instruction plus `# Caption / # Lyric`, metadata as YAML in
  `<think>`. With mlx-audio's layout the LM planned a ~3-minute song for a
  30 s request, and the clip was the instrumental intro: mean WER 0.94.
  `plan()` follows the official pipeline — CoT first (the requested
  duration and language replace the LM's), then codes only, CFG against
  `NO USER INPUT`, stopped at duration x 5 codes: WER 0.56, against 0.66
  for the official turbo pipeline, ~22 s vs 68-85 s per track.
- **sft has no planner.** Fed mlx-audio's LM hints, the sft DiT produced
  cacophony (no music, no words). Without them, with the official sft
  sampling — CFG 7 with APG on every step, shift 1 — it sings: mean WER
  0.22 (bf16), 0.24 (8-bit), 0.29 (GPTQ 4-bit), at ~36-49 s per track.
- **`null_condition_emb`, not zeros.** mlx-audio's unconditional CFG
  branch encodes all-zero text; the official one uses the trained
  embedding. `NullAwareEncoder` swaps it in for sft: WER 0.22 vs 0.28.

## Rules

- **Knobs** (profile defaults `musicCreativity` 0.42, `musicAdherence`
  0.5; the model may also pass them per call), in the runner's constants:
  - creativity -> `LM_TEMPERATURE = 0.6 + 0.6c` (0.85 at the default, the
    official value). turbo only: sft has no planner, so the draft disables
    it (`MusicModel.hasCreativity`).
  - adherence -> `LM_CFG = 1 + 2a` (turbo, 2.0 at the default) and
    `DIT_CFG = 3 + 8a` (sft, 7.0 at the default).
- **Codes 0-63999 only.** The tokenizer also has `<|audio_code_64000…|>`,
  which the FSQ can't represent; a malformed CoT YAML (an unquoted colon)
  falls back to the known `key: value` lines.
- **The LM's checkpoint keys lack mlx-lm's `model.` prefix**: `load_lm`
  remaps them, as the official loader does.
- **LM freed before the DiT loads**: the cache is capped
  (`mx.set_cache_limit(1 << 30)`) before planning, and the LM deleted and
  `mx.clear_cache()` called after it, else mlx keeps the freed buffers.
- **Chunked VAE decode**, 250 frames (10 s) with 16 frames of overlap:
  bit-identical to a whole decode, peak 5.35 vs 9.55 GB for 30 s, and no
  longer growing with the length.
- **Kept as AAC, not the runner's WAV**: `LLMTrayCore.AudioCodec` encodes
  it in memory (AudioToolbox file callbacks over a buffer, so a temporary
  chat still writes nothing), off the main actor. A 30 s song: 5.76 MB
  WAV → 0.99 MB at 256 kbit/s, 0.13 s; 120 s in ~0.7 s. The profile's
  `musicBitrate` picks 128-320 kbit/s or WAV. Songs saved before stay WAV;
  file names take their extension from the sniffed format (PR #86).
- **`SEED <n>`** is emitted before generating; `MusicManager.Song.seed`
  carries it. The request can pass a seed back, but no caller does today:
  Regenerate and Tweak make a variant with a new seed
  ([0011](0011-creator-mode-and-media-variants.md)).
- Two quantization save bugs were caught only by listening (tracks with
  no music and no words): a dropped text-encoder file and encoder keys
  renamed by the null-cond wrapper. Listen to a new checkpoint once;
  WER measures the words only, not timbre or mix.

[findings]: https://github.com/rromenskyi/quant-ternary/blob/main/acestep-quant/docs/FINDINGS.md
