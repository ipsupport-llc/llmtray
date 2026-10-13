# 0024 — Memory: what LLMTray learns about the user between chats

**Status: proposed** (2026-10-12, asked for by the user: "after each session,
extract useful facts, stable user preferences, corrections and behavioral
observations ... inject relevant information into future sessions ... expire
old ones ... with config").

## Why

Every chat starts from zero. The user repeats who they are, what they work
on, how they want answers ("short, in Russian", "no invented charts"), and
corrects the same mistakes again. IPSupport Code has a reflection pass
(its ADR 0007); its lessons for us:

- Reflection runs off the answer path and never delays it. Keep that.
- A short prompt; enforcement in code. A long list of what not to write made
  models recite the list until the repetition guard cut them off.
- Its weak spots, which this design avoids: every fact is folded into every
  prompt (no relevance), facts carry no date or evidence, an observation and
  what it supposedly means are one string, and the only expiry is "last seen".

The hard problem the user named: **the same thing must stay one note.** With
different models, and chats in different languages, a naive pass writes "Prefers
short answers", "Хочет краткие ответы" and "Answer length: brief" as three
notes. Most of this design is about preventing that.

## Decision

### The note

One note is one short statement, at most 160 characters:

| Field | |
|---|---|
| `id` | short stable id (`m42`) |
| `subject` | `user`, or `project:<project id>` (the id, never the project's name, which can change) |
| `topic` | a key from the topic list (below), e.g. `reply-language`, `answer-length`, `hardware`, `esp32-webcam` |
| `kind` | `fact`, `preference`, `correction`, `observation` |
| `text` | the statement, in the memory language |
| `observed` | what actually happened, kept apart from `text` for observations and promoted preferences |
| `evidence` | up to 5 entries: chat id, date, and a quote of the user's own words |
| `created`, `confirmed`, `used` | ISO dates: first written, last confirmed by a chat, last injected |
| `confidence` | `stated` (the user said it) or `inferred` |
| `pinned` | never expires, never rewritten by reflection |
| `history` | the last 3 superseded texts with their dates (audit only, never injected) |

Kinds:

- **fact**: about the user or a project ("Builds an ESP32-S3 speaker with OTA updates").
- **preference**: how the user wants things. Stored as a preference only when
  the user stated it, or when the same observation was confirmed in at least
  2 different chats on at least 2 different days. Until then it stays an
  observation.
- **correction**: the user corrected the model ("Don't invent chart data").
- **observation**: what the user did, with evidence. Its interpretation (what it
  may mean) goes in `text` and is shown to the model as a guess; the
  observation itself is in `observed`.

**Observations stay apart from interpretations**: `observed` is what happened
(close to the user's words, with the quote in `evidence`), `text` is the reading
of it. The model sees both, marked: "observed: …; likely: …".

### Evidence is checked, and only the user's words count

Every `add` and `confirm` carries a quote. The code checks that the quote is
a substring (after whitespace and case folding) of a **user** message in that
chat. Nothing is learned from the model's own replies, tool results, web
pages, project files or documents. This blocks two failures at once: a note
the model invented, and a web page or file that says "remember that the user
wants…" (prompt injection into long-term memory).

### Same thing, one note: the update mechanism

Five layers, each catching what the previous one missed:

1. **One memory language.** Setting, default the app's language. Reflection is
   told to write every `text` in it whatever the chat's language. The code checks
   (`NLLanguageRecognizer`, only for texts long enough to tell). A mismatch gets
   one rewrite request in the same pass; a second mismatch drops the note.
2. **A topic list.** Topics are short English kebab-case keys, a closed set per
   subject that grows slowly: the built-in ones (`reply-language`,
   `answer-length`, `tone`, `formatting`, `hardware`, `os`, `work`, `tools`,
   `documents`, `code-style`, ...) plus project topics created over time.
   Reflection gets the current list and must reuse a topic when one fits. A
   new topic is accepted only if its embedding isn't within 0.85 of an
   existing topic's name and description (else it's mapped to that one).
3. **Reflection edits, not appends.** The pass receives the notes it may touch:
   all notes of the topics the chat's user messages are closest to, plus the
   top-k notes by embedding similarity to those messages, each with its id. It
   answers with operations:
   - `confirm(id, quote)`: still true; adds evidence and refreshes `confirmed`.
   - `update(id, text, quote)`: same thing, said better or changed in detail.
     The old text goes to `history`.
   - `supersede(id, text, quote)`: the user now wants the opposite. `confidence`
     becomes `stated` only when the quote says so.
   - `add(subject, topic, kind, text, observed?, quote)`.
   - `forget(id, quote)`: the user asked to forget it, or said it's no longer true.
   Ids are checked; an unknown id drops the operation.
4. **A duplicate guard in code.** Before any `add`, its text is embedded (bge-m3,
   which matches across languages) and compared with every note of the same
   subject: at 0.88 or above the `add` becomes a `confirm` of that note; between
   0.75 and 0.88 it's stored with a `near:<id>` mark for the next tidy-up. A
   `preference` or `correction` with a topic that already has an active one of
   the same kind is turned into an `update` of it (a topic holds one active
   preference per subject: "answer-length" has one value).
5. **Tidy-up.** Once a day, when the server is idle, clusters of notes with
   similarity ≥ 0.80 (and every `near:` pair) in one subject go to the model in
   one call: "merge these into one note in <language>, or say they differ". A
   merge keeps the earliest `created`, the latest `confirmed`, the union of
   evidence (5 newest), and `pinned` if any had it. The same pass rewrites
   notes not in the memory language (after the user changes it).

Without an embedder (the project-files feature off), layers 2 and 4 fall back
to exact topic match and normalized-text match, and the settings say memory
works better with it on (it downloads only when the user agrees,
adr/0012).

### When reflection runs

- A chat is reflected on when it goes quiet (no message for N minutes, default
  10), when the user switches to another chat, or when the app quits (queued,
  done on next launch). Only the messages after the chat's watermark (the last
  message reflected on) are read.
- Never: a temporary chat, a chat marked "Don't remember this chat", a chat
  whose user messages since the watermark total under 20 words.
- Only when the server has no request running (adr/0021), with thinking off.
  A user request arriving cancels the pass; it retries later from the same
  watermark. One pass at a time, at most one queued per chat.
- On the loaded model by default, never loading another one for it. The
  setting can point it at a profile; a different model is used only if it's
  already loaded.
- Input: the user messages in full (capped at ~6k tokens, newest kept), the
  assistant's replies cut to their first ~300 characters (context only, never a
  source), the topic list and the candidate notes.
- At most 5 operations of each kind per pass. A pass that can't be parsed
  writes nothing and is logged (the reply length and finish reason, like
  IPSupport Code does).

### What goes into a chat

- **Once, when the chat starts** (its first request), the notes for it are
  chosen, then **frozen** for that chat, so the prompt prefix stays the same
  and the KV cache keeps working. They're chosen again only when the chat is
  compacted.
- Score: `similarity × weight(confidence) × 0.5^(days since confirmed / half-life of the kind)`,
  similarity against the first user message (and the chat's project).
  Pinned notes and `user`/`preference` notes with `stated` confidence always
  go in first (up to half the budget); the rest by score until the budget.
- Budget: tokens (default 300), set in Settings; a profile can set its own (a
  small-context model wants less).
- Shown to the model as data, under a trust barrier like project files: "What
  you know about the user from earlier chats. It may be outdated; what the
  user says now wins." Guesses are marked as guesses. A chat in a project gets
  that project's notes too.
- The chat shows a small "Memory: 4 notes" chip; clicking lists them, with
  "Forget" on each. Each injected note's `used` date is updated.

### Expiry

- Each kind has a half-life in days, set in Settings (defaults: observation 30,
  fact 90, preference 180, correction 180). Confirming a note restarts it.
- A note whose recency factor falls under 0.1 (about 3.3 half-lives) is
  **expired**: it's no longer injected or offered to reflection, shown under
  "Expired" in Settings, and deleted 30 days later unless the user restores it.
- At most 300 active notes (setting); over it, the lowest-scoring unpinned
  ones expire.
- Pinned notes never expire.

### Settings › Memory

- Memory on/off: **off by default** (every LLMTray feature is opt-in); the
  first-run setup offers it.
- What to collect: facts / preferences / corrections / observations (each a
  toggle).
- Injection budget (tokens), max active notes.
- Half-life per kind; "delete expired notes after (days)".
- Memory language (Auto = app language).
- Reflection: when the chat is idle for N minutes; model: the loaded one or a
  profile.
- Project memory on/off.
- The notes: grouped by subject and topic, each with its evidence and dates;
  edit, pin, forget; "Expired" with restore; "Forget everything".
- Per chat, in its menu: "Don't remember this chat".

Everything stays in `~/Library/Application Support/LLMTray/memory/`
(`notes.json`, `vectors.bin` for the embeddings, `queue.json` for pending
passes). Local only. External clients through the proxy never get memory:
it's for LLMTray's own chat.

### Later (todo)

- **Temporary states** ("tired", "in a hurry", "ill"): a solvable problem, not
  in the first version. The first version tells reflection to skip them and
  drops a note whose text the code recognizes as a state. The plan for later:
  a `state` kind with a TTL in hours, never promoted to a preference, injected
  only while it lives.
- A `remember` tool so "запомни, что…" lands at once, with a visible chip,
  instead of waiting for the pass.

## Order of work

1. Store + Settings › Memory with hand-written notes (no model involved):
   format, expiry, list UI, injection with the budget and the freeze.
2. Reflection pass: prompt, operations, evidence check, language check,
   duplicate guard, queue and idle scheduling.
3. Tidy-up pass.
4. Project memory.

## Testing

- Unit: note store round-trip; every operation incl. unknown ids; the evidence
  check (quote from the assistant or a tool result is refused); duplicate guard
  with fixture vectors (an English and a Russian note of one preference merge);
  topic mapping; decay and expiry; injection order and budget; freeze per chat.
- Reflection eval: a set of fixture chats (Russian and English, the same
  preferences said differently) run through two different models; measured:
  notes per real fact (target 1.0), notes in the wrong language (target 0),
  notes without valid evidence (must be 0: the code refuses them). Runs on the
  user's Mac only on their command.

## Consequences

- Reflection costs model time while the user isn't asking for anything; it
  never competes with a request.
- What is learned is bounded by the model; the evidence rule and the guards
  limit the damage, the Settings list lets the user fix the rest.
- The embedder (1.1 GB) is a soft requirement for good deduplication.
