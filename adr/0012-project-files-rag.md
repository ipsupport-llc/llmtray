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
  records it, and a change re-embeds in the background while the old
  vectors keep answering. Candidates, decided on the user's documents
  (Plan, step 2): bge-m3 (MIT, 568M, 8k context, strong on Russian — the
  provisional default), USER-bge-m3 (bge-m3 tuned for Russian), Snowflake
  arctic-embed-l-v2.0 (Apache-2.0), multilingual-e5-large-instruct (MIT,
  512-token limit), EmbeddingGemma-300m. Licences and MLX support of the
  two not in the research yet are checked first.
- **Scale**: 1-2k documents, up to ~200k chunks per project, without a
  vector index — 200k × 1024 is ~16 ms per query in f32 (~4 ms with the
  multi-core f16 kernel); vectors kept f16 in memory (~400 MB) or at a
  smaller dimension where the model supports it. Indexing 1,000 documents
  × 20 pages is hours of background work at most: it shows progress,
  pauses for chat generation, resumes after a relaunch.
- **Extraction in tiers**, cheapest first; a page takes the first tier
  whose text passes the junk check: (1) text layer — PDFKit, docx/doc/
  odt/rtf via `NSAttributedString`, HTML via LLMTrayCore `WebParsing`,
  plain text and code, xlsx/pptx from their XML; (2) Vision OCR for
  scans and photos; (3) a document VLM for hard pages. Images get OCR
  and a short description, both indexed, so a photo is found by what it
  shows. All three tiers are in the product's scope; the plan orders
  them.
- **Retrieval, not stuffing**: no "whole project in the request" mode.
- **Files are immutable snapshots** copied into the project; replacing
  one is remove + add. The UI calls them copies.
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
- once a project tool has returned text in a turn, tools with
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

- `documents(doc, name, ext, sha256, bytes, added_at, status, pages,
  error)`; `doc` a small integer. `status`: staged → extracting →
  searchable → embedded | failed | removing.
- `pages(doc, page, text, tier, status, error)` — the raw extracted
  text: `read_project_file` quotes it; a failed page is retried from it.
- `chunks(id, doc, page, ord, heading, body)` — `body` normalized (NFC,
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
   the generic embed runner with two registry entries (bge-m3 and one
   other family) on MLX, matching reference vectors.
2. **Eval on extracted text.** The user's 20-30 real documents through
   tier 1 (and the tier-2 prototype); 40-60 questions with the answering
   page; recall@10 and MRR for lexical vs hybrid with each candidate
   embedder; CER per tier. Decides the default embedder.
3. **v1a — hybrid, safe, usable.** The embed runner and registry, the
   ML policy, `ProjectIndex` and the registry,
   ingestion and reconcile, tier 1 with the junk check, `--extract`,
   caps, the three tools, budget, elision, trust rules, compaction
   exclusion, citations, the Files view, New Chat in Project, deletion,
   the tests above. Exit: text-document recall on the eval set, the
   injection tests passing.
4. **v1b — every format**: tier 2 (Vision OCR, segmentation,
   perspective, `RecognizeDocumentsRequest` tables on macOS 26+), image
   descriptions, xlsx/pptx. Exit: CER and recall on the scanned part of
   the eval set, peak memory within the Metal limit.
5. **v2 — images as material**: project images for `edit_image` by a
   `doc` argument (pinned through Regenerate,
   [0011](0011-creator-mode-and-media-variants.md)).
6. **v3 — hard pages**: tier 3 benchmarked on the eval pages; a reranker
   (bge-reranker-v2-m3 or similar — not Qwen) kept only if it moves
   recall.

## Open questions (the user's to decide)

- Scale: 1-2k documents per project, or tens of thousands (then a
  vector index)?
- Legacy binary .xls / .ppt: unsupported ("save as xlsx/pptx"), .doc is
  read natively?
- Spreadsheets: besides chunks, a tool that loads sheets into SQLite
  tables for the model to query (sums, filters) — in v1 or later?
- Image descriptions: the chat model (sees images, ~10 s each, competes
  with generation) or a small VLM beside it?
- Project instructions (text added to every chat of the project)?
- Copies in the project folder, or references to the user's folders
  with re-indexing on change (less disk for many documents, more
  moving parts)?
- The caps' values; the budget's share of the context.
- Whether an original's later edits should ever be offered as an update
  (snapshots today).
