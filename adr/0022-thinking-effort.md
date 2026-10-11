# 0022 — Thinking effort: Off, Low, Medium, High in the composer

**Status: accepted** (2026-10-11, asked for by the user, "as ChatGPT has it").

## Decision

A thinking model gets a picker in the composer, next to Send: **Off,
Low, Medium, High**. One setting for every chat (`Pref.thinkingEffort`),
High until changed -- as long as the model takes, what every chat did
before. A model that doesn't think shows no picker.

- **What a model offers** is read from its chat template
  (`chat_template.jinja`, else `tokenizer_config.json`'s
  `chat_template`), `Thinking.style`:
  - `reasoning_effort` in it (gpt-oss): its own **levels** -- the
    request's `chat_template_kwargs.reasoning_effort` low / medium /
    high; Off is low (it has no off).
  - `enable_thinking`, `<think>`, `<|channel>` or `<|think` (Qwen 3.5,
    Gemma 4, Nemotron, LFM2.5 Thinking): a **budget** -- Off is
    `enable_thinking: false` and `thinking_budget: 0` (a template that
    thinks regardless is closed at once); Low and Medium are
    `thinking_budget` 512 and 2048 tokens; High sends nothing.
  - Anything else: none.
- **The budget is the server's** (fork ipsupport-llc/mlx-lm#39): the
  request's `thinking_budget` counts the tokens generated in the
  reasoning state; at the budget the server stops the generation, writes
  "I have to answer now." and the model's own close (`</think>`,
  `<channel|>`), and goes on with a new request of the prompt, the tokens
  so far and the close. Not a logits processor: those turn off MTP and
  draft speculation in the server, and the speed of Gemma 4 26B with its
  drafter is the point. The prompt's prefix comes from the prompt cache.
  Never past `max_tokens`, never inside a close the model is writing
  itself, a token that ends the response at the boundary ends it; not for
  image requests (the carry-on would need the images' features). The
  Anthropic endpoint maps `thinking.budget_tokens` to it, so Claude Code's
  budget applies too.
- **In-app requests only** for now: the proxy forwards an external
  client's body as it is (it may send `thinking_budget` itself). A
  profile field for external clients is a later step if wanted.
- The app's own one-shot requests (a title, a compaction summary) keep
  `enable_thinking: false` as before.

## Verification

- LLMTrayCore: `Thinking.style` from templates (none, budget, levels),
  `requestFields` for every style and effort.
- Fork: the carry-on with a mocked generator (reasoning text, the carried
  prompt, remaining `max_tokens`, usage of the request's own prompt), zero,
  no room for the close, a stop at the boundary, a partial close, bad
  values refused.
- By hand: Gemma 4 26B with its drafter at Low answers after about 512
  reasoning tokens with MTP still on (the speed line); Off on Qwen 3.5
  thinks not at all; a model without thinking shows no picker.
