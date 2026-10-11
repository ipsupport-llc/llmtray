# 0020 — Documents: the chat makes a PDF, with charts; tools loaded when needed

**Status: accepted** (2026-10-10, by the user). The spike and the measurement it asked for are done: see "Spike and measurement".

## Decision

The chat model gets one tool that turns what it wrote into a finished
document: "put this together as a report", "make me a PDF of the plan
with a chart of the costs", "write a cover letter and give me the PDF".
The model writes the content; the app does the layout, so a document from
a 4B model looks as good as one from a 35B model.

- **Opt-in**, like every feature that writes files: off until turned on
  in Settings (Tools); without it the tool is never declared. Nothing is
  downloaded for it.
- **One tool, `make_document`**, modes by fields, not separate tools
  ([0007](0007-chat-tools.md), "as few tools as possible"):

  ```
  make_document(
    title,                      // also the file name
    content,                    // Markdown
    style?: report|letter|notes|invoice,   // default report
    charts?: [ { id, type: bar|line|pie, title?,
                 labels: [..], series: [ {name, values: [..] | formula} ],
                 range?: [from, to], unit? } ],
    format?: pdf                // the only one for now
  )
  ```

  A chart goes where the content says `![chart](chart:<id>)`; a chart the
  content never names goes at the end. A function plot gives each series a
  `formula` in `x` (`sin(x)`) and the chart a `range` (numbers or
  expressions like `2*pi`, default -10...10) instead of values: the app
  computes 101 points with the `calculate` tool's evaluator and draws a
  line over a number axis. A small model asked for "a sine chart" otherwise
  writes out a hundred made-up numbers -- slowly, and wrong. Labels that
  don't match the number of values give way to point numbers with a note;
  the numbers are what the chart is for. **Pictures come only from the
  project** (the user's rule): `![caption](project:<id>)`, the id
  `project_files` lists for a picture of the chat's project (see "Project
  pictures"). Not the chat's attached or generated images, not a folder's,
  nothing by path or URL; a chat outside a project has no pictures. The
  app reads the picture from the project's own storage and decodes it
  never at full size: the header's pixel count first (at most 100
  megapixels), then `CGImageSourceCreateThumbnailAtIndex` straight to
  at most 2400 px, in the bounded path of "Project pictures"; it
  re-encodes it (PNG, or JPEG for photos) without its metadata (no GPS
  or camera data goes into a document) and serves it as
  `llmtray-doc://image/<k>`. The model never gets the picture's bytes.
  An id that isn't a picture of this project, or one that fails to
  decode, is left out with a note. The model sends numbers, never
  drawings, CSS or HTML. Tables are Markdown tables in `content`, not
  charts. `ToolSchema` gains list kinds (`list(.string)`,
  `list(.number)`) with their JSON schema, lenient reading (a single value
  for a one-item list, `"5"` for 5) and errors, tested as the other kinds.
- **The app renders, locally**, in three steps:
  1. *Markdown to HTML* by our own converter in LLMTrayCore (the block
     rules of `ChatMarkdown`: headings, lists, tables, code, quotes,
     links), no new package. It emits only an allowlist (Hardening 2).
  2. *Charts* drawn by Swift Charts (`ImageRenderer`, capped size) to PNG,
     and pictures re-encoded as above, served to the page by our scheme
     (`llmtray-doc://chart/<id>`, `llmtray-doc://image/<k>`), not as
     `data:` URLs, so the page may load nothing else (Hardening 1).
  3. *Pages*: the HTML, with the style's CSS (system fonts only, so
     nothing is loaded for them; headings kept with what follows; a table
     of contents after the title of a report with four chapters or more;
     Letter or A4 by the Mac's region), printed by WebKit to a paginated
     PDF in a child process (`LLMTray --render-document <job folder>`,
     `DocumentRenderCLI`), supervised as extraction is: its own process
     group killed whole at 60 s, a 1.5 GB footprint limit (jetsam and
     polling), 4 KB of stdout, and a file-size limit it sets on itself
     (`RLIMIT_FSIZE`, 100 MB) so a runaway print dies before the
     parent's 50 MB check. The app writes the job (the page already
     built, the charts' numbers) into a fresh 0700 temp folder and deletes
     it after; the child draws the charts, prints, stamps and makes the
     thumbnail there. Before printing it waits for the page's images to
     decode, with the app's own script (`callAsyncJavaScript` in the
     default client world; the page's scripts stay off): printed earlier,
     a chart came out blank.
     `WKWebView.printOperation(with:)` with a save-to-file `NSPrintInfo`,
     the view in a borderless offscreen window, run with
     `runModal(for:delegate:didRun:contextInfo:)` (proven on macOS 14.8,
     15.7 and 27.2, below). Never `NSPrintOperation.run()` on a view
     outside a window: it ran away. The header (title) and footer (page N
     of M) are drawn by a `PDFPage` subclass (`PDFDocumentDelegate.
     classForPage`) and the document written by PDFKit, which keeps the
     link annotations; redrawing pages into a new `CGContext` drops them.
  Styles are a few fixed CSS files in the app, picked by name.
- **The result is a card in the chat**, like a generated image: the first
  page as a thumbnail, the title and page count, and Open (Preview),
  Show in Finder, Save As…, Add to Project (when the chat is in one).
  Add to Project calls `ProjectIndexer.addFiles([pdf], to: project)` on
  the main actor, the + menu's path ([0012](0012-project-files-rag.md)):
  Project files are turned on first if they're off
  (`enableProjectFiles`), and its notes (added, already in the project)
  show as they do for a drop.
- **Stored beside the chat's images, but not in memory.** Images and
  songs are `[Data]` loaded with the chat; a PDF can be 50 MB, so a
  message gets `documents` as metadata only (`DocumentRef`: an `id`
  (UUID), file name, title, pages, the `DocumentSource`), in `ChatMessage` and
  `PersistedMessage`. The PDF and its thumbnail (PNG, at most 400 px,
  under 100 KB) are files in the chat's `<uuid>-images/` folder
  ([0006](0006-chat-sessions-and-library.md)), never in the JSON, read
  only to show, open, save or share. `PersistedMessage.withoutFiles`,
  the sweep's referenced set, the save-time drop of empty assistant
  messages, `turnProducedSomething` (a document-only turn at the tool
  limit isn't "the model kept calling tools"), compaction's media check
  and the history entry's "has content" all count documents (one `hasContent` helper); the files go
  with the chat. **Not in temporary chats, for now.** They write nothing
  (0006), and the printing that works (save-to-file `NSPrintInfo`) writes
  a file; until a paginated in-memory path is proven, `make_document`
  isn't declared in a temporary chat by any path (not `always`, not
  `load_tools` — whose enum leaves `documents` out there — not the + menu's
  item, which isn't shown), and a call there is refused first, before
  any "call load_tools first", saying a saved chat can make documents. When one is: the PDF and thumbnail bytes sit
  in a session-scoped in-memory store keyed by the document's id (never
  in `Codable`), freed when the chat closes, written only when the user
  opens, saves or shares (the temp export of `MediaSharing`), Show in
  Finder not offered.
- **Regenerate**: Regenerate on the answer re-runs the turn as for any
  answer. "Make again" on the card re-renders from the saved call (a
  `DocumentSource`: the arguments, as `MediaSource` keeps a generator's)
  by its own small path (`regenerateDocument`): no generator queue, no
  model unload, no draft — it doesn't ask the model again. Pictures
  are read from the project again (one removed since: left out).
- **The model is told it's done**: the tool answers the title, the page
  count and that the user sees it in the chat; no path. It doesn't read
  the PDF back.
- Later, through the same tool: `format: docx` (Word, for editing) and
  `format: xlsx` for tables; `style` gains the user's own templates. Not
  in the first version.

## Project pictures

Projects take pictures beside documents, so a document can use them.
**Kept out of the search index**: a picture has no text, and
[0012](0012-project-files-rag.md)'s index (its schema, states, counts
and every query) stays exactly as it is. Pictures are a small store of
their own, `ProjectPictures` (LLMTrayCore), per project:
`pictures/<uuid>.<ext>` copies (mode 0600, `O_EXCL | O_NOFOLLOW`) and a
`pictures.json` manifest (id `p1`, `p2`… never reused, name, width,
height, bytes, SHA-256, added). When 0012's image OCR and descriptions
come, they may move pictures into the index; until then pictures are
never searched.

- **Formats**, exactly: png, jpg, jpeg, jfif, heic, heif, webp, tif,
  tiff, gif; at most 50 MB each, checked by size when the files are
  sorted for adding (`ProjectFileDrop.sort` and `add_to_project`'s
  candidate check), before anything is copied. Then the picture is
  checked and measured (below); one that isn't an image or has no
  dimensions is refused with "not a picture" and its copy removed. The
  same file twice (by SHA-256) is "already in the project".
- **Consistency**, as the index's ([0012](0012-project-files-rag.md),
  "Consistency", "Concurrency"): every change to a project's pictures
  holds the project's index writer lock (the same `flock`), so two
  tabs or flows never write the manifest at once; an add copies into
  `pictures/staging/`, is checked, then renamed into place before the
  manifest records it; the manifest is replaced atomically (temp file,
  `rename`); a removal takes the entry out of the manifest first, then
  the file. Opening the project reconciles: files the manifest doesn't
  name and staging leftovers are deleted, entries whose file is gone
  dropped. Pictures count toward the project's and the app's disk
  limits and usage.
- **Added** by the flows that add documents, which sort each file to its
  store: the project's Add Files…, the + menu's Add Files to the
  project, the project files window's drop, and `files(add_to_project)`
  from a granted folder ([0014](0014-folder-tools.md), its consent
  dialog). Dropping an image on a project chat still attaches it to the
  message for a vision model, as today; adding it to the project is the
  explicit path. Texts say what's true per kind: the consent dialog
  ("…can then search it" for a document, "…can then use it in
  documents" for a picture), `add_to_project`'s answer likewise, the add
  notes ("1 picture added"), and the format lines of the Add Files
  panel, the drop zone and the empty Files view ("…; pictures are kept
  for documents").
- **Shown apart.** The Files window gets a Pictures section
  (thumbnail, name, size, Remove); "Searches N files" and the ring
  count documents only, as now; a project with pictures only says "N
  pictures" in that line.
- **What the model sees.** `project_files`' listing ends with a
  `Pictures:` part after the documents' last page, `p1. name -- 1600×1200`
  per picture (names are file text, as documents' names are); when they
  don't fit there, a `pictures:N` cursor lists them on their own, page by
  page. A search or read in a project with no searchable document answers
  with the same listing, pictures included. The project's context counts pictures
  (`ProjectContext.pictures`): a project with pictures and no documents
  declares `project_files` in its listing-only mode, so the ids can be
  learned. Pictures aren't documents to `project_files`: its `doc`
  stays an integer, a `p` id there is the usual type error, and search,
  read and pin never see pictures. When `make_document` is declared,
  the listing's picture part starts with "use one in a document as
  ![caption](project:p1)" (`listing(… picturesUsable:)`); otherwise it
  says nothing about documents.
- **Decoding untrusted images** — check and measure at add, the
  window's thumbnail, and render — happens in a child process spawned
  exactly as extraction's (0012, "A child process": `posix_spawn`
  through `ProcessRunner`, its own process group killed whole, no
  network, the extraction's jetsam memory limit with the 20 ms footprint
  polling as backstop), as `LLMTray --decode-picture <in> --out <dir>`
  with a 10 s wall clock. The parent makes `<dir>` fresh (0700); the
  child writes the re-encoded picture there and prints one JSON line
  (width, height, bytes, or an error); the parent reads at most 16 MB
  of it and 4 KB of stdout, and deletes `<dir>` after. It reads the
  header incrementally without caching (as `FileClassifier` does),
  refuses above 100 megapixels before any decode, decodes frame 0 only
  (a GIF's other frames never), scales with
  `CGImageSourceCreateThumbnailAtIndex` (2400 px for a document, 400 for
  the window) and returns the re-encoded bytes (PNG, or JPEG for
  photos) without metadata, or an error. A picture that fails or times
  out is refused (add) or left out (render).
- **At render**, for each `project:<id>`: the chat still in the
  project, the id in its manifest, then decoded as above into memory —
  all before the page loads; the scheme handler serves only those bytes,
  nothing is read from disk while WebKit prints. The decoded pictures of
  one document total at most 60 MB; past that the rest are left out.
  The `DocumentSource` records the project's id with the call; Make
  again uses pictures only if the chat is still in that project (moved
  out: every picture left out, never another project's `p1`), and a
  picture removed since is left out.
- **Trust**: the listing's picture part is project text, as the rest of
  the listing; a picture's pixels reach no model through this, only
  `make_document`'s output. Looking at a project picture with a vision
  model is not part of this ADR.

## Hardening

A document is built from text the model wrote, and that text may come
from a project file, a folder file or a web page with instructions in it.

1. **Nothing executes, nothing loads.** The first line of defence is the
   converter: the page it makes loads nothing but `llmtray-doc:`
   (Hardening 2), and a test over hostile fixtures proves it emits no
   other resource URL (an `img` or the stylesheet), no `data:` and no
   `blob:`; links (`a href`, http/https/mailto, Hardening 2) are never
   loaded and are checked separately. Behind it, the printing web
   view: JavaScript off (`defaultWebpagePreferences.allowsContentJavaScript
   = false`, `javaScriptCanOpenWindowsAutomatically` off), a
   non-persistent data store, HTML loaded from a string with no base URL.
   A `WKContentRuleList` blocks every load (`url-filter` `.*`, every
   resource type) and then lets `^llmtray-doc:` and `^about:` through
   (`ignore-previous-rules`); WebKit's rule regexes have no `|`, so a
   deny-all with exceptions is also the simpler rule. Content rules don't
   see `data:` or `blob:`, which is why the converter guarantee comes
   first. The
   `WKNavigationDelegate` refuses every frame navigation but the initial
   load. `llmtray-doc:` (a `WKURLSchemeHandler`) serves only the style's
   CSS (built into the app) and this document's chart PNGs and
   re-encoded pictures, by a fixed table built before the page loads,
   never a path; with `Access-Control-Allow-Origin: *`, which a font
   from it would need (the styles use system fonts). Tested with a remote image, `file:`,
   `data:text/html`, `data:` SVG, a CSS `url()`, a `<script>`, an
   `onerror`, a `<meta http-equiv=refresh>`, a redirect.
2. **The converter can't emit markup from the content.** Raw HTML in
   the Markdown is text (a `<script>` comes out as those characters);
   every text and attribute value is escaped. It emits only these tags:
   `html head meta title body` (its own frame: `meta` only as `charset`), `p h1–h6 ul ol li table thead tbody
   tr th td pre code blockquote a strong em del hr br sup span img nav section
   link` (`link` only as the one stylesheet reference it places itself),
   and only these attributes: `class` (its own names), `href` on `a`,
   `src` and `alt` on `img` (a chart's or picture's `llmtray-doc:` address
   only),
   `rel="stylesheet"` and `href` on its own `link` (the style's
   `llmtray-doc:` address only),
   (a table cell's alignment is a class); the stylesheet is one `<link>` to the style
   it put there itself. Everything else (`style`, event handlers,
   `script`, `iframe`, `object`, `embed`, `svg`, `video`, `audio`,
   `source`, `form`, any other `meta`, `base`, `style`) never comes out. Images other than chart and
   picture references (`chart:`, `project:`) become their alt
   text. Links: only `http`, `https` and
   `mailto` stay links; any other scheme (`javascript:`, `file:`,
   `data:`) becomes plain text. Where a link's text isn't its address,
   the address is printed after it in small type (as print stylesheets
   do), so the PDF never hides where a link goes.
3. **Limits on what goes in and what comes out.** In: at most 8 charts,
   12 series, 500 points per chart (101 for a formula, at most 200
   characters); values finite; labels and titles
   capped; content at most 200,000 characters; at most 30 pictures. A
   bad chart or picture is left out with a note in the
   tool's answer, the rest is made; pictures past the 30th are left out
   the same way. "Over a limit: no document" is for the output limits
   below. Out: chart PNGs at
   most 2400×1600 px; at most 200 pages and 50 MB; rendering stops after
   60 s. Over a limit: no document, and the tool says which limit.
4. **It only writes its own new file.** No path comes from the model.
   The name is built from the title by one sanitizer: Unicode NFC,
   control characters and `/ : \` removed, no leading dot, trimmed to 80
   characters, empty → "Document"; the file is created with
   `open(O_CREAT | O_EXCL | O_NOFOLLOW)`, a " 2", " 3"… suffix on a
   collision, never over anything. Getting it anywhere else is the
   user's click (Save As…, Add to Project).
5. **Trust kind: ordinary**, and why not guarded
   ([0012](0012-project-files-rag.md), [0014](0014-folder-tools.md)):
   guarded tools are the ones that reach the network or start a
   generator — heavy queued work that can unload the chat model — after
   text a file brought in. `make_document` does neither: it can't send
   anything anywhere (Hardening 1), changes no existing file
   (Hardening 4), is bounded (Hardening 3), and its output only goes
   further by the user's click. Project pictures don't change that:
   their bytes go only into the document, never back to the model.
   Making a document from project, folder
   or pinned text is the point of the tool ("summarise these files into
   a report"), so it stays allowed after file text and with pinned
   files. If a later format ever fetches anything, that call becomes
   guarded.
6. **One document per turn**, with the generators' treatment
   ([0007](0007-chat-tools.md), Lessons): once made, the tool isn't
   declared again in the turn; a second call is refused with "already
   made — say if it should change", and that refusal is dropped from
   later turns (`ChatRequestBuilder.withoutEarlier`).

## Tools loaded when needed

Every declared tool is tokens in every request, and small models choose
worse among many tools (the user's rule, [0007](0007-chat-tools.md)).
`make_document` with charts is one of the bigger declarations (an
estimated 250–300 tokens). Declaring it only when it's needed:

- **The cost of a change.** In-app, tools go in the request's `tools`
  field, but the server's chat template renders them at the start of the
  prompt (Gemma 4, Qwen 3.5 and Nemotron put them in the system turn), so
  a different list is a different prefix and the prompt cache misses.
  The list already changes within a chat today (a spent generator, the
  trust barrier, the project's and folder's modes, a profile change), so
  loading adds one more such change, not a new kind. Measured: about a
  minute for a 30K-token chat on Gemma 4 26B (see "Spike and
  measurement"). A loaded group is **never removed**
  for the rest of the chat, and `load_tools` stays declared (40 tokens)
  so loading doesn't cost a second change.
- **Three settings per group** in the profile ([0005](0005-profiles.md)):
  a new optional field `tools.toolLoading: [group: always | onDemand]`
  beside `enabledTools`, merged **per group**, not as a whole field: for
  each group, the overlay's value, else Default's, else on demand (so an
  overlay that sets one group doesn't wipe Default's others).
  `toolLoading` is in `allFields` like every stored field (so the
  coverage test and Reset work); the override count counts it as its
  number of groups rather than as 1. A group off is simply
  not in `enabledTools`, as today. Old profiles without the field read
  as before. The field decodes leniently: values case-insensitive, an
  unknown group or value skipped with a log line, never failing the
  whole profile (synthesized `Codable` would throw on one bad value).
- **How a group gets declared:**
  1. *By the model.* With any on-demand group switched on, a small tool
     `load_tools(group)` is declared, its enum the groups with a phrase
     each (`documents: PDF documents with charts`). The model calls it
     on "make this into a document"; the answer says the tools are ready; the
     group is declared from the next request on.
  2. *By the user.* The composer's + menu gets "Make a Document…": the
     group is loaded from this message on. No text is added to the
     user's message; the tool's own description says when to use it.
  3. *Always*, for a user who wants it in every chat and has the
     context.
- **State, saved with the chat**: `loadedToolGroups` in the session file
  ([0006](0006-chat-sessions-and-library.md); temporary chats keep it in
  memory). `ChatToolbox.definitions(for:)` declares the groups switched
  on that are `always` or in `loadedToolGroups`. A call of a tool whose
  group isn't loaded (a model that saw it in another chat) is answered
  "call load_tools first", which it can, not "isn't available".
- **After file text, loading waits for the user.** `load_tools` is
  ordinary: declared, with the same enum, in every request of a chat
  that has an on-demand group switched on — also after its groups are
  loaded, so loading never changes the list a second time; a call for a
  group already loaded answers "already loaded" and changes nothing. It
  runs anytime. A group loaded by a call made after outside text in the turn
  (`hasUntrustedText` or `networkText`, pinned files included) goes to
  `pendingToolGroups`, and pending groups become loaded at the start of
  the user's next message, unconditionally — else a chat with pinned
  files, untrusted every turn, could never load one. A file can't hand
  the model a new tool in its own turn; the answer says so. What a
  loaded tool may then do is still the trust barrier's to decide.
- **The other tools later** (web, weather, country) take the same
  setting; out of this ADR's first step. Groups are data, so adding one
  is a line.

## Spike and measurement (2026-10-10)

**Printing.** A throwaway Swift script, run on this Mac (macOS 27.2) and
on GitHub's macos-14 (14.8.9) and macos-15 (15.7.9) runners: a 30-chapter
document with a chart, a table, a bundled font and the hostile fixtures
of Hardening 1, in a web view configured as above.
- Offscreen window + `runModal`: 61 Letter pages, a page break before
  every chapter (30 of 30), the bundled font (served with
  `Access-Control-Allow-Origin: *`) and the chart loaded through
  `llmtray-doc:`, 130 KB. The same on all three systems.
- Nothing ran or loaded: no `<script>`, no `onerror`; zero requests to a
  local HTTP server for the remote `<img>`, the CSS `url()`, the
  `<iframe>` and the meta refresh (the navigation delegate saw and
  refused the last two); `file:` and `data:` SVG images didn't render.
- `NSPrintOperation.run()` with the view in no window wrote a 979 MB
  file in 90 s and didn't finish: never used, and the output limits of
  Hardening 3 (size checked while printing, the 60 s stop) are needed
  in any case.
- `createPDF`: 2 pages of 612×14400 pt, as expected. Not used.
- Header/footer: the PDFKit page subclass keeps the link annotation
  (`https://example.com/`); a `CGContext` redraw lost it.

**Cache cost of a changed tool list.** The chat templates of Gemma 4
26B, Ornith 1.5 35B and FrogNano 4B (Qwen 3.5) and the Nemotron 3.5
LoRA, rendered by their tokenizers for a 20-exchange chat (about 7,300
tokens) with and without one more tool: the token sequences part after
90–138 tokens, so 98% of the prompt is prefilled again. At the prefill
speeds in this Mac's speed journal (medians: Gemma 4 26B 520 tokens/s,
FrogNano 4B 870–920), a 30K-token chat costs about 58 s (Gemma) or
33 s (FrogNano) once. Hence: a group is loaded once and never removed,
and `load_tools` stays declared. The same cost already follows every
mid-chat change of the tool list today (the trust barrier dropping
guarded tools after a project read, a spent generator): worth a
separate look, not part of this ADR.

## Verification

- Unit tests (LLMTrayCore): the converter (every block, raw HTML
  escaped, no attribute but the allowed ones, link schemes, link
  addresses shown, chart and picture references, a picture's metadata
  stripped, unknown images to alt text); chart
  validation (caps, non-finite values, unknown types); the file-name
  sanitizer (NFC, separators, leading dot, collisions); `ToolSchema`
  list kinds; `load_tools` (sticky, saved with the chat, pending after
  file text until the next user message, with pinned files too); the
  profile field's per-group merge, an old profile, a bad hand edit.
- Project pictures: each format added; a renamed non-image, one over
  50 MB and one over 100 megapixels refused (the last before decoding);
  a duplicate by hash; the manifest's ids never reused; listing,
  the listing with and without documents on, a pictures-only project's
  listing-only mode, a `p` id refused by `project_files`; a manifest
  reconciled after a crash mid-add; removed with
  its copy; a document with a picture of another project, a removed one
  or past 60 MB leaves it out; metadata gone from the embedded copy; the
  decoder child killed at 10 s.
- Rendering tests: a fixed document in each style to PDF, page count and
  extracted text (PDFKit) checked; the hostile fixtures of Hardening 1
  load nothing; the output limits fail cleanly.
- `--run-tool make_document '<json>'` writes the PDF into the current
  folder and prints its path (the other tools print text only); the CLI
  declares every group as loaded; `scripts/eval_tool_choice.py` gets prompts that need a document
  (called, through `load_tools` when on demand) and ones that don't
  ("hi", "explain this": not called).
- Manual: a report with a table and two charts from a project file, a
  letter, an invoice; Open, Save As…, Add to Project with files off;
  Make again; a temporary chat (`make_document` not declared, a direct call refused, nothing written); a chat
  reopened after a restart keeps its documents and its loaded group.
