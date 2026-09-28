# 0003 — Launch defaults and other lessons from live failures

- **Prompt cache capped at 1 GiB** (profile default). Uncapped, a long
  session's cross-request KV cache grew until a later request's own
  allocation hit Metal "Insufficient Memory".
- **...and capped by the GPU memory the model leaves.** The cached KV
  lives in GPU memory: a 17.8 GB model under the 19.1 GB default limit
  with a 4 GB profile cache ran a 20K-token prefill out of memory. The
  launch passes min(profile, (GPU limit − weights − 1.5 GB) / 2), 0 when
  nothing's left (a 0-byte cap in mlx_lm.server, not unlimited); the
  user's own `--prompt-cache-bytes` wins. A model leaving under 2.5 GB
  gets a notice with the `sysctl iogpu.wired_limit_mb` way to raise it.
- **Prompt cache holds 64 entries** (`--prompt-cache-size`; the user's
  own wins). The server's default of 10 sat full with an agent's parallel
  conversations, each request storing several checkpoints, and evicted
  useful ones; the byte cap is the real limit.
- **Prefill progress keeps a request alive.** On a swapping Mac 512 prompt
  tokens took up to 74 s with nothing on the wire, and the 60 s stall
  watchdog reset a request the server was still working on. "Prompt
  processing progress" / "Prefill step" log lines now count as activity
  for every in-flight request; no bytes *and* no progress still stalls.
- **KV quantization forced off for KV-shared models** (Gemma 4 E2B/E4B):
  they crash with quantized KV. Applied at every launch, including
  proxy-driven switches, which used to reuse the first start's KV bits.
- **Auto-start never falls back to another model.** After a Sparkle update
  the saved selection briefly didn't resolve (a startup timing race — it
  was intact seconds later) and a `?? first model` fallback silently loaded
  an unrelated 27B model. One short retry, then a visible error.
- **Chat continuations are tied to their conversation.** New chat / History
  stay enabled during a turn, and image generation and compaction are
  async; their results used to land in whatever conversation was on screen
  by then (a generated image and follow-up request in the *new* chat, an
  old compaction summary spliced into and saved with another session). A
  conversation epoch makes stale continuations drop their result.
- **Image generation unloads the chat model** (unless the profile says the
  Mac fits both): Z-Image Turbo alone peaked near 25 GB on a 24 GB Mac.
- **Tool calling is capped per turn** (one image, four rounds): small
  tool-calling models treat a tool result as "call it again" and loop.
