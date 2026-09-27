# 0012 — Project files: a local micro-RAG

**Status: accepted** (2026-09-26, by the user). Nothing here is built yet. Numbers
under Evidence were measured on an M5 (26 GB, macOS 27.2) or are cited.
Revised after two architecture reviews (Codex, Claude) and the user's
requirements (2026-09-26): a full workspace like ChatGPT's projects —
many documents, vector search from v1, sources from the tool, office,
PDF and images all processed.

## Decision

A project ([0006](0006-chat-sessions-and-library.md): today only a named
group of chats) gets **files**: documents added once, usable from every
chat of the project, reached by the chat model through tools.

- **Engine: the system SQLite, no extensions.** One `index.sqlite` per
  project. Apple's SQLite has FTS5 but `OMIT_LOAD_EXTENSION` (no
  sqlite-vec); LLMTrayCore links `sqlite3` (`linkerSettings`).
- **Hybrid from v1.** FTS5 twice — `unicode61` (words, BM25) and
  `trigram` (substrings, the stand-in for the Russian stemmer FTS5
  lacks: "договор" finds "договора") — plus dense vectors, f16,
  brute-forced with Accelerate; the three lists fused by RRF (k = 60).
- **The embedder is configuration, not code**, and never Qwen (the
  user's call). A registry entry names the HF repo, the architecture
  family, pooling (CLS / mean / last token), normalization, query and
  document prefixes, max length and dimension; adding a model is adding
  an entry. A project picks its embedder once, at creation; the index
  records it. A change builds the new vector set separately (the model
  and its preprocessing version pinned per set); queries use the active
  set's model only; the switch to the new set is one transaction.
- **The default embedder is bge-m3** (the user's choice): MIT, 568M
  (XLM-RoBERTa), 8k-token context, 1024 dimensions, CLS pooling,
  normalized, no query/document prefixes; RuBQ retrieval (MTEB results)
  71.2 against multilingual-e5-large-instruct 69.2 and EmbeddingGemma
  69.7 (plain multilingual-e5-large scores 74.1 but has a 512-token
  limit and no instructions); MLX conversions exist
  (mlx-community). No MRL: vectors stay 1024-d, ~400 MB f16 at 200k
  chunks. Its sparse and multi-vector outputs are not used in v1 — FTS5
  covers the lexical side. Other registry entries (USER-bge-m3, tuned
  for Russian; arctic-embed-l-v2.0; multilingual-e5-large-instruct;
  EmbeddingGemma-300m) stay possible per project.
- **Scale**: 1-2k documents, up to ~200k chunks per project, without a
  vector index — dense scoring of 200k × 1024 took 5-8 ms, the whole
  hybrid search p50 ~190 ms / p95 ~350 ms (spike); vectors stay f16 in
  memory (~400 MB at 200k) and are widened in tiles only while scoring.
  The index takes ~104 MB per 10k chunks on disk (~2 GB at 200k). Indexing 1,000 documents
  × 20 pages is hours of background work at most: it shows progress,
  pauses for chat generation, resumes after a relaunch.
- **Extraction in tiers**, cheapest first; a page takes the first tier
  whose text passes the junk check: (1) text layer — PDFKit, docx/doc/
  odt/rtf via `NSAttributedString`, HTML via LLMTrayCore `WebParsing`,
  plain text and code, xlsx/pptx from their XML (v1b), and the legacy
  binary .xls / .ppt (v1b; supported — the user's call): every sheet as
  rows with its header, every slide's text and notes, one "page" per
  sheet or slide; embedded objects not in scope; (2) Vision OCR for
  scans and photos; (3) a document VLM for hard pages. Images get OCR
  and a short description, both indexed, so a photo is found by what it
  shows. For images OCR text and description are separate outputs, both
  produced (the first-tier-that-passes rule is for pages). The
  description comes from a small built-in VLM beside the chat model, not
  the chat model itself (the user's call), run as a bounded, cancellable
  `GenerationQueue` job with progress; candidates
  (Florence-2, SmolVLM2, moondream2 — licences and MLX support checked
  in the spike) are compared on the eval images. All three tiers are in
  the product's scope; the plan orders them.
- **Retrieval, not stuffing**: no "whole project in the request" mode.
- **Copies or linked folders — the user's choice**, per source:
  - *added files* are immutable copies in the project; replacing one is
    remove + add;
  - *linked folders* stay where they are: watched with FSEvents, a
    changed file (mtime, then hash) re-indexed, a removed one dropped
    from search; a citation to a file that has since changed or gone
    says so. The folder is remembered by a bookmark, so a rename or
    move doesn't lose it.
- **Project instructions**: text the user writes for the project, stored
  with the project in `library.json` (`decodeIfPresent`), resolved for
  every request from the chat's current project (an edit applies on the
  next message; a chat moved to another project gets the other's), and
  placed after the profile's system prompt, before the tool-use policy.
  It's the user's text, trusted — unlike document text — but tool access
  and the trust rules stay in code whatever it says.
- **Document text is data, never instructions**, enforced by what the
  code declares and sends, not by asking the model.
- **Optional, like everything heavy in the app.** Project files are off
  until turned on in Settings, as image and music generation are
  ([0009](0009-media-generators.md)): until then nothing is downloaded
  or started, and a project is the group of chats it is today. Each
  model is its own opt-in with its download shown — the embedder when
  the feature is turned on, the OCR VLM (tier 3) and the image
  describer separately; without them their tier is skipped and says so
  (a scan without tier 2/3 is indexed as "no text"). Settings shows the
  disk each takes and removes it when turned off.
- **Everything stays on the Mac.** A temporary chat has no project; the
  "writes nothing" rule of 0006 is untouched.

## The chat side

**Project identity.** `ChatSettings` gains `project: (id, hasSearchable
Files)?`, carried across rounds by `currentSettings()` the way
`modelPath` is, so tool declaration (`definitions(for:)`, `isOffered`)
and execution both see it. It is set from `ChatLibraryStore`'s chat →
project map when the turn starts; each project tool checks again when it
runs, and again just before it returns document text, that the chat
still belongs to that project and the project exists (moved chat,
deleted project, a never-declared tool → refused). "New
Chat in Project" writes the map when the session id is created, so the
first turn already sees the files; a temporary chat started from a
project is still projectless.

**Tools** (always on in a project chat, independent of the profile's
`enabledTools`; in `--dump-tool-definitions` for evals; the tool-use
policy gets their wording):

- `list_project_files()` — whenever the chat has a project: short ids
  (`1`, `2`, … per project), names, pages, status;
- `search_project_files(query, top_k = 5, ≤ 10, doc?)` — once any file
  is searchable; hits as `[doc:page]`, heading, the chunk, a neighbour
  only while budget remains; at most 2 hits per document unless `doc`
  narrows the search, so a question across files isn't answered from one;
  the result says which files are still indexing, failed, or searched
  lexically only (no vectors yet or the embedder unavailable);
- `read_project_file(doc, from_page, to_page, cursor?)` — bounded by
  tokens, not pages; a cut result returns a cursor to continue.

A large document (up to 5,000 pages) can't be read through in four tool
rounds: the policy tells the model to say what it read and that the rest
is unread ("insufficient coverage") rather than summarise pages it
hasn't seen; whole-document summaries are a later feature (per-document
summary chunks, v3).

**Budget.** Nothing in the chat counts prompt tokens today (auto-compact
counts messages). An estimator in LLMTrayCore counts the whole
serialized request in UTF-8 bytes and converts with a ratio calibrated
per chat from the server's own `usage.prompt_tokens` of the previous
response (asked for with `stream_options.include_usage`; without it the
default ratio stays), starting from a deliberately low 2 bytes per token until the
first response (validated against the chat models' tokenizers on
Russian, English and code in PR 3.3). It counts —
system prompt, instructions, history, tool declarations, the calls so
far. Before each project result the room left is `context − estimate −
max_tokens − margin (10%)`; the result gets at most a share of it
(≤ 50%, hard-capped), is truncated with a marker past that, and a chunk
already returned this turn isn't sent again. With no safe room left the
tool answers "the conversation is too long to add more file text —
compact or start a new chat", and search/read stop being declared for
the turn — as spent generators are ([0007](0007-chat-tools.md));
listing stays. Tested with a long chat and repeated searches.

Built (PR 3.3, `PromptTokenEstimator`, `ProjectTextBudget`): the fork's
mlx_lm.server (pin `e1a05ac`) answers `include_usage` in streams too — a
last chunk with `prompt_tokens` = the whole prompt (`len(ctx.prompt)`,
the cached part included; `cached_tokens` apart). The next request of a
tool round is that count plus what was added since (the call, the
results, grown declarations) at 2 bytes/token — new file text may
tokenize worse than the chat so far; anything else (nothing counted, a
request with images) is the whole request at 2. No chat-average ratio is
applied to new text: a request that got smaller (tools no longer
declared) while adding dense file text would be undercounted (Codex).
Images count 1,536 tokens each,
their data URIs left out of the bytes, and a request with images doesn't
calibrate. Measured on the local tokenizers (Gemma 4, Qwen3, Llama 3.2,
Mistral v0.3, Phi-3.5, DeepSeek-Coder-V2-Lite, LFM2.5, Falcon3): Russian
2.1-6.9 bytes/token (Falcon3 the lowest), English 4.1-4.6, code 2.8-3.6
— 2 never undercounts. Hard cap 8,000 tokens a result, 256 the least
worth sending. A project tool opts in with `ChatTool.projectAccess`
(`.listing` / `.fileText`) and returns `ToolResult.projectText` —
`ProjectToolOutput`: hits with an id (dedup), doc, rev, page, chunk,
name, heading and text, plus text before and after them.

**Earlier results.** Live chats resend old tool messages every turn;
saved chats drop them (`persistCurrentSession` skips `role == "tool"`),
so a reloaded chat would lose its evidence and a live one grow ~5-10k
tokens per search. A `withoutEarlierProjectResults` step, beside
`withoutEarlierRefusals`, drops earlier turns' project tool calls and
their results together, leaving the answer (with its citations): what a
reloaded chat has, so the request is the same live and reloaded. The
model searches again when it needs the text. (Built as one step with the
refusals: `ChatRequestBuilder.withoutEarlier`, the logic in
`LLMTrayCore.HistoryPruning`.)

**Trust**, deterministic. File names and every other project tool
result (listing included) count as file text. What this guarantees is
narrow: file text can't trigger a network or generator tool in the same turn, and can't
come back as a trusted summary. It does not stop the model from being
misled by what it reads — an answer built on a file is attributed to the
file (citations), so the user can see where a claim came from.

- document text reaches the model only as project tool results, framed
  as quoted material with its `[doc:page]`;
- a batch of tool calls that includes any project tool has its network
  and generator calls refused up front, before drafts, queueing or
  unload; and once a project tool has returned anything in a turn, tools with
  `ToolCatalog.Entry.usesNetwork` and the generators are not declared for
  the rest of the turn, and refused (`.refused`) if called anyway —
  exfiltration or actions prompted by a file need a new user message.
  The barrier is per call: in a batch holding a project read and a
  generator, the generator is refused before any draft, queue ticket or
  model unload (the round decides those up front today), and checked
  again before it runs;
- compaction ([0006](0006-chat-sessions-and-library.md)) leaves tool
  messages out of its transcript (or uses their stubs), else file text
  would come back as a trusted summary.

**Citations.** The model writes `[3:12]` (doc 3, page 12 — a sheet or
slide number for spreadsheets and decks, shown with its name).
`ChatMessage` and `PersistedMessage` gain `citations: [Citation(project,
doc, rev, page, chunk?)]` (`decodeIfPresent`), collected per answer
like `sourcesByAnswer`, from the pages search or read returned this turn
only, and resolved against the project they were made in — never the
chat's current one (a chat can move). A `[n:p]` in the text that matches
none stays plain text; duplicates collapse into one chip. A chip opens
the copy (or the linked file) at that page, and says so when the file
has changed since that revision or is gone. A citation also keeps the
file's name as it was read (the chip's label, once the file is gone too);
the chip's action is `MessageBubble.openCitation`, nil until PR 3.4/3.5.

**Retention.** The cited revision's `pages` rows are kept as tombstones
when its document is re-indexed or removed (a linked file too), until no
saved citation refers to them. No reference counts across the two
stores (session files and the project's database can't commit
together): a **sweep** during maintenance reads the citations of the
project's saved chats and drops tombstones none of them names —
idempotent, so a crash, a regenerated or edited answer, a compaction or
a deleted chat is simply caught by the next sweep. Deleting a project
deletes all of it. Tombstones count towards the disk caps.

## The index

```
Application Support/LLMTray/projects/<projectID>/
  files/<doc>.<ext>     the copy
  staging/              copies in progress
  index.sqlite (+ -wal, -shm)
```

- `documents(doc, source, rev, name, ext, sha256, bytes, added_at, status, pages,
  error)`; `doc` a small integer, `AUTOINCREMENT` (a plain integer key
  reuses the last id after a delete, and an old `[2:5]` would point at
  another document). `status`: staged → extracting → searchable →
  embedded | failed | removing, plus `empty` (no text in it),
  `unsupported` (a format this version doesn't index), `not_indexed`
  (indexing stopped by the user; Index Now resumes it).
- `pages(doc, rev, page, text, tier, status, error)` — the raw extracted
  text: `read_project_file` quotes it; a failed page is retried from it.
- `chunks(id AUTOINCREMENT, doc, rev, page, ord, heading, start, len,
  body)` — `body` normalized for indexing only (NFC, ё→е, case, soft
  hyphens and zero-width removed; look-alike Latin/Cyrillic kept
  distinct) with the heading path as prefix; `start`/`len` are
  code-point offsets into `pages.text`, where the verbatim text the model
  is shown comes from. 300-500 tokens by structure, no overlap, a table
  its own chunk with its header row.
- `chunks_fts` (`unicode61 remove_diacritics 2` — it folds Latin only:
  not ё/е, not й/и, so our ё→е is required) and `chunks_tri` (`trigram`,
  `detail=full`: `none`/`column` break MATCH for any term of 4+
  characters; budget ~1.75× the text), both external content on
  `chunks(body)`, kept in step by insert/delete/`AFTER UPDATE OF id,
  body` triggers, `'rebuild'` as the repair. Queries shorter than 3
  characters go to `chunks_fts` only.
- Vectors in packed blocks, not a row each (one 2 KB blob per row left
  most of each page empty in the spike, and blocks load faster): `vec_blocks(set_id, doc, rev, n, chunk_ids, v)`, one row
  per embedding batch (≤ 64 vectors), committed batch by batch —
  `embedded` flips after the last, so a crash costs one batch;
  `vec_sets(set_id, model, dim, prep_version, active)` for an embedder
  switch (one transaction flips `active`). `vec_chunks(chunk, set_id)`
  says which chunks have a vector (a batch checks its own chunks, not
  every block of the document) and `vec_progress(set_id, doc, rev,
  next_ord)` where the next batch starts, so a batch costs the same at the
  end of a 10k-chunk document as at its start.
- `meta(schema, ...)`. A schema change builds a **new database beside
  the old one** (`index.next.sqlite`): documents migrated, derived
  tables rebuilt from copies and available linked sources, an
  unavailable source's rows and every cited revision's pages carried
  over — and for an unavailable source its current revision too, pages
  kept and its chunks, FTS rows and vectors rebuilt from those pages, so
  it stays searchable offline; the switch is the compaction swap below, done only
  when the new file is complete; a crash leaves the old one in use;
  free disk is checked first. `documents` — user
  state — migrates only by explicit ALTERs. 16 KB pages and
  `auto_vacuum = INCREMENTAL`, both set before the first table.

**Search path.** The query is normalized, split into letter/digit runs,
each run double-quoted, joined with OR — at most 24 terms of 64
characters; raw text never reaches MATCH (44 of 65 hostile strings
would have been syntax errors). Cyrillic terms are pseudo-stemmed for
trigram (a crude ending strip: "договоров" → "договор" finds
договора/договору). Each list ranks inside FTS5 first (`ORDER BY rank
LIMIT ~85`), then joins `documents` for `status IN (searchable,
embedded)` (~40% cheaper than joining first; a `removing` document is
hidden before reconcile). bm25 cost grows with the matching rows and
FTS5 has no top-k early exit ("в" alone 300-880 ms at 200k), so a
document-frequency gate drops terms in > 20% of chunks (via `fts5vocab`,
~0.5 ms a term) but keeps the rarest matching one — it halves p95 and
changes results, so its threshold is set by the eval. When only terms
above it are left (a one-word "в" too) and the dense list runs, both
lexical lists are skipped: bm25 over most of the index for ~0
information (without dense the rarest still ranks). A per-query
latency budget; trigram may run only when unicode61 underdelivers or
for stemmed/identifier terms (eval). Dense: f16 blocks widened in tiles
(vImage) into `cblas_sgemv` — f32 speed at f16 memory.

**Consistency.** Add: insert the `staged` row (its `doc` allocated),
copy to `staging/<doc>.part`, hash, rename to `staging/<doc>.<ext>`,
record the hash, rename to `files/<doc>.<ext>` — every staged path
belongs to exactly one row (two adds of the same file never share one;
duplicates by hash are refused at add); extraction writes `pages`, chunks and FTS in one
transaction → `searchable`. Remove: `removing` in a transaction, delete
the file, delete the rows in a transaction. Re-index: rebuild the
document's derived rows in one transaction; the old ones stay searchable
until it commits. At project open a reconcile pass finishes or undoes
every state: `.part` files and staged copies no row claims are deleted,
a complete staged copy whose hash matches its row is promoted (a promoted
copy of a still-`staged` row is re-hashed first: a torn one gives way to a
matching staged copy, or, the only copy left, is kept and `failed`), `extracting` goes back
to `staged`, `removing` is finished, embedding resumes. The spike
killed a child at 16 points of add/remove/re-index: before reconcile a
document was invisible or complete, after it no orphans or duplicates,
and a crash mid re-index kept the old revision searchable.

**Linked folders.** Before linking, the user is told that the folder's
text and vectors are kept in the app's data (searchable while the folder
is offline) and how much disk that takes; removing a source offers
"remove it and its index". The app isn't sandboxed, so the bookmark is a
plain (not security-scoped) one, refreshed when stale; the folder is
read only, and the extractor gets file paths inside it only. A
`sources(id, kind, bookmark, path)` table: `copy`
or `folder`; a document of a folder source keeps its relative path and
the mtime + hash it was indexed at. FSEvents (and a full rescan at
project open, since events are lost while the app isn't running) queue
changed files for re-index through the same states; a file that
vanished goes `removing` — but only after the source itself resolved
and scanned: a source is `available`, `offline` (volume not mounted),
`needs access` or `stale bookmark`, and an unavailable one changes
nothing in the index (an unplugged disk is not a mass deletion). Events
are coalesced; a new revision is committed only after the file's
identity and hash are checked. Symlinks leaving the folder and
packages/bundles are skipped; the caps count linked files too.

Every document version has a `rev` (a counter, with its content hash),
stored in `pages`/`chunks` and in citations. A re-index of a linked
file writes a new `rev`; the cited revision's page text stays in
`pages` until no saved citation refers to it (checked at compaction and
chat deletion), so a citation still quotes what the model saw, marked
"the file has changed since". Opening a citation opens the live file,
or says it's gone.

Removal and reconcile are source-aware: removing a linked document or
source drops its rows — except the tombstoned pages of cited revisions,
which the sweep removes later — and never touches the user's files; only copies
under `files/` are ever deleted.

**Concurrency.** An app-wide `ProjectIndexRegistry` owns one writer per
project (tabs don't: `ChatToolbox` is per tab) plus a read-only WAL
connection for searches, so tabs don't queue behind an ingest. No
`await` while a transaction is open: extract first, then write
synchronously. The writer owns the project exclusively — an flock on
`index.lock` from open to close, so a second writer (another handle, another
process) is refused rather than racing a compaction swap, which also
checks `data_version` and drops a copy older than the file. Each
connection answers on its own queue only (a `ProjectIndex` or searcher
leaked out of a registry closure throws instead of racing it). The reader wasn't blocked by a 6k-chunk write (p50 44
vs 45 ms, no BUSY) and never saw uncommitted rows. But the WAL grows
(60-350 MB for that transaction) and any open reader snapshot stalls
the checkpoint, so readers reset statements at once, a TRUNCATE
checkpoint runs when ingest goes idle (retried on BUSY), and
`journal_size_limit` is set. `'rebuild'` (82 s at 200k chunks) and
`integrity-check` (23 s) are background jobs with progress, never run at
every project open.

**Maintenance (vacuum).** Deletes, re-indexes and embedder switches
leave free pages, and FTS5 segments accumulate:

- **Routine**: the database is created with `auto_vacuum =
  INCREMENTAL`; when ingest goes idle, `PRAGMA incremental_vacuum(n)`
  returns free pages to the OS in small steps. That shrinks the file but
  doesn't defragment it or merge FTS segments.
- **Full compaction** is triggered by fragmentation, not the free list
  (which the routine step keeps low): after churn since the last
  compaction passes a threshold (chunks deleted or re-indexed ≥ 30% of
  the live ones), or on demand — **Compact Index** in the project's ring
  menu and the Files view. Steps: FTS5 `'optimize'` on the live database
  (5-8 s at 200k), `VACUUM INTO` a temp file, `quick_check` on it; then
  the swap: new searches wait, readers drain, a TRUNCATE checkpoint,
  **all** connections closed, the old file (and its `-wal`/`-shm`) moved
  aside, the new one renamed in, connections reopened, the old one
  deleted; a `meta`-independent marker file records the step, so a
  crash mid-swap is finished or rolled back at the next open.
- It rewrites the whole file (~2 GB at 200k chunks): free disk is
  checked first; it runs only with no ingest active; it can't pause —
  it's cancelled and restarted later (the old file stays in use until
  the swap).
- WAL: TRUNCATE checkpoints when idle and `journal_size_limit` (above).
- The Files view shows the index's size on disk and how much a
  compaction would free.

**Deletion.** `deleteProject` (today it only edits `library.json`)
cancels the project's jobs, closes its connections, writes a deletion
record, removes the directory, then drops the record; at launch pending
records are finished. A directory with no project and no record is left
alone (an unreadable `library.json` loads as empty today — sweeping on
it would delete a user's files).
Open tabs of its chats get "project removed" from the tools.

## Extraction

Parsers see hostile input, and Apple's own hang or blow up on it (the
spike, branch `spike/rag-extract`): a 1.9 MB zip-bomb docx given to
`NSAttributedString` reached 14.3 GB in 13.5 s; an 18 KB mutated RTF
loops `NSAttributedString` and `textutil` forever
(`fixtures/rtf_hangs_textkit.rtf`); Quick Look hung > 60 s on a corrupt
.ppt. So:

- **The safety contract is the public mechanisms**; the private and
  deprecated ones only tighten it. Required before any parser runs: the
  wall-clock timeout, killing the process group, the stdout cap, and
  parent-side footprint polling (20 ms). The jetsam limit is used when
  the symbol resolves, and is not relied on. Network isolation
  (`sandbox_init`) is required for the formats that go through Apple's
  importers (docx/doc/odt/rtf via `NSAttributedString`): if it can't be
  set up, those formats fail with "not supported on this system" and our
  own parsers (PDFKit text, OOXML sheets and slides, legacy, HTML, plain)
  still run — none of them opens a connection. Tested in the signed,
  packaged app on macOS 14 (the minimum, as CI) and the current macOS, with the private symbol
  absent and the sandbox call failing.
- **A child process** of the app binary (`LLMTray --extract <path>`,
  JSON lines out) does all parsing, started with `posix_spawn` —
  `ProcessRunner` gains that variant; `Process` can't set what follows —
  in its own process group:
  - **wall-clock timeout** that kills the group — required, not optional
    (the RTF hang);
  - **memory**: `setrlimit` RLIMIT_AS/DATA/RSS are rejected (`EINVAL`) on
    macOS; the kernel's jetsam limit set at spawn
    (`posix_spawnattr_setjetsam_ext`, private — resolved at run time)
    killed exactly at the limit, with the parent polling the child's
    footprint every 20 ms as the public backstop (+21 MB overshoot at a
    500 MB limit);
  - RLIMIT_CPU and RLIMIT_CORE = 0, set by the child on itself;
  - **no network**: `sandbox_init` "no-network" in the child before it
    opens the file (deprecated, works; none of the paths tried to
    connect anyway);
  - a **stdout cap** counted by the parent.
- **Zip containers** (docx, xlsx, pptx, odt) go through our own capped
  zip reader first — per-part and total bytes, compression ratio, entry
  count, no nested archives — and only then to `NSAttributedString`
  (the same bomb: refused in 2 ms). zip64 is refused.
- **XML**: the system parser already refuses entity expansion and never
  fetches external entities; any DOCTYPE in an OOXML part is refused
  and nesting capped at 256 (it parsed 200k levels).
- **HTML** through a new `HTMLText` in LLMTrayCore (sharing
  `WebParsing.decodeEntities`; `WebParsing.text` keeps script/style and
  drops newlines): consistent on every supported macOS and 43 ms vs 373-504 ms
  for `NSAttributedString`, whose HTML import is in-process WebKit on
  macOS 14 (an out-of-process service on 27).
- **Legacy .xls / .ppt: our own parsers** (OLE2 + BIFF5/8; PPT text
  atoms following the live edit chain) — 46,688/46,688 cells against
  xlrd on 23 files, all slide text and notes on 17 POI files, 2-15 ms a
  file. Quick Look lost notes and whole sheets and hung; thumbnails +
  OCR recalled a median 36%. Out of scope: .xls text boxes and charts,
  .ppt headers, footers and comments. Password-protected files fail
  cleanly.
- **Type from content** (magic bytes), not the extension.
- **The junk check**, six signals (letters per glyph, U+FFFD, private
  use, look-alike code points such as U+0138 for "к", control characters,
  mojibake like "Äîãîâîð"), threshold 0.5 (clean text in ~10 languages
  scored ≤ 0.17), applied only where a next tier exists (PDF pages,
  images); an empty sheet or slide is "empty", not junk.
- **The runner contract**: the child writes JSON lines (one per page,
  sheet or slide); the parent caps the encoded stdout at the text cap
  plus framing (~1.5×, escaping included), the page count and the wall
  time; hitting any cap kills the group and records which one on the
  document ("too large: text cap"), keeping the pages already received
  only if the document is otherwise complete — never a silently
  truncated one.
- **Caps**: bytes per file, 5,000 pages, 32 MB of text per document,
  time per file, pixels per rendered page (a PDF page can claim 10⁹
  points); per-project files, bytes and chunks; free space checked
  before a copy.

Timing (M5, child's own): PDF 100 pages 450 ms; docx/doc/odt/rtf 100
pages 69-84 ms; xlsx 5k × 9 273 ms; xls 5k × 8 163 ms; process start
adds ~20 ms.

- **Tier 2**: `VNRecognizeTextRequest` rev3 `.accurate` (Russian
  from macOS 13), document segmentation + perspective correction for
  photos, `RecognizeDocumentsRequest` for tables on macOS 26+.
- **Tier 3 (v3)**: PaddleOCR-VL-1.5 or GLM-OCR via mlx-vlm, as a
  `GenerationQueue` client like the generators
  ([0009](0009-media-generators.md)).

## Dense retrieval

- Vectors in `vec_blocks` of their `vec_set` (The index), f16 in memory
  for open projects only, widened in tiles while scoring; the set
  records model and preprocessing, so a change re-embeds into a new set.
- `embedded` is a second commit after `searchable`: lexical works from
  extraction on, and a crash while embedding costs only the embedding.
- The embedder is a managed bidirectional runner (JSON lines, request
  ids, bounded messages, timeouts, cancellation, restart, the orphan
  marker) — `ProcessRunner.runStreaming` is one-shot.
- **Scheduling.** Indexing is a background job in bounded slices (one
  embed request ≤ 256 chunks and ≤ 10k estimated tokens — `EmbedRunner`
  refuses a larger one and `documentBatches` splits a document to fit;
  the runner's own 262k-token limit is only a backstop — ≤ ~3 s); it
  holds no `GenerationQueue`
  ticket across slices. `GenerationQueue` gains a background lane below
  the interactive one: an image or music generation that wants the queue
  gets it at the next slice boundary, and the embed runner exits then
  (its ~1.7 GB freed) — at every generation grant, since a search's
  query may have started it too; indexing resumes after. While a
  generation holds or waits for the queue the runner is paused: a query
  embedding gets `.paused` at once and the search goes lexical-only
  instead of loading the embedder next to the generation's model. Slices also wait while
  the chat model generates. A query embedding is interactive: it jumps
  ahead of queued index batches in the runner. At most two projects'
  vectors are resident (LRU, a ~800 MB budget); a search in a third
  loads its vectors (120-300 ms at 200k) and evicts the oldest.
- **Budget, measured before v1b ships**: the chat model + the embedder +
  two open projects' vectors + the extractor, at the Metal limit
  (~19 GB by default here, not the 26 GB of RAM), with chat latency
  under indexing; the OCR/VLM tiers only run as exclusive queue jobs.
- A query while it can't run falls back to lexical, and says so.
- **The runner is plain MLX with our own family modules** (`xlm-roberta`
  ~150 lines, `gemma3-bidir`): only `mlx`, `tokenizers`, `numpy` — all in
  the app's venv already; not `mlx-embeddings` (36 more packages), not
  mlx-lm (the fork pin doesn't matter). Spike: branch `spike/rag-embed`.
  It runs in **the mlx-lm server's venv** (`mlx_server_venv`), not a venv
  of its own like mflux's or music's: those exist because their stacks
  pull conflicting transformers/tokenizers versions, while the runner
  needs nothing the server venv lacks, and its own venv would download the
  same ~200 MB of wheels again. The coupling to the fork pin's versions is
  guarded rather than assumed: every load re-embeds the reference vectors
  (below), so an mlx or tokenizers bump that changed the vectors refuses
  the model instead of mixing old and new vectors in one set.
- **bge-m3 weights**: `mlx-community/bge-m3-mlx-fp16` (1.1 GB, MIT),
  pinned by revision and per-file sha256, tokenizer.json pinned by hash
  (BAAI's older file adds a token before `</s>` after trailing
  whitespace). fp16 is the default; 8-bit (592 MB) is allowed but saves
  memory only, not time; 4-bit is refused (min cosine 0.915).
- **Pooling, prefixes, dtype come from the registry**, never a model
  card (mlx-community's card says mean pooling for bge-m3; it's CLS).
  An entry: id, licence, family, source {repo, revision, files → sha256},
  weights {compute dtype, quantization}, tokenizer {file, max length,
  pad id}, prefixes, pooling, dense layers, normalize, dim,
  `preprocessing_version`, batching, reference {file, sha256,
  min_cosine}.
- **Each entry ships reference vectors** (6 documents, 3 queries: ru,
  en, mixed, code, one longer than any local-attention window); the
  runner re-embeds them at load and refuses the model below the
  threshold, NaN counting as failure (EmbeddingGemma gives NaN in fp16:
  bf16 or fp32 only; a 512- vs 257-token window bug showed only past
  ~250 tokens).
- **Protocol**: a `ready` line (dim, max length, load ms, verify
  cosine, limits) or `fatal`; requests `{id, op: embed, kind:
  query|document, texts, timeout_ms}` → base64 f16 vectors with token
  counts and truncation flags, or `{ok: false, error: bad_request |
  too_large | timeout | cancelled | internal}`; `cancel`, `ping`,
  `shutdown`; limits 8 MiB a line, 256 texts, 262k tokens a request.
  Cancel and timeouts act at batch boundaries of ≤ 4,096 tokens (≤ ~2 s),
  so the client adds a grace period, then kills. stdin EOF is the normal
  stop; the runner exits within 0.1 s if the app dies. Large requests
  (up to 256 texts): many small concurrent ones ran at 3-4k tokens/s.
- EmbeddingGemma is gated on Hugging Face (Gemma licence): its entry
  needs the user's acceptance or an ungated mirror.

## UI

- **Files view** of the project: a drop zone and Add… (files, or Link
  Folder…), a row per document with its status (copying, reading, OCR,
  describing, embedding, ready, empty, failed + reason), Remove,
  Re-index; per source, its availability.
- **Indexing is visible without opening it** (the user's design): in the
  sidebar the project's folder icon becomes a progress ring while it
  indexes — ⏸ when paused, ⚠︎ with a count when files failed — and
  returns to the folder when done. Hover: "Indexing 120 of 450 files ·
  OCR · ~20 min left". Clicking the ring: **Pause / Resume** (the pause
  survives a relaunch), **Stop** (the queue is cleared; what's indexed
  stays searchable, the rest is marked "not indexed" with Index Now),
  **Show Files**.
- **Automatic pause** while the chat model generates or an image/music
  generator runs; the ring then says "waiting", so it doesn't look stuck.
- The menu bar icon carries a small dot while any project indexes.
- A project chat's header shows how many files it can search; answers
  show their sources as chips (file, page) that open the file there.
- Settings: the feature and each of its models, opt-in, with sizes;
  the disk each project's index uses and the app-wide total.
- **Statuses the user sees**, one mapping: copying / reading / OCR /
  describing / embedding / ready / empty / failed / not supported.
  `searchable` shows as *ready (words only, meaning search after
  embedding)*; `embedded` as *ready*; a hit found lexically only is
  marked so in the tool result. A project chat asked about a file that
  isn't ready gets that status from the tools and says so.
- **Formats offered**: the add flow accepts only what the installed
  version indexes (v1a, exactly: plain text, Markdown, code, PDF text
  layer, docx/doc/odt/rtf, HTML); anything else is refused at add with "not yet supported",
  never shown as searchable.
- **Disk limits**: per project and app-wide (Settings); add, re-index and
  compaction check free space first (a file: its size + index growth;
  compaction and migration: 1.2× the index); a failed swap is cleaned up
  at the next open.

## Tests (LLMTrayCore)

The pure logic lives in LLMTrayCore, where the tests are: schema and
triggers after insert/delete/`rebuild`; a crash at each ingest state,
then reconcile; short queries; ё/е and Latin/Cyrillic normalization;
RRF; budget truncation and dedup; earlier-result elision; the compaction
transcript without tool text; a citation id not in the results; a tool
call after the chat moved or the project was deleted; injection
documents with network tools on; searches during an ingest from two
tabs; opening a previous schema.

## Evidence

- System SQLite 3.54.0 here; FTS5 and `trigram` work with Cyrillic
  (`МЕНТАЦ` finds `Документация`); `load_extension` absent. Index spike
  (branch `spike/rag-index`, 24 tests): at 200k chunks the DB is
  2.08 GB (104 MB per 10k: trigram 32, chunks 28, vectors 20, pages 19,
  unicode61 6 — measured with 4 KB pages and no auto_vacuum; to be
  re-measured with the final layout); hybrid search p50 ~190 ms, p95 ~350 ms with the df gate
  (232 / 700 ms without), nearly all of it trigram ranking; dense
  scoring 5-8 ms, vectors loaded in 120-300 ms; ingest ~590 chunks/s
  with both FTS tables. PR 3.4a's scale run (210,975 chunks, 103 MB
  per 10k with 16 KB pages; the synthetic corpus puts nearly every query
  term above the gate): vectors loaded in 55 ms warm (a rowid range
  scan, no sort), hybrid p50 19 ms / p95 44 ms over 200 searches with a
  256 MB reader mmap, lexical-only p50 122 ms / p95 270 ms. macOS 13.2
  ships 3.39.5: trigram (3.34), `remove_diacritics 2` (3.27); FTS5 is
  checked at runtime (`sqlite_compileoption_used('ENABLE_FTS5')`).
- Brute force, 1 query, top-20, f32 `cblas_sgemv`: 50k × 1024 2.6 ms,
  200k 11 ms (5-8 ms tiled/parallel), 500k 40 ms. No vector index at
  project scale.
- bge-m3 fp16 on our MLX encoder: min cosine 0.99998 against
  sentence-transformers / FlagEmbedding on 52 texts (ru, en, mixed,
  code, up to 8k tokens), retrieval order identical; 8.0-9.4k tokens/s
  on 400-token chunks at any batch size, an 8k text in 1.85 s, peak
  ≤ 1.75 GB, load < 1 s, spawn to first vector 0.76 s. 200k chunks ×
  400 tokens ≈ 2.5 h of background indexing. RuBQ retrieval (MTEB
  results repository): bge-m3 71.2, multilingual-e5-large 74.1,
  multilingual-e5-large-instruct 69.2, EmbeddingGemma-300m 69.7.
- Vision rev3 `.accurate`, a clean Russian page: body near perfect,
  table cells column-wise; `RecognizeDocumentsRequest` (macOS 26+)
  returned rows and cells. PaddleOCR-VL-1.5 (0.96B, Apache-2.0) via
  mlx-vlm: character-exact incl. the table, 5.5 s; GLM-OCR (0.9B, MIT):
  3 character errors, 13.9 s. One page each.
- Chunking: 200-400 tokens without overlap had the best precision at
  equal recall (Chroma); page-level chunks were the most consistent
  (NVIDIA); contextual prefixes cut retrieval failures 35% (Anthropic).

Sources: sqlite.org/changes.html, /fts5.html, /wal.html;
github.com/embeddings-benchmark/results; huggingface.co/Qwen/
Qwen3-Embedding-0.6B; WWDC25 session 272; trychroma.com/research/
evaluating-chunking; developer.nvidia.com/blog/finding-the-best-
chunking-strategy-for-accurate-ai-responses; anthropic.com/engineering/
contextual-retrieval.

## Plan

1. **Spike (throwaway) — done 2026-09-26** (branches `spike/rag-index`,
   `spike/rag-extract`, `spike/rag-embed`; results above). Carried into
   v1a: injection documents against the real tools, and the index size
   re-measured with 16 KB pages and incremental auto-vacuum.
2. **Eval on extracted text**, run with the spike's code (no app changes
   needed): the user's 20-30 real documents through tier 1 (and the
   tier-2 prototype); questions include cross-file comparisons,
   whole-document summaries (expected: "insufficient coverage"), long
   tables, a just-added file; 40-60 questions with the answering
   page; recall@10 and MRR, lexical vs hybrid with bge-m3 (and
   USER-bge-m3 beside it); CER per tier. Sets the fusion weights, the
   chunk size and the recall target for v1a.
3. **v1a — text documents and PDF, behind a feature flag (beta)**, as separate PRs,
   each with its tests, in this order:
   1. **Supervised extractor**: `ProcessRunner`'s `posix_spawn` variant
      (process group, wall timeout, stdout cap, footprint polling,
      jetsam when available), `LLMTray --extract`, the capped zip reader,
      `HTMLText`, the junk check; packaged smoke test on macOS 14.
   2. **Project lifecycle**: New Chat in Project (the session and its
      project mapping created atomically before the first turn), project
      instructions, project deletion with deletion records, the
      projects/ layout.
   3. **Chat plumbing**: the token estimator and per-request budget,
      `withoutEarlierProjectResults`, compaction without tool text,
      citations in `ChatMessage`/`PersistedMessage` (with project and
      rev) and their chips, the per-call trust barrier.
   4. **The index and tools**, in two PRs: 4a `ProjectIndex` +
      `ProjectIndexRegistry` (schema, FTS, packed vectors,
      staging/reconcile, maintenance), the embed runner and registry
      (bge-m3), the background lane of `GenerationQueue`; 4b, after the
      chat plumbing, the indexing job and the three tools.
   5. **Files UI**: the Files view, the sidebar ring with Pause / Stop,
      the menu-bar dot, Settings opt-in.

   Exit gates: recall@10 on the eval's text documents at the target;
   injection documents passing with network and generator tools on; a
   search tool call p95 ≤ 1.5 s warm and ≤ 3 s cold (runner spawn
   included), measured while indexing and while a generator waits;
   combined peak memory within the Metal limit; the index re-measured
   with the final layout and the disk limits set from it; macOS 14
   packaged smoke test.
4. **v1b — every format**: tier 2 (Vision OCR, segmentation,
   perspective, `RecognizeDocumentsRequest` tables on macOS 26+), image
   descriptions (the small VLM), xlsx/pptx and .xls/.ppt, linked folders
   with FSEvents — **the full-workspace promise is gated here**. Exit:
   CER and recall on the scanned part of
   the eval set, description quality on the eval images, peak memory
   within the Metal limit.
5. **v2 — images as material**: project images for `edit_image` by a
   `doc` argument (pinned through Regenerate,
   [0011](0011-creator-mode-and-media-variants.md)).
6. **v3 — hard pages**: tier 3 benchmarked on the eval pages; a reranker
   (bge-reranker-v2-m3 or similar — not Qwen) kept only if it moves
   recall.

## Decided with the user (2026-09-26)

- Scale: 1-2k documents per project, brute force.
- Legacy .xls / .ppt: supported.
- Image descriptions: a small built-in VLM.
- Project instructions: yes.
- Copies or linked folders: both, the user picks per source.
- Embedder: bge-m3 by default, configurable, never Qwen.
- The whole feature and each of its models are opt-in in Settings;
  nothing is downloaded for users who don't turn it on.

## Open questions

- Spreadsheets: besides chunks (rows with their header), a tool that
  loads sheets into SQLite tables for the model to query (sums,
  filters)? Undecided; proposed as a v2 experiment once the eval shows
  whether table questions fail with chunks alone.
- The caps' values; the budget's share of the context.
