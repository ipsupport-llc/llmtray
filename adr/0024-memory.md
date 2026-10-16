# 0024 — Memory: what LLMTray learns about the user between chats

**Status: accepted** (2026-10-12, asked for by the user: "after each session,
extract useful facts, stable user preferences, corrections and behavioral
observations ... inject relevant information into future sessions ... expire
old ones ... with config"; the plan approved by the user the same day after
two codex and muse review rounds).

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
   too. So each surviving operation goes through a short verify call that sees
   the **whole user message** with the quote marked in it, and the assistant
   message before it for context: "Does the user, speaking for themselves, say
   this about <subject>? yes / no / unclear". Only `yes` is applied.

### Lasting, not a log (revised 2026-10-13 after the first real use)

Reading a real history ("Learn from Past Chats Now") gave a log of requests,
not a picture of the person: "User asked for the definition of rdma",
"requested an image of an ocean planet", and, from a test of the image
generator ("now imagine it on LSD, now on alcohol"), "is testing the
boundaries of the AI". So:

- **Lasting only.** The prompt asks for what would still be true and useful in
  an unrelated chat a month later (role, ongoing work, tools, stack, how they
  want answers); a question or a thing asked for (an explanation, code, an
  image, a story) is not a fact about the user, nor a creative or test prompt.
  The verify call answers "no" for those too.
- **Never learned:** health, drugs or alcohol, sex, religion, politics, money,
  legal matters -- even said outright; the user can write them in About you.
  Checked by the model (reflect, verify) and in code (`MemoryText.unlearnable`:
  word stems in English, Russian, Ukrainian, and one-off phrasings like "User
  asked ...").
- **No motives.** No guess at why the user asked something. An observation is
  only about how to answer them (topics tone, answer-length, formatting,
  reply-language, code-style).
- **A candidate first.** A learned fact or observation is sent once this many
  chats showed it (Settings, default 2), or the user approved it; reflection
  still sees it, so a second chat confirms it rather than adding it again.
  Preferences and corrections the user stated go at once.
- **At most 4 new notes per batch,** what the user asked for first.
- **Starting over:** "Forget What Was Learned…" removes every learned note the
  user didn't write, edit, pin or approve (no tombstones: better rules may learn
  them again) and the queue; "and read all chats again" also forgets where each
  chat was read, then queues them all.

### Targeted steps (revised 2026-10-14, the user's call: "a pointed prompt, not a general one")

One general reflect prompt had to judge everything at once -- what matters,
which kind, confirm or add, manner, what's off limits -- and every rule added
moved the others (more caution lost the confirms; a rule about complaints folded
"short, in Russian" into "concrete versions"). A batch is now read in narrow
steps (`MemoryExtraction`), each with only the messages and notes it needs; the
operations they give go through provenance, verify, reconcile and commit as
before.

1. **Triage.** One call labels each message (one line each, "2: about-me"):
   `how-to-answer` (how they want answers, a complaint, a correction),
   `about-me` (something lasting about them or their work), `forget`, `manner`
   (the words show how they talk), `mood` (a strong feeling now), `none`
   (questions, tasks, content requests, creative or test prompts, other
   people, sensitive topics). Most batches end here.
2. **Instructions**: the `how-to-answer` messages, with the preference and
   correction notes. One note per wish; a complaint is a wish for the opposite;
   an "update" of a wish becomes an add (a small model used it to fold two
   wishes together), and reconcile confirms it if it's the same.
3. **Facts**: the `about-me` messages, with the fact notes.
4. **Forget**: the `forget` messages, with the candidates.
5. **Manner**: only when two messages are labelled `manner` (one more confirms
   a manner noted before), with every manner note; an add needs two quotes from
   two of those messages, checked in code; the same "observed" as a note there
   confirms it.
6. **Mood**: below.

Code holds each step to its kind and its notes' ids. A confirm whose quote
isn't the user's words (a model copying the note into it) takes the step's one
message as its quote; verify still judges the claim against the whole message,
and for a confirm asks whether the message says again at least part of the note,
in any language. Texts this close in meaning (cosine >= 0.95) are the same,
whatever classify says. Steps see only what the user typed (no code, quotes or
pastes). Live eval (`MemoryLiveEval`, sets 1-4): Gemma 4 26B gives the expected
notes run after run; E4B keeps every trap out, its misses are safe (a confirm
not made, so a note waits).

**Lasting check (2026-10-16, after the user's past chats were read).** The
steps were told "a task is no note", and E4B still turned "add tests" and
"make it shorter, just a list" (about the answer just given) into wishes and
"we are the buyer in this contract" into a fact; a line saying so in the
instructions step made Gemma 4 26B drop "for this project use PlatformIO".
So after verify, each new or changed preference, correction or fact gets one
more narrow question, one call per note (asked about two, E4B answered once):
the user's message, the assistant's answer before it and the note -- `task`
(steers the work at hand, redoes one answer, a detail of this task, asked once)
or `lasting` (how answers should be from now on, a fact that stays true, a
wish for a whole project, a complaint that answers keep being some way).
Anything but `lasting` drops the note. Live eval, sets 1-5 (set 5 now holds
the contract chat from the user's queue), twice each: 26B identical and
complete, every task dropped; E4B drops every task, its one miss is safe ("vague
again, be concrete" kept as the mood, not a wish).

### Mood (2026-10-14, the user: "mood is a short-lived metric")

How the user seems right now -- angry at a failing build, tired, in a hurry --
is not a note. Triage labels `mood` messages; a step reads the last few of them
said within the setting's hours (default 3, 0: off) and writes what it shows and
how to answer now ("Angry: the linker keeps failing" / "Brief, straight to the
fix"). The newest one is kept (`MemoryFile.mood`), from the message's time;
new chats get a line "Right now (from the user's last messages, a guess): ...",
at most half the budget; a chat whose block holds a mood that ran out chooses
its block again. Sensitive topics never become a mood: a message about one isn't read for
it at all ("I've been depressed for weeks" gave E4B a mood). Reading past chats gives
none (their hours are gone). Settings shows the mood now, with Forget; forgetting
a chat's lessons, everything, or what was learned drops it.

### Settings: privacy and the exact block

Settings › Memory starts with a privacy note: memory stays on this Mac, is
never uploaded or shared, and goes only into the prompt of LLMTray's own chats
(not to API clients, not temporary chats). "Show What Chats Get…" shows the
exact block a new chat gets now (outside projects, or a project's), chosen by
the same code a chat uses, with its size.

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
   **and expired** notes of its subject. A change to an existing note (an
   `update`, an edit, a restore) excludes that note from its own candidates
   and keeps its id; the requested text is applied, and if it comes out
   `same` as another note, the two merge (the older id survives). If the top candidates are within reach
   (similarity ≥ the candidate floor, about 0.6, calibrated by the eval), one
   classify call labels each pair: `same`, `opposite`, `narrower`, `broader` (the new one says less than the old), `different`.
   - `same` or `broader`: confirm the existing note (an expired one comes back), add the evidence.
   - `opposite`: supersede the existing note.
   - `narrower` / `different`: a new note.

   Equivalence is the model's call on an explicit pair, never a threshold.
   An `update` from reflection is also compared with its own note: if it says
   less (`broader`), it's a confirm -- found in the first live run, where a
   small model turned "short answers, in Russian" into "short answers".
   The store enforces pinned immutability after reconcile: an outcome that
   would confirm-in-place is fine, one that would supersede, merge or rewrite a
   pinned note becomes a suggestion in Settings instead.

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

### Scope: where a note is seen

(Revised 2026-10-13 with the user: "project X remembers facts inside project
X, project Z sees only what the user set about themselves -- or a switch to
see everything everywhere".)

A note is seen in every chat (`user`), in chats outside projects (`general`),
or in one project's chats (`project:P`).

- **By default learning is kept apart.** What a project's chats teach is
  `project:P` and seen only there; what chats outside projects teach is
  `general` and seen only there. The code assigns it; the model doesn't choose.
  What the user writes (About you, notes for all chats) is `user`, seen
  everywhere.
- **"Learned from chats: Shared by all chats"** (Settings; the default is
  "Stays in its project"): every chat
  sees every note, and the model gives `scope: user | project` in a project's
  chats, so facts about the person stay apart from the work's.
- Kept apart, a batch writes only its own place: it's shown only those notes
  to change, and the write checks it again with the settings as they are then.
  A new note is still compared with everything the chat sees (About you
  included), so the same thing confirms what it can't change and adds
  nothing; one contradicting a note it can't change is its own place's.
- A `user` note learned while sharing was on and never approved is seen,
  once sharing is off, only in chats outside projects; one the user wrote or
  approved is seen everywhere.
- "Remember in projects" off: nothing is learned in a project's chats, shared or not,
  and no project note is sent.
- A chat's block is chosen again when the settings it depends on change
  (sharing, project notes, kinds, the budget), not only its notes.
- A note's visibility can be changed in Settings (All chats / Chats outside
  projects / a project's chats).
- Moving a chat to another project: its snapshot is rebuilt (below).
- Deleting a project deletes its `project:` notes, drops queued batches for it,
  and rejects any in-flight write to its id at commit. Its chats (which project
  deletion keeps) lose those notes from their snapshots.

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
- **Model.** (Revised 2026-10-13 with the user: a chat written in Russian with
  Gemma mustn't be read by a coding or English-only model loaded later.) A
  batch remembers the model that answered in its chat, and by default that
  model reads it. Settings can name one model for every chat instead (only
  models of ~3B and up are offered; one whose card doesn't list the notes'
  language gets a warning). A batch waits until its model is loaded and free;
  the first batch the loaded model may read goes first. Memory loads a model
  itself only if the user allows it ("Load it itself" after N idle minutes,
  off by default), never from a stop, never while anything runs.
- **Manner, not mood.** How the user tends to talk (polite, curt, swears when
  something breaks) may be kept as an observation under `tone` when several
  messages show it; a passing mood never is (temporary states stay a todo).

### What goes into a chat

- **Never in a temporary chat** (no reads, no writes, no `used` stats). Never to
  external clients through the proxy: the block is added only in the in-app
  request builder.
- **A snapshot per chat.** The rendered memory block, its note ids and the memory
  generation, saved in the chat file. It's built at the chat's first request and
  reused as is, so the block (and, where nothing before it changes, the prompt
  prefix) stays the same for the KV cache. Every committed change to memory
  (any operation, an edit in Settings, expiry, a cascade from a deleted chat or
  project, a settings change) raises the memory generation. Before each request
  the snapshot is checked against the current generation, and it is rebuilt when:
  - one of its notes changed, was forgotten, expired, or is no longer eligible
    (its kind turned off, project memory off, memory off): privacy and the
    user's settings beat the cache;
  - the chat moved to another project or was compacted;
  - the model or profile changed and the block is over the new budget.

  New notes alone don't rebuild a snapshot: they reach the next chat.
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
hold URLs, paths, commands or secrets. So an injected memory block is
**user-derived, not outside text**: it does not raise the tool barrier
(`ToolTrust`). Raising it for unreviewed notes was considered and turned down
(the user's choice, 2026-10-12): it would switch off web search and folder
changes in nearly every chat with memory on.

### Forgetting

- **Forget** (one note, or every note learned from one chat):
  - the note is deleted;
  - a tombstone (its subject, the source quotes' hashes and the text's
    embedding; never the text) stops reflection from writing it again: the
    hashes block the same evidence for good, the embedding blocks close
    rewordings. An embedder change can't re-embed text that's gone, so the
    embeddings are dropped then and only the hash block remains (Settings says
    so when it happens);
  - the snapshots that held it are rebuilt;
  - the memory generation goes up, and a queued batch started under an older
    generation re-checks before commit.
- **Forget everything:**
  - deletes notes (not About you: the user's own fields, cleared there),
    vectors, the queue and tombstones; "and read all chats again" also forgets
    where each chat was read (otherwise what was read stays read, and "Learn
    from Past Chats" offers "Read All Chats Again" when nothing is left);
  - raises the generation;
  - clears every chat's snapshot.
- **Deleting a chat** removes its evidence entries and queue items. A note left
  with no evidence from any other chat is deleted too, unless it's `reviewed`
  (setting: "Forget what was learned only from a deleted chat", default on).
- **Back on, the user chooses.** Turning memory off, or "Don't remember this
  chat", puts the watermarks aside (and, for the chat, what was queued from
  it goes). Turning it on again, or "Remember this chat", asks: read what was
  said meanwhile too, or only from now on (closing the question without an
  answer leaves the choice open in Settings › Memory; nothing is read or met
  until it's made). A chat opted out waits for its own "Remember".
- **Past chats** (added 2026-10-13, the user's ask). Memory reads a chat only
  from where it met it. "Learn from Past Chats Now" (Settings › Memory, after a
  confirmation) queues every saved chat's messages from before that, all of a
  chat it never met, and meets it from its start; open chats go through their
  tab, others through their file (user messages from before seqs get them,
  saved with the chat). What was queued or read already isn't again (also
  what was read before an "only from now on" made it meet the chat anew); chats
  opted out, or waiting for the "back on" choice, are skipped. The queue is
  then read at once, as usual (the chat's model, the model free).
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

### About you

Settings › Memory › About you: name, where the user is (a city, or an exact
address, as they like), what they do, anything else. Optional; each field is a
pinned `user` note ("Name: …"), so it's sent first, never expires, and
reflection never changes it (a learned "my name is …" reconciles with it and
writes nothing).

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
