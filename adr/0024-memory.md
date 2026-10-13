# 0024 — Memory: what LLMTray learns about the user between chats

**Status: proposed** (2026-10-12, asked for by the user: "after each session,
extract useful facts, stable user preferences, corrections and behavioral
observations ... inject relevant information into future sessions ... expire
old ones ... with config"). Revised after codex and muse reviews.

## Why

Every chat starts from zero. The user repeats who they are, what they work
on, how they want answers ("short, in Russian", "no invented charts"), and
corrects the same mistakes again. IPSupport Code has a reflection pass (its
ADR 0007). What we take from it:

- Reflection runs off the answer path and never delays it.
- A short prompt, enforcement in code. A long list of things not to write made
  models recite the list until the repetition guard cut them off.

What we do differently, because its weak spots show:

- It folds every fact into every prompt; we pick by relevance within a budget.
- Its facts carry no date and no evidence; ours carry both.
- An observation and what it supposedly means are one string there; here they
  are separate fields.
- Its only expiry is "last seen"; here every kind ages at its own rate.

The hard problem the user named: **the same thing must stay one note**. With
different models, and chats in different languages, a naive pass writes
"Prefers short answers", "Хочет краткие ответы" and "Answer length: brief" as
three notes. The design's core is the reconcile step below.

## Decision

### The note

One note is one claim, `text` at most 160 characters:

| Field | |
|---|---|
| `id` | stable (`m42`); a merge keeps the older id, the other becomes a redirect |
| `subject` | `user`, or `project:<project id>` (the id, never the name) |
| `topic` | a retrieval category from the topic list (`answer-length`, `hardware`, …). Several notes may share a topic |
| `kind` | `fact`, `preference`, `correction`, `observation` |
| `text` | the claim, in the memory language, with its condition if it has one ("Short answers for routine questions") |
| `observed` | for observations: what happened, kept apart from the reading in `text` |
| `evidence` | up to 5: chat id, message seq, date, quote (≤ 200 characters) |
| `created`, `confirmed` | first written; last confirmed by a chat |
| `confidence` | `stated` (the user said it) or `inferred` |
| `reviewed` | the user wrote, edited, pinned or approved it in Settings |
| `pinned` | never expires; reflection and tidy-up never change it |
| `history` | the last 3 replaced texts with dates (audit only, never injected) |

Kinds:

- **fact**: about the user or a project ("Builds an ESP32-S3 speaker with OTA updates").
- **preference**: how the user wants things. A preference is written only when
  the user stated it, or when an observation was confirmed in 2+ different
  chats on 2+ different days (promotion). Until then it stays an observation.
- **correction**: the user corrected the model ("Don't invent chart data").
- **observation**: what the user did (`observed`, with evidence) and, separately,
  what it may mean (`text`). Shown to the model as "observed: …; likely: …".

Notes never hold URLs, file paths, commands, hosts or anything shaped like a
key or password. The code refuses them, as IPSupport Code does for its lessons.
A note is about the person and their work, not a place to stash data.

### Evidence: provenance in code, support by the model

Every operation that changes memory (`add`, `confirm`, `update`, `supersede`,
`forget`) carries a quote. Two checks follow.

1. **Provenance (code).** The quote must be a substring (whitespace and case
   folded) of what the user **typed** in that chat: a user message's text, not
   its attachments, pasted documents (a paste over ~1,500 characters or inside
   a code fence), or a quoted block (`>`). Nothing is learned from the model's
   replies, tool results, web pages, project files or documents.
2. **Support (model).** Provenance doesn't make a claim true: "Translate 'I live
   in Berlin'" contains the quote but doesn't say where the user lives.
   Hypotheticals, negations and talk about other people pass a substring check
   too. So each surviving operation goes through a short verify call: "Does the
   quote, as the user's own statement, support this claim about <subject>?
   yes / no / unclear". Only `yes` is applied.

### Same thing, one note: reconcile

Embeddings only **find candidates**. They never decide that two notes are the
same: "prefers long answers" and "prefers short answers" can be close.

1. **One memory language.** A setting; default is the app's language. Reflection
   writes every `text` in it. The code checks with `NLLanguageRecognizer` only
   when the recognizer is confident (texts of 40+ characters, not mostly names or
   code). A mismatch is kept and marked for the tidy-up to rewrite; it's not dropped.
2. **Topics as categories.** Short English keys: the built-in set plus ones added
   over time. Reflection gets the list and reuses a topic when one fits. A new
   topic is an ordinary candidate for reconcile against the existing topic names.
   A wrong topic costs retrieval quality, not duplicates.
3. **Reflection edits, not appends.** The pass gets the notes it may touch, each
   with its id: candidates by embedding similarity to the batch's user messages
   (top 12), plus the notes in the same topics (up to 12). It answers with
   operations: `confirm(id)`, `update(id, text)`, `supersede(id, text)`,
   `add(scope, topic, kind, text, observed?)`, `forget(id)`, each with a quote.
   The code checks that every id exists, is not pinned, and is in a subject this
   chat may touch.
4. **Reconcile in code + one classify call.** Any operation that creates or
   changes text (an `add` or `update` from reflection, an edit or restore in
   Settings, a tidy-up merge) is first compared by embedding with active
   **and expired** notes of its subject. If the top candidates are within reach
   (similarity ≥ the candidate floor, about 0.6, calibrated by the eval), one
   classify call labels each pair: `same`, `opposite`, `narrower`, `different`.
   - `same`: confirm the existing note (an expired one comes back), add the evidence.
   - `opposite`: supersede the existing note.
   - `narrower` / `different`: a new note.

   Equivalence is the model's call on an explicit pair, never a threshold.

   **Without an embedder there is no memory.** Turning memory on asks to download
   bge-m3 (1.1 GB, multilingual, adr/0012), with the same consent as project files.
   Memory owns its own use of the embed runner, independent of the project-files
   toggle. `vectors.bin` records the embedder id and revision; a change re-embeds
   all notes in one transaction before memory is used again.
5. **Tidy-up.** Daily, when idle. It runs pairwise, not by cluster. It considers
   pairs of non-pinned notes in one subject whose similarity is at least the
   candidate floor and that haven't been classified since either changed. Same
   classify call; a `same` pair merges:
   - the older id survives;
   - the merged text is verified against the union of evidence;
   - `confirmed` is the latest of the two.

   It also rewrites notes marked as in the wrong language. Pinned notes are never
   merged or rewritten. A likely duplicate of a pinned note is shown in Settings
   as a suggestion.

### Scope

- A chat outside a project may write `user` notes only.
- A chat in project P may write `user` and `project:P` notes. The model gives
  `scope: user | project`, the code maps `project` to P. Facts about the work go
  to the project by default; `user` needs the claim to be about the person
  (tone, language, hardware, habits).
- Moving a chat to another project or deleting a project: below (snapshot,
  deletion).

### When reflection runs

- **Message ids.** Messages get a persistent sequence number in the chat file
  (`PersistedMessage.seq`, assigned once, kept across reloads). The watermark is a seq.
- **Trigger.** A chat goes quiet (no message for N minutes, default 10), the user
  switches away, or the app quits (queued, run on next launch). Before a chat is
  compacted, its unreflected user messages are copied into the queue entry. A
  summary is never evidence.
- **Never.** A temporary chat; a chat marked "Don't remember this chat"
  (checked again at commit time).
- **Batches.** Unreflected user messages are read in chronological batches of
  ~3k tokens, sized against the model's context with the candidates, topics,
  prompt and output room counted. The watermark advances only through the
  batch's last message, after its operations commit.
- **Commit.** Notes, vectors and the watermark are written in one journaled
  transaction with a batch id. A replay after a crash is a no-op.
- **Background admission.** Reflection, verify, classify and tidy-up are
  background work:
  - Admitted at the proxy with a background mark, only when no foreground
    request is running.
  - Bound to the loaded model and the server's epoch. It never loads or
    switches a model; if the model changed, it's dropped and retried later.
  - Any foreground request preempts it, from the chat or an external client:
    the proxy cancels the background request and waits for it to drain before
    forwarding.
  - Thinking off. One background job at a time.
- **Model.** The loaded one, or a profile's if that model is loaded.

### What goes into a chat

- **Never in a temporary chat** (no reads, no writes, no `used` stats). Never to
  external clients through the proxy: the block is added only in the in-app
  request builder.
- **A snapshot per chat.** The rendered memory block, its note ids and the memory
  generation, saved in the chat file. It's built at the chat's first request and
  reused as is, so the block (and, where nothing before it changes, the prompt
  prefix) stays the same for the KV cache. Rebuilt when:
  - the chat moves to another project;
  - the chat is compacted;
  - the model or profile changes and the block is over the new budget;
  - one of its notes is forgotten or memory is turned off (privacy beats the cache).
- **Position.** In `chatSystemPrompt`: after the profile's prompt, before the
  project's instructions and pinned files.
- **Choice.**
  - Pinned notes and `stated` preferences/corrections of `user` come first, up to
    half the budget, ordered by recency.
  - The rest by `similarity(first user message + project name) × weight × recency`,
    with `weight` 1.0 for stated, 0.6 for inferred.
  - A first message too short to rank by ("hi") ranks by `weight × recency`.
- **Budget.** In tokens via `PromptTokenEstimator`, the whole rendered block
  counted. Default 300, set in Settings; a profile may lower it. The block is
  also fitted into the request room after history, tools, pins and output
  allowance. When it doesn't fit, the lowest-ranked notes go first.
- **Rendering.** `text` and `observed` only. Never the evidence quotes. Framed as
  data: "What you know about the user from earlier chats. It may be outdated;
  what the user says now wins." Guesses are marked as guesses.
- **Shown.** A "Memory: 4 notes" chip; clicking lists them with "Forget" on each.

### Trust

Notes come only from the user's own typed words, are verified, and may not
hold URLs, paths, commands or secrets. So the proposal treats an injected
memory block as **user-derived, not as outside text**: it does not raise the
tool barrier (`ToolTrust`), which would switch off web search and folder
changes in every chat with memory.

**Open for the user:** whether unreviewed (learned, not `reviewed`) notes
should raise the barrier anyway. That's safer, but turns guarded tools off
whenever memory is on.

### Forgetting

- **Forget** (one note, or every note learned from one chat):
  - the note is deleted;
  - a tombstone (the text's embedding, its subject and the source quotes' hashes)
    stops reflection from writing it again from the same evidence;
  - the snapshots that held it are rebuilt;
  - the memory generation goes up, and a queued batch started under an older
    generation re-checks before commit.
- **Forget everything:**
  - deletes notes, vectors, the queue and tombstones;
  - raises the generation;
  - clears every chat's snapshot.
- **Deleting a chat** removes its evidence entries and queue items. A note left
  with no evidence from any other chat is deleted too, unless it's `reviewed`
  (setting: "Forget what was learned only from a deleted chat", default on).
- "Don't remember this chat" stops reflection for it and asks whether to forget
  what was already learned from it.
- Storage is plaintext in `~/Library/Application Support/LLMTray/memory/`
  (`notes.json`, `vectors.bin`, `queue.json`, `tombstones.json`), like chats.
  Local only.

### Expiry

- **Half-life.** Each kind has a half-life in days, set in Settings (defaults:
  observation 30, fact 90, preference 180, correction 180). A confirm restarts it.
- **Expired.** A note whose recency falls under 0.1 (about 3.3 half-lives):
  - no longer injected or offered to reflection;
  - still searched by reconcile, so a repeat brings it back rather than writing
    a duplicate;
  - shown under "Expired" in Settings;
  - deleted after N days (setting, default 30).
- **Cap.** At most 300 active notes (setting). Over it, the unpinned notes with
  the lowest `weight × recency` (query-independent) expire.
- **Pinned** notes never expire.

### Settings › Memory

- **Memory on/off.** Off by default (every LLMTray feature is opt-in). Turning it
  on downloads the embedder if needed, with consent. Off: nothing is injected or
  learned; notes are kept.
- **What to collect.** Facts / preferences / corrections / observations, a toggle
  each. A kind turned off is neither learned nor injected; its notes stay, shown
  dimmed. Promotion of an observation needs both observations and preferences on.
- **Budgets.** Injection budget (tokens), with a profile override (`Profile`
  gains an optional field; old profiles inherit). Max active notes.
- **Expiry.** Half-life per kind; delete expired after N days; forget what was
  learned only from deleted chats.
- **Memory language.** Auto = the app's language.
- **Reflection.** Idle minutes; model: the loaded one or a profile.
- **Project memory** on/off. Off: no `project:` notes learned or injected.
- **The notes.**
  - grouped by subject and topic, with evidence and dates;
  - edit, pin, approve (`reviewed`), forget;
  - "Expired" with restore;
  - tidy-up suggestions;
  - "Forget everything".
- **Per chat**, in its menu: "Don't remember this chat".

### Later (todo)

- **Temporary states** ("tired", "in a hurry", "ill"): a solvable problem, kept
  for later.
  - First version: reflection is told not to record them, and the topic list
    has no topic for them. Code can't reliably recognize a state in every
    language, so it doesn't pretend to.
  - Later: a `state` kind with a TTL in hours, never promoted, injected only
    while it lives.
- **A `remember` tool**: "запомни, что…" lands at once with a visible chip,
  instead of waiting for the pass.

## Order of work

1. **Store and settings.**
   - notes, reconcile store API, tombstones, expiry;
   - Settings › Memory with hand-written notes (no model involved yet);
   - snapshot and injection with budget and invalidation;
   - message seq in chat files.
2. **Background admission** at the proxy (preemption, epoch binding).
3. **Reflection pass.**
   - batches, provenance, verify, classify, commit journal;
   - queue and idle scheduling;
   - compaction hand-off.
4. **Tidy-up.**
5. **Project memory.**

## Testing

- **Unit.**
  - the store round-trip;
  - each operation, including unknown, pinned and out-of-scope ids;
  - provenance: a quote from the assistant, a tool result, an attachment, a long
    paste or a `>` block is refused;
  - reconcile with fixture vectors and classify replies (same, opposite, narrower);
  - expired notes coming back;
  - tombstones blocking a rewrite;
  - generation checks on commit;
  - decay and the cap;
  - injection order, budget and every snapshot invalidation;
  - temporary chats get no block;
  - the watermark only advancing through committed batches;
  - journal replay.
- **Calibration.**
  - Hard pairs across Russian and English: paraphrases, opposites, conditional
    variants, two different hardware facts.
  - Measured: bge-m3 similarity distributions, to set the candidate floor so
    real duplicates are always candidates.
  - Measured: the classify call's accuracy per model.
- **Reflection eval.**
  - Fixture chats in Russian and English, the same preferences said differently,
    with traps (translations, hypotheticals, other people's facts, pasted text).
  - Run through two different models.
  - Measured: notes per real fact (target 1.0), false merges (target 0), notes in
    the wrong language, claims the traps sneak in (target 0).
  - Runs on the user's Mac only on their command.

## Consequences

- Each pass costs several background calls (reflect, verify, classify). They
  never compete with a request, but on a busy server memory lags behind.
- What is learned is bounded by the model. Provenance, verify, reconcile and the
  Settings list limit the damage and let the user fix the rest.
- Memory needs the embedder: 1.1 GB on disk, and its runner's memory while it
  embeds.
- Chat files gain message seqs and a memory snapshot. Old chats get seqs on
  first load.
