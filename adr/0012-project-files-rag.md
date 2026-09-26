# 0012 — Project files: a local micro-RAG

**Status: proposed** (2026-09-26). Nothing here is built yet. Numbers
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
  normalized, no query/document prefixes; RuBQ retrieval 71.2 against
  mE5-large-instruct 69.2 and EmbeddingGemma 69.7; MLX conversions exist
  (mlx-community). No MRL: vectors stay 1024-d, ~400 MB f16 at 200k
  chunks. Its sparse and multi-vector outputs are not used in v1 — FTS5
  covers the lexical side. Other registry entries (USER-bge-m3, tuned
  for Russian; arctic-embed-l-v2.0; multilingual-e5-large-instruct;
  EmbeddingGemma-300m) stay possible per project.
- **Scale**: 1-2k documents, up to ~200k chunks per project, without a
  vector index — 200k × 1024 is ~16 ms per query in f32 (~4 ms with the
  multi-core f16 kernel); vectors kept f16 in memory (~400 MB) or at a
  smaller dimension where the model supports it. Indexing 1,000 documents
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
- `search_project_files(query, top_k = 5, ≤ 10)` — once any file is
  searchable; hits as `[doc:page]`, heading, the chunk, a neighbour only
  while budget remains;
- `read_project_file(doc, from_page, to_page)` — bounded by tokens, not
  pages.

**Budget.** Nothing in the chat counts prompt tokens today (auto-compact
counts messages). Project results get a per-turn budget in
`ChatToolbox`, reset in `startTurn()` like `imagesThisTurn`: a share of
`maxTokensCap − max_tokens` (~25%, hard-capped); a result past it is
truncated with a marker; a chunk already returned this turn isn't sent
again; once spent, search and read stop being declared — as spent
generators are ([0007](0007-chat-tools.md)); listing stays.

**Earlier results.** Live chats resend old tool messages every turn;
saved chats drop them (`persistCurrentSession` skips `role == "tool"`),
so a reloaded chat would lose its evidence and a live one grow ~5-10k
tokens per search. A `withoutEarlierProjectResults` step, beside
`withoutEarlierRefusals`, drops earlier turns' project tool calls and
their results together, leaving the answer (with its citations): what a
reloaded chat has, so the request is the same live and reloaded. The
model searches again when it needs the text.

**Trust**, deterministic:

- document text reaches the model only as project tool results, framed
  as quoted material with its `[doc:page]`;
- a batch of tool calls that includes a project read has its network
  and generator calls refused up front, before drafts, queueing or
  unload; and once a project tool has returned text in a turn, tools with
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

**Citations.** The model writes `[3:12]` (doc 3, page 12). `ChatMessage`
and `PersistedMessage` gain `citations: [Citation(doc, page, chunk)]`
(`decodeIfPresent`, `chunk` optional), collected per answer like
`sourcesByAnswer`, from the pages search or read returned this turn
only; a citation in the text that matches none stays plain text. A citation opens the copy at
that page, or says the file was removed. After compaction citations are
text only.

## The index

```
Application Support/LLMTray/projects/<projectID>/
  files/<doc>.<ext>     the copy
  staging/              copies in progress
  index.sqlite (+ -wal, -shm)
```

- `documents(doc, source, rev, name, ext, sha256, bytes, added_at, status, pages,
  error)`; `doc` a small integer. `status`: staged → extracting →
  searchable → embedded | failed | removing.
- `pages(doc, rev, page, text, tier, status, error)` — the raw extracted
  text: `read_project_file` quotes it; a failed page is retried from it.
- `chunks(id, doc, rev, page, ord, heading, body)` — `body` normalized (NFC,
  ё→е, case; look-alike Latin/Cyrillic kept distinct) with the heading
  path as prefix; 300-500 tokens by structure, no overlap, a table its
  own chunk with its header row.
- `chunks_fts` (`unicode61 remove_diacritics 2`) and `chunks_tri`
  (`trigram`), both external content on `chunks(body)`, kept in step by
  triggers, `'rebuild'` as the repair. Queries shorter than 3 characters
  go to `chunks_fts` only (trigram can't match them).
- `meta(schema, ...)`. On a schema change the derived tables (`pages`,
  `chunks`, both FTS, vectors) are dropped and rebuilt from `files/`;
  `documents` — user state — migrates only by explicit ALTERs.

**Consistency.** Add: copy into `staging/`, hash, rename to `files/`,
insert `documents`; extraction writes `pages`, chunks and FTS in one
transaction → `searchable`. Remove: `removing` in a transaction, delete
the file, delete the rows in a transaction. Re-index: rebuild the
document's derived rows in one transaction; the old ones stay searchable
until it commits. At project open a reconcile pass finishes or undoes
every state (staging leftovers, files without rows, rows without files,
interrupted extraction, `removing`).

**Linked folders.** A `sources(id, kind, bookmark, path)` table: `copy`
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
source drops its rows and never touches the user's files; only copies
under `files/` are ever deleted.

**Concurrency.** An app-wide `ProjectIndexRegistry` owns one writer per
project (tabs don't: `ChatToolbox` is per tab) plus a read-only WAL
connection for searches, so tabs don't queue behind an ingest. No
`await` while a transaction is open: extract first, then write
synchronously. Checkpoint when ingest goes idle and on close.

**Deletion.** `deleteProject` (today it only edits `library.json`)
cancels the project's jobs, closes its connections, writes a deletion
record, removes the directory, then drops the record; at launch pending
records are finished. A directory with no project and no record is left
alone (an unreadable `library.json` loads as empty today — sweeping on
it would delete a user's files).
Open tabs of its chats get "project removed" from the tools.

## Extraction

Parsers see hostile input. Extraction runs in a child process of the
app binary (`LLMTray --extract <path>`, like `--run-tool`, through
`ProcessRunner`): a crash, a hang past the time limit, or memory past a
cap kills that process, not the app. Limits: bytes per file, pages,
pixels, time per file, text per document; type from content, not the
extension. `NSAttributedString`'s HTML import is WebKit-based and
main-thread-only, so HTML goes through `WebParsing` instead. The junk
check (letters per glyph, replacement characters, look-alike code points
— PDFKit returned Cyrillic "к" as U+0138 in a test) is in v1: bad text
must not become `searchable`. Per-project caps (files, bytes, chunks)
and a free-space check before a copy are in v1.

- **Tier 2 (v2)**: `VNRecognizeTextRequest` rev3 `.accurate` (Russian
  from macOS 13), document segmentation + perspective correction for
  photos, `RecognizeDocumentsRequest` for tables on macOS 26+.
- **Tier 3 (v3)**: PaddleOCR-VL-1.5 or GLM-OCR via mlx-vlm, as a
  `GenerationQueue` client like the generators
  ([0009](0009-media-generators.md)).

## Dense retrieval

- Vectors `(chunk, model, dim, v f16)`, widened to f32 in memory for
  open projects only; `model` recorded, so a change re-embeds.
- `embedded` is a second commit after `searchable`: lexical works from
  extraction on, and a crash while embedding costs only the embedding.
- The embedder is a managed bidirectional runner (JSON lines, request
  ids, bounded messages, timeouts, cancellation, restart, the orphan
  marker) — `ProcessRunner.runStreaming` is one-shot. It runs for
  indexing and for the query only, as a `GenerationQueue` client: never
  beside an image or music generator, exiting when one takes the ticket.
  Its fit is measured against the Metal limit (~19 GB by default on this
  Mac), not the 26 GB of RAM.
- A query while it can't run falls back to lexical, and says so.
- The runner is generic over the registry's families (XLM-R for the
  bge-m3 line and e5, Gemma for EmbeddingGemma, …) on MLX; each entry
  ships with reference vectors so a conversion is checked on load.

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
  (`МЕНТАЦ` finds `Документация`); `load_extension` absent. macOS 13.2
  ships 3.39.5: trigram (3.34), `remove_diacritics 2` (3.27); FTS5 is
  checked at runtime (`sqlite_compileoption_used('ENABLE_FTS5')`).
- Brute force, 1 query, top-20, f32 `cblas_sgemv`: 50k × 1024 2.7 ms,
  500k × 1024 40 ms. No vector index at project scale.
- Qwen3-Embedding-0.6B (measured before Qwen was ruled out, kept as a
  speed reference) under mlx-lm: ~6,400 tokens/s at batch 16, 1.8 GB peak. RuBQ retrieval: 0.6B 66.9, bge-m3
  71.2, mE5-large 74.1, Qwen3-4B 73.7 (MTEB results repository).
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

1. **Spike (throwaway).** Schema, triggers, both FTS tables on a few
   hundred chunks; `--extract` on hostile samples (corrupt PDF, zip-bomb
   docx, remote-loading HTML); injection documents against the tools;
   legacy .xls / .ppt: xlrd-style BIFF parsing for .xls, the text
   records of .ppt's binary stream, or Quick Look rendering + OCR as the
   fallback — whichever gives full text on sample files;
   the generic embed runner with bge-m3 on MLX, matching the reference
   (FlagEmbedding / sentence-transformers) vectors, plus a second
   registry entry of another family to prove the registry isn't bge-only;
   bge-m3's own indexing speed and peak memory measured (the speed under
   Evidence is Qwen's).
2. **Eval on extracted text.** The user's 20-30 real documents through
   tier 1 (and the tier-2 prototype); 40-60 questions with the answering
   page; recall@10 and MRR, lexical vs hybrid with bge-m3 (and
   USER-bge-m3 beside it); CER per tier. Sets the fusion weights, the
   chunk size and the recall target for v1a.
3. **v1a — hybrid, safe, usable.** The embed runner and registry, the
   ML policy, `ProjectIndex` and the registry,
   ingestion and reconcile, tier 1 with the junk check, `--extract`,
   caps, the three tools, budget, elision, trust rules, compaction
   exclusion, citations, the Files view, New Chat in Project, project
   instructions, deletion,
   the tests above. Exit: text-document recall on the eval set, the
   injection tests passing.
4. **v1b — every format**: tier 2 (Vision OCR, segmentation,
   perspective, `RecognizeDocumentsRequest` tables on macOS 26+), image
   descriptions (the small VLM), xlsx/pptx and .xls/.ppt, linked folders
   with FSEvents. Exit: CER and recall on the scanned part of
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

## Open questions

- Spreadsheets: besides chunks (rows with their header), a tool that
  loads sheets into SQLite tables for the model to query (sums,
  filters)? Undecided; proposed as a v2 experiment once the eval shows
  whether table questions fail with chunks alone.
- The caps' values; the budget's share of the context.
