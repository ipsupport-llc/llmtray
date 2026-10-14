# 0025 — Apple's on-device model: memory's reader and a chat model, nothing to download

**Status: proposed** (2026-10-14, asked for by the user: "connect the local
model, if it's there, and for choosing in the main models menu too"; earlier:
"bring it everywhere, including memory -- works without downloading models at
all"; its point: "it runs on the ANE").

## Why

Every model LLMTray runs is a folder of MLX weights the user downloads (GBs,
over Starlink for some), loaded by `mlx_lm.server` on the GPU. macOS 26+ ships
a ~3B language model with the system (Apple Intelligence, the
`FoundationModels` framework):

- nothing to download or load, no Python, no extra process;
- it runs on the Neural Engine, not the GPU: it doesn't compete with the MLX
  model, image or music generation, and costs little power;
- guided generation: a reply that follows a schema, never broken JSON;
- on this Mac (macOS 27.2, M5): available with no entitlement or key once
  Apple Intelligence is on; context 8192 tokens; streaming; token counting.

Its limits: small (about E4B's league, maybe below); 8K context; the languages
Apple lists (24) don't include Russian or Ukrainian -- it answers in Russian
anyway, but nothing is promised; only on Macs with Apple Intelligence on.

A first probe of memory's triage on it (the user's real traps, in Russian): 6
of 8 right, the same three runs out of three, 1-2 s each; misses: "depression"
labelled mood (code filters it anyway), a swearing message labelled none.

## Decision

### The model, as LLMTray sees it

- One built-in model, **"Apple (on this Mac)"**, listed when
  `SystemLanguageModel.default.availability` is `.available`; when Apple
  Intelligence is off or the Mac can't run it, Settings says why (Apple's
  reason) instead of listing it. Never `PrivateCloudComputeLanguageModel`:
  that's Apple's cloud, and LLMTray is local-only.
- Its id is a fixed non-path (`apple-system`); `ModelCatalog` adds it beside
  the folders; nothing on disk, nothing to delete or download. Capabilities:
  no thinking, no vision and no tools in the first version, context from
  `contextSize`.
- Apple's guardrails stay as they are (`.default`); LLMTray never tries to get
  round them (Apple's acceptable-use requirements).

### Part A: memory's reader (first)

- Settings › Memory › "Reads chats with" gains **Apple (on this Mac)**. Chosen,
  `MemoryReflector.ask` calls the model in-process (one `LanguageModelSession`
  per call, instructions = the step's system prompt), not the proxy: no
  background admission, no waiting for the GPU, no model to load, the user's
  model untouched. It can read while a chat answers.
- Everything after the reply (provenance, verify, reconcile, commit) is as
  before; the steps' replies are text parsed as today (guided generation is a
  later step if the eval asks for it).
- The memory eval (`MemoryLiveEval`, sets 1-4) gains an in-process Apple run;
  the option ships only if it keeps every trap out.

### Part A as built: Apple sorts, the reading model reads (2026-10-14)

The eval (`MemoryLiveEval`, sets 1-5, `MEMORY_EVAL_MODEL=apple-system` and
`MEMORY_EVAL_SORTER=apple-system`) settled it:

- **As the reader, no.** With guided generation every reply parses, and the
  traps stay out -- but it misses most of what's there ("short, in Russian",
  "concrete versions", "no invented charts"), its own verify rejects right
  confirms across languages, and it makes things up ("Give concrete answers"
  from the chart sentence). Not offered in Settings (a setting made in a test
  build still works).
- **As the sorter, yes -- a gate only.** Settings › Memory › "Sorts messages
  with": the reading model, or Apple (on this Mac). Apple answers one question
  per message, "does it tell anything about the user?" (yes/no, "when unsure,
  yes"), on the Neural Engine, before the reading model is needed: a batch of
  only "no" is done there -- no model loaded, no GPU. A batch with a "yes" goes
  to the reading model, which sorts it itself (Apple's six-way labels mixed
  kinds up: a wish labelled a fact). Eval: every batch with something in it
  kept (sets 1-4, both runs); 2 of 3 chats of plain questions done by Apple
  (set 5). It catches manner and complaints less well, so "when unsure, yes"
  errs toward reading.
- Guided generation: `ReplyShape` (labels as one field per message -- an
  array of them didn't keep the count; ops with ids limited to the notes shown;
  mood; verdicts and relations), turned into the JSON the parsers read.

### Part B: a chat model in the menus

- The model is in the popover picker, the tray's Select Model and Settings ›
  Models like the others. Choosing it doesn't start `mlx_lm.server`: the MLX
  model is unloaded (as a switch does today) and the proxy runs alone,
  answering this model's requests itself.
- The proxy turns an OpenAI `chat.completions` request into a `Transcript`
  (system → instructions, user/assistant turns → prompts and responses; the
  last user message is the prompt) and streams the reply back as OpenAI SSE
  chunks (`delta.content`, `finish_reason`, `usage` from `tokenCount`, `[DONE]`),
  so `ChatClient`, titles, compaction and memory work unchanged.
- **Only LLMTray's own chat and memory** get it: a request without the app
  token naming it is refused (Apple's terms make LLMTray answerable for what
  others do with it; external API access may come later as an opt-in).
- Not in the first version: tools (Apple's tools are called by the framework;
  bridging them to the chat's tool loop is its own step), images, thinking.
  The chat's tool and image controls are off for this model, as for a model
  without them.
- Requests that don't fit 8K (a long chat) are compacted as today; one that
  still doesn't fit fails with the model's "context exceeded" as an error the
  chat shows.

### What the review added (codex, muse, 2026-10-14)

- **A model has a source.** `LocalModel` gains `source: .folder(path) |
  .appleSystem`; `id == path` stays true for folders only. The Apple id
  `apple-system` is reserved (an alias can't take it). Everything that walks a
  folder -- `resolve`'s config.json check, sizes, weights, `remove`, `fit`,
  `ModelCapabilities` -- skips it; its context is `contextSize`
  (`ChatSettings.maxContext` must return it, not the 32768 default). It lives
  in `catalog.models`, so a selection of it stays valid. Part A needs this
  identity too.
- **A listener without a process.** `ServerManager` gets an explicit Apple
  state: the proxy listener starts on its own (bind success = running; bind
  failure = failed), no runtime install, no `mlx_lm.server`; Stop closes it.
  Switching both ways stays serialized and drains requests. Idle unload,
  image/voice suspension and stall restarts don't apply to Apple (it doesn't
  hold the GPU): it stays answerable during media work, and nothing reloads
  MLX for it.
- **The proxy answers Apple first.** In `route()`, before `beginRequest` /
  `acquireModel` / switch logic: the effective target (named, by alias, or
  the current model when `model` is omitted) is resolved; Apple without the
  app token → 403 before anything else moves; Apple with it → the in-process
  handler. `routeBackground` dispatches Apple too. `/v1/models` lists Apple
  only to the app (by token).
- **Streaming and not.** SSE for chats and memory; a plain JSON completion
  (`choices[0].message.content`, `finish_reason`, `usage`) for titles and
  compaction (`stream: false`). `finish_reason` and `[DONE]` always (memory's
  `StreamedContent` treats their absence as preempted); `usage` from
  `tokenCount` when it can.
- **Errors.** Before the stream: OpenAI-shaped HTTP errors (unavailable 503,
  context exceeded 400 `context_length_exceeded`, guardrail refusal 400
  `content_refused`). During it: an `error` chunk then `[DONE]`, and
  `SSEDecoder`/`ChatClient` learn to show it instead of treating a clean close
  as success. Memory maps a refusal to `failed` (counted, dropped after 3),
  unavailability to `later`.
- **Its own deadline.** No MLX watchdog: a generation gets a timeout (no first
  token in 60 s, no progress in 60 s) and is cancelled; a client disconnect
  cancels it; request accounting is released exactly once.
- **Bounded concurrency.** One `LanguageModelSession` per request, never shared;
  at most one Apple generation at a time, foreground first (a memory call
  waits for a chat's, and is cancelled by one, as at the proxy today).
- **Fitting 8K.** The request is budgeted before it's sent: instructions
  (profile, memory block, project text), history and the reply's room within
  `contextSize` (input and output share it). Oldest turns are dropped first
  with a note to the model, as the chat's own trimming does; compaction's
  summary request is fitted the same way.
- **Old chats into a Transcript.** Several system messages join into the
  instructions; tool calls and tool results become plain text turns ("[tool
  result: …]") or are left out past the budget; content parts keep their text,
  images and audio drop; empty assistant turns drop; the last user message is
  the prompt (not also in the history). Tool and file text stays in turns,
  never in instructions.
- **Availability is live.** Checked at launch, when Settings opens, and on
  every request; an Apple reader for memory that becomes unavailable waits
  (`later`), it isn't swapped for another model.
- **Claims to keep honest.** ANE-only, power and 8192 are what this Mac shows;
  the eval records the OS and model version, and re-runs on an OS update.
- **First run.** The wizard offers "Use Apple's model (nothing to download)"
  when it's available.

### Availability### Availability

`#if canImport(FoundationModels)` and `if #available(macOS 26, *)` around all
of it: the app still runs on macOS 14+, the model is simply not offered there.
The App Store flavor gets it too (no runtime to bundle, no process to sandbox).

## Order of work

1. Shared Apple adapter: availability, Transcript conversion, budgeting,
   streaming/non-streaming, error and timeout policy (unit-tested).
2. Part A: model source and reader identity; memory's `reader`/`runQueue`
   paths for Apple; in-process ask; full memory eval; ships when clean.
3. Part B: listener-only lifecycle; the proxy's Apple handler and gate;
   `SSEDecoder` errors; pickers, cards, first-run wizard.
3. Later, separately: tools bridge, images, guided generation for triage,
   external API opt-in.

## Testing

- Unit: OpenAI messages → Transcript entries; cumulative snapshots → SSE
  deltas; the app-token gate; capability flags; unavailable → not listed.
- Live (the user's Mac): memory eval sets 1-4 with Apple as reader; a chat in
  Russian and English through the popover; switching Apple ↔ an MLX model and
  back; memory reading during a chat.

## Consequences

- LLMTray does something useful with no model downloaded at all.
- Memory stops competing with the user's model for the GPU when Apple reads.
- The 8K context and missing tools make it a light model: the UI says so, the
  big models stay the default for real work.
