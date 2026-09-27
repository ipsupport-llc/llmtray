# Spike: extraction tier 1 for ADR 0012 (throwaway)

A standalone SwiftPM package, system frameworks only. It is not linked into the app.
Measured on an M5 (26 GB) running macOS 27.2 (26B5091g), release builds, 2026-09-26.
Nothing was tested on macOS 13.

- `extract <path>` stands in for `LLMTray --extract`. It prints one JSON line per
  page, sheet or slide: `{page, text, tier, junk_score, error, name?, truncated?}`.
  It exits 2 on a handled failure.
- `supervise [--timeout S] [--mem MB] [--jetsam MB] [--max-out B] -- child…` is the
  parent. It starts the child with `posix_spawn` in its own process group and
  kills the group when the child passes the wall-clock limit, the polled
  `phys_footprint` limit or the stdout cap. It can also ask the kernel for a
  fatal memory limit when it spawns the child.
- `makesamples <dir>` builds every generated sample and hostile file.
  `scripts/fetch_poi.sh` downloads the public Apache POI test files.
- `probe` holds the measurement helpers: junk signals, a memory hog with
  rlimits, raw XMLParser, NSAttributedString on the main thread or a
  background thread, sandboxed connect, and Vision OCR.
- The `scripts/*.py` files are the test drivers. They use xlrd, openpyxl and
  python-pptx as references for measurement only.

```
swift build -c release
.build/release/makesamples /tmp/x/gen            # --skip-big: no 1 GB text or 2 GB bombs
sh scripts/fetch_poi.sh /tmp/x/poi
python3 scripts/hostile.py --jetsam 1024 --timeout 20 /tmp/x/gen/zipbomb*.docx …
```

## Results

**Completeness against reference readers:**

| Format | Samples | Result |
|---|---|---|
| .xls vs xlrd 2.0.1 | 20 POI files (BIFF5 and 8, SST+CONTINUE, 1904 dates, DBCS, rich text), 2 user files read in place, and a 5,000-row Cyrillic xlwt file | 46,688 / 46,688 cells (100%). Both encrypted files end in a clean "password-protected" error. |
| .xlsx vs openpyxl | 8 POI files | 392 / 392 cells (100%) |
| .pptx vs python-pptx | 8 POI files | 397 / 397 words (100%), notes included |
| .ppt | 17 POI files | All text and notes that PowerPoint shows. No reference reader was available, so these were checked by hand against Quick Look. |

**Timing.** Each figure is the median of 3 runs. "Extract" is the child's
own time; "wall" adds starting the process.

| File | Pages | Chars | Extract | Wall | Peak |
|---|---|---|---|---|---|
| PDF, 100 pages (ru+en, CoreText) | 100 | 158k | 450 ms | 470 ms | 29 MB |
| docx, 100 pages (NSAttributedString) | 1 | 158k | 69 ms | 97 ms | 6 MB |
| doc, 100 pages | 1 | 158k | 82 ms | 98 ms | 5 MB |
| odt, 100 pages | 1 | 158k | 75 ms | 93 ms | 6 MB |
| rtf, 100 pages | 1 | 158k | 84 ms | 100 ms | 4 MB |
| html, 100 pages (own parser) | 1 | 159k | 43 ms | 71 ms | 3 MB |
| xlsx, 5,000 rows × 9 columns | 2 | 474k | 273 ms | 284 ms | 12 MB |
| xls, 5,000 rows × 8 columns | 2 | 787k | 163 ms | 189 ms | 16 MB |
| PDF, 30,000 pages (5,000-page cap) | 5,000 | – | 4.0-6.5 s | | 57 MB |
| text, 1 GB (32 MB text cap) | 33 | 33 MB | 1.9 s | | 17 MB |

For comparison, NSAttributedString's HTML import of the same 100-page file
took 373-504 ms.

**Legacy .xls and .ppt, three approaches** (`scripts/ql_compare.py`, `scripts/ql_ocr.py`):

- **(a) Own CFB + BIFF / PPT-record parser.** Complete, as shown above.
  It takes 2-15 ms per file (0.25 s for 5,000 rows). It detects encryption
  (FILEPASS, and the encrypted token in Current User). A fast-saved or
  corrupted .ppt is handled through the persist directory.
- **(b) Quick Look (`qlmanage -p`, OfficeImport HTML).** It takes 0.2-4.5 s
  per file, 10-100× slower than (a).
  - It drops .ppt notes.
  - It returns nothing for a BIFF5 .xls.
  - It covers only 36% of the words in a 7-sheet workbook.
  - It **hung for more than 60 s** on `57272_corrupted_usereditatom.ppt`, a
    file that (a) reads in 2 ms.
  - `textutil` does not read .xls or .ppt; it dumps the raw bytes.
- **(c) Quick Look thumbnail plus Vision OCR.** It sees the first slide or
  sheet only. Word recall against (a) was 0.9-100%, with a median around 36%.

**Recommendation: (a).** OCR stays the tier-2 path for scans only.

**Hostile inputs.** All runs used `supervise --jetsam 1024 --timeout 20`:

| Input | Outcome |
|---|---|
| truncated PDF, garbage after `%PDF-`, `/Count 2e9` lie, page-tree loop | PDFKit refuses to open it. Clean error in about 25 ms. |
| PDF corrupted in its middle half | 100 pages recovered |
| MediaBox 1e9 × 1e9 | Text is fine in 49 ms. Tier 2 needs a pixel cap before rendering. |
| 30,000-page PDF | Page cap (5,000) reached in 4-6.5 s. With no page cap, `--timeout 2` kills it, and `RLIMIT_CPU 1` kills it with SIGXCPU. |
| **2 GB-member zip-bomb docx (1.9 MB file)**, handed to NSAttributedString as it is | **Peak footprint 14.3 GB, 13.5 s** with no limits. The jetsam limit kills it at 1,002 MB. Polling kills it at 1,049 MB. |
| the same bomb after the zip pre-check | Refused in 2 ms: "declares 2000000167 bytes > cap" |
| the bomb with a lying declared size (4 KB) | Stopped by the inflate cap in 52 ms, with a 2 MB peak |
| xlsx sheet bomb | That sheet ends in a per-sheet error. The other sheets are unaffected. |
| nested bomb in `word/embeddings` (10 GB after inflation) | The embeddings are never opened. Text comes out fine. |
| 100k-entry zip | Entry cap |
| billion laughs, XXE in `sharedStrings.xml` | Refused: the part has a DOCTYPE. Raw XMLParser (libxml2) also rejects billion laughs by itself in 0 ms (error 111), and it never resolves SYSTEM entities even with `shouldResolveExternalEntities = true`. |
| XML nested 200,000 deep | The walker's depth cap (256) stops it. Raw XMLParser parsed it in 28 ms. |
| HTML with remote css, js, img, iframe, srcset, @import and meta refresh | 0 connections to the local listener from the own parser, from NSAttributedString `.html`, from a docx with an external image, from RTF `INCLUDEPICTURE` and from qlmanage |
| **mutated 18 KB RTF** (`fixtures/rtf_hangs_textkit.rtf`) | **NSAttributedString and `textutil` loop forever** at 2 MB. Only the wall-clock kill ends it. |
| 1 GB text | Over the 512 MB file cap, so refused in 2 ms. With the cap raised, the text is read in 1 MB slices and stops at the 32 MB text cap. |
| 1,350 mutated files across 9 formats | 0 crashes, 1 hang (the RTF above), 0 memory kills |

## Resource limits on macOS: what works

- **`setrlimit` RLIMIT_AS, RLIMIT_DATA and RLIMIT_RSS fail with `EINVAL` on
  macOS 27.** Setting the soft limit, the hard limit, or both makes no
  difference, and `ulimit -v`, `-d` and `-m` fail the same way. The limit
  stays at infinity, and a 3 GB hog runs to the end.
- **RLIMIT_CPU works.** The child is killed with SIGXCPU. RLIMIT_CORE=0
  and RLIMIT_FSIZE are accepted.
- **The private `posix_spawnattr_setjetsam_ext` works as a normal user.** The
  flags were `0x8000|0x04|0x08` (set, active-fatal, inactive-fatal) with
  priority −1. The kernel SIGKILLs the child at the limit: `max_rss` was
  504 MB against a 500 MB limit, and 2,003 MB against 2,000 MB. There is
  no overshoot. Each kill writes a `JetsamEvent-*.ips` report ("per-process-limit")
  to /Library/Logs/DiagnosticReports; these appear to be rate-limited.
  `memorystatus_control(SET_JETSAM_TASK_LIMIT)` on the process's own pid
  returns EPERM, so the limit must be set at spawn. That means using
  `posix_spawn`: Foundation's `Process` and today's `ProcessRunner` cannot
  set it.
- **Polling `proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint`** is the
  public fallback. It works, but it overshoots by roughly the allocation
  rate times the poll interval. The hog allocates about 15 GB/s. Measured
  peaks against a 500 MB limit: 521 MB at a 20 ms poll, 536 MB at 5 ms,
  871 MB at 100 ms.
- **`sandbox_init("no-network")`, applied in the child before it opens the
  file, works.** It is deprecated but functional. `connect()` and
  URLSession return "Operation not permitted", and file reads still work.
  It is a cheap guarantee that tier 1 never uses the network.

## Other findings

- **Main thread.** On macOS 27, `NSAttributedString` imports docx, doc,
  odt, rtf and WordML fine on a background thread. Even `.html` works
  there, because the import now runs in an XPC service
  (`UIFoundation.framework/XPCServices/nsattributedstringagent`). That
  service logged `ExcUserFault` (EXC_GUARD) reports during the tests. This
  is OS-dependent; macOS 13 uses in-process WebKit on the main thread. The
  own parser avoids the question. Inside the child, running on the main
  thread is free anyway.
- **`WebParsing.text` is not reusable for documents.** It keeps
  `<script>`, `<style>` and comment content, collapses every newline, and
  decodes only 7 named entities. `decodeEntities` is reusable. The spike's
  `HTMLText` does the rest: a single byte pass that skips
  script, style, head, svg and template, keeps paragraphs, list items and
  table rows as "a | b", and decodes about 60 named entities plus numeric
  ones.
- **Junk check.** It flags every broken ToUnicode map the spike built into
  real PDFs (U+0138 for к, Latin look-alikes, PUA, U+FFFD, symbol soup) and
  the cp1251-as-WinAnsi mojibake when there is no ToUnicode. Its signals
  are the max of: U+FFFD share, control-character share, PUA share,
  Cyrillic words mixed with Latin/Greek/Latin-Extended, Latin-1-letter
  share, and letters+digits per glyph. It scored 0 on fr, de, pt, cs, is,
  sv, tr, vi, uk, kk, zh, number tables and code. The worst clean score
  was Icelandic at 0.17 (Latin-1 share 0.20). The cut-off is 0.5.
- **Detection by content** handles files with the wrong extension:
  xlsx named .docx, pdf named .txt, doc named .xls. It also distinguishes
  encrypted OOXML (CFB with `EncryptedPackage`), cp1251 text and UTF-16 text.
  WordML 2003 `.xml` comes out as plain text.
