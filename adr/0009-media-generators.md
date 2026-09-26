# 0009 — Image and music generators

## Decision

- **A Python runner per generator, as a subprocess.** Images run
  `runtime/llmtray_mflux_runner.py` (mflux), music
  `runtime/llmtray_music_runner.py` (mlx-audio, see
  [0010](0010-music-ace-step.md)), started per generation by
  `MfluxManager` / `MusicManager` through `ProcessRunner.runStreaming`.
  Each has its own venv under `RuntimePaths.externalRuntimeDir`
  (`mflux_venv`, `music_venv`), outside the bundle for the same reason as
  the server's ([0001](0001-mlx-runtime.md)), and apart from the server's
  venv: each stack pulls its own tokenizer / transformers dependencies.
- **Everything in memory.** The request goes in on stdin, the result
  comes back on stdout as `@@LLMTRAY <KIND> <data>` lines, parsed by
  `LLMTrayCore.MfluxRunnerMessage` (`STEP`, `PREVIEW`, `IMAGE`, base64 PNG)
  and `MusicRunnerMessage` (`STAGE`, `SEED`, `STEP`, `AUDIO`, base64 WAV).
  No file is written, not even a temporary one: a temporary chat must
  leave no trace. A saved chat writes its media (`.png`, `.m4a` — older songs `.wav`) with the
  session; one whose media file failed to write stays unsaved rather than
  listing a missing file (23d5342, eb18dc0).
- **Models are set up from Settings only**, never mid-chat (that would
  write files from a temporary chat): the download is confirmed, goes to
  `<dir>.partial-<uuid>` and is moved into place when complete, so a
  folder that exists is a finished one. Runs use `HF_HUB_OFFLINE=1`.
- **The chat model is unloaded around a generation** unless the profile
  says the Mac fits both — the why is in [0003](0003-field-lessons.md).
- **One generator at a time, app-wide:** `LLMTrayCore.GenerationQueue`.

## Image models (`ImageGenModel`)

Published pre-quantized checkpoints, downloaded as-is (no on-device
quantization pass, unlike mflux's own `--quantize`):

- Z-Image Turbo, GPTQ (quant-ternary `zimage-quant`):
  `roman220220/z-image-turbo-gptq-mlx-{8bit,4bit,mixed}`; mixed (attention
  8-bit, feed-forward 4-bit) is the recommended one. 9 steps.
- FLUX.2 klein 4B, `roman220220/flux2-klein-4b-mlx-mixed` (quant-ternary
  `flux2-quant`): transformer GPTQ 4-bit, text encoder 8-bit, ~5.3GB.
  4 steps. The only model with `supportsEditing`, so the only choice for
  the separate edit model that `edit_image` uses.

`edit_image` (`EditImageTool`) takes a 1-based `index` over every image
in the chat, attached and generated, and runs klein at the source's
aspect ratio (`LLMTrayCore.EditCanvas`).

## Rules

- **The protocol has its own fd.** The mflux runner dups fd 1 for the
  protocol and points fd 1 and `sys.stdout` at stderr (8573fab): anything
  mflux or native code prints can't land inside a protocol line. The music
  runner swaps `sys.stdout` for a `StringIO` while mlx-audio runs.
- **In memory replaced file polling.** Previews used to be mflux's stepwise
  PNGs, read while still being written: top rows, black below (9b349c0).
  bd92ccc moved to the streamed runner.
- **The prompt is on stdin**, not in the arguments `ps` shows.
- **mflux is pinned** (`MfluxManager.mfluxVersion`, 0.20.0): the runner
  drives its internals (in-memory model, callbacks). A venv from before
  the pin is brought to it (version read from the dist-info folder,
  53ea7d7); a mismatched one refuses to generate. mlx-audio is pinned to a
  commit (`MusicManager.mlxAudioCommit`). The mflux venv is never vendored
  into a DMG: opencv-python in it bundles GPL codecs.
- **klein's memory:** the text encoder is cut to its first 27 layers (only
  hidden states 9, 18, 27 condition the image: bit-identical output,
  ~1GB less), the VAE decodes in 256 px tiles, and the preview's x0 is
  cast back to the latents' dtype (a float32 decode peaked ~0.6GB higher,
  49c2afd). A preview never fails a run.
- **Orphans are stopped at launch.** Runners carry `LLMTRAY_IMAGE_RUNNER`
  / `LLMTRAY_MUSIC_RUNNER` in their environment; `OrphanScan` stops one
  whose app crashed (6027ac4) — it holds its model's memory.
- **No unload for a call that won't run** (refused, turned off, an empty
  edit instruction, a model not set up): `willGenerate` is checked first
  (498097c, ff5b656, 5f06a89, 23d5342). For images it checks the venv, the
  pinned mflux and the checkpoint (`MfluxManager.isReady`): before, a
  missing image model was refused only after the chat model's unload.

## The queue and the proxy

- `GenerationQueue.acquire` waits in order instead of refusing a second
  chat (1006782). It polls rather than holding continuations, so a
  waiter that stops caring (Stop, a chat switch) just leaves.
- **The ticket is released after the chat model is reloaded** (the
  `defer` is declared before the reload): the next in line starts from a
  loaded model. A turn stopped after its grant hands the ticket back
  (1c2ee41), or the queue would stay taken.
- A granted turn also waits for `MfluxManager` / `MusicManager.isBusy` —
  a Settings download holds the generator too (1c2ee41).
- `ServerManager.unloadModel()` sets `suspendedForImageGeneration` and
  drains in-flight requests first. `acquireModel` then waits (outside the
  serialized transition, up to 15 min, Stop ends it) instead of failing,
  and retries a request that got in line just as the unload happened
  (error code 7) — another tab's answer, or the holder's own follow-up,
  used to fail there (1c2ee41). `ensureModelLoaded()` clears the flag.
