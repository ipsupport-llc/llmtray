# 0003 — Launch defaults and other lessons from live failures

- **Prompt cache capped at 1 GiB** (profile default). Uncapped, a long
  session's cross-request KV cache grew until a later request's own
  allocation hit Metal "Insufficient Memory".
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
