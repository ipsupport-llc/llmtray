# 0020 — Documents: the chat makes a PDF, with charts; tools loaded when needed

**Status: proposed** (2026-10-10). Nothing is built before the user accepts it.

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
                 labels: [..], series: [ {name, values: [..]} ],
                 unit? } ],
    format?: pdf                // the only one for now
  )
  ```

  A chart goes where the content says `![chart](chart:<id>)`; a chart the
  content never names goes at the end. The model sends numbers, never
  drawings, CSS or HTML. Tables are Markdown tables in `content`, not
  charts. `ToolSchema` gains list kinds (`list(.string)`,
  `list(.number)`) with their JSON schema, lenient reading (a single value
  for a one-item list, `"5"` for 5) and errors, tested as the other kinds.
- **The app renders, locally**, in three steps:
  1. *Markdown to HTML* by our own converter in LLMTrayCore (the block
     rules of `ChatMarkdown`: headings, lists, tables, code, quotes,
     links), no new package. It emits only an allowlist (Hardening 2).
  2. *Charts* drawn by Swift Charts (`ImageRenderer`, capped size) to PNG,
     served to the page by our scheme (`llmtray-doc://chart/<id>`), not
     as `data:` URLs, so the page may load nothing else (Hardening 1).
  3. *Pages*: the HTML, with the style's CSS (fonts, margins, `@page`
     size, page breaks before chapter headings, a table of contents for
     a long report), printed by WebKit to a paginated PDF
     (`WKWebView.printOperation(with:)` with a save-to-file
     `NSPrintInfo`, in an offscreen window if it needs one — **a spike on
     macOS 14 proves it before the build**, and this ADR is updated with
     what works; `createPDF` is no fallback, it makes one endless page). The
     header (title) and footer (page N of M) are drawn onto the finished
     pages with PDFKit, not by CSS, which WebKit's printing honours only
     in part.
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
  message gets `documents` as metadata only (`DocumentRef`: file name,
  title, pages, a small thumbnail, the `DocumentSource`), in
  `ChatMessage` and `PersistedMessage`. The file is in the chat's
  `<uuid>-images/` folder ([0006](0006-chat-sessions-and-library.md)),
  read only to open, save or share it. `PersistedMessage.withoutFiles`,
  the sweep's referenced set, compaction's media check and the history
  entry's "has content" all count documents; the file goes with the
  chat. **Temporary chats write nothing** (0006): the PDF stays in
  memory while the chat is open and goes to disk only when the user
  opens, saves or shares it (the temp export of `MediaSharing`); Show in
  Finder isn't offered there.
- **Regenerate**: Regenerate on the answer re-runs the turn as for any
  answer. "Make again" on the card re-renders from the saved call (a
  `DocumentSource`: the arguments, as `MediaSource` keeps a generator's)
  by its own small path (`regenerateDocument`): no generator queue, no
  model unload, no draft — it doesn't ask the model again.
- **The model is told it's done**: the tool answers the title, the page
  count and that the user sees it in the chat; no path. It doesn't read
  the PDF back.
- Later, through the same tool: `format: docx` (Word, for editing) and
  `format: xlsx` for tables; `style` gains the user's own templates. Not
  in the first version.

## Hardening

A document is built from text the model wrote, and that text may come
from a project file, a folder file or a web page with instructions in it.

1. **Nothing executes, nothing loads.** The first line of defence is the
   converter: the page it makes references nothing but `llmtray-doc:`
   (Hardening 2), and a test over hostile fixtures proves it emits no
   other URL, no `data:` and no `blob:`. Behind it, the printing web
   view: JavaScript off (`defaultWebpagePreferences.allowsContentJavaScript
   = false`, `javaScriptCanOpenWindowsAutomatically` off), a
   non-persistent data store, HTML loaded from a string with no base URL.
   A `WKContentRuleList` blocks `http`, `https`, `file` and `ws(s)` loads
   of every resource type (document, image, style-sheet, script, font,
   media, svg-document, raw, popup); content rules don't see `data:` or
   `blob:`, which is why the converter guarantee comes first. The
   `WKNavigationDelegate` refuses every frame navigation but the initial
   load. `llmtray-doc:` (a `WKURLSchemeHandler`) serves only the style's
   bundled CSS and fonts (with `Access-Control-Allow-Origin: *`, which
   fonts from another origin need) and this document's chart PNGs, by a
   fixed table, never a path. Tested with a remote image, `file:`,
   `data:text/html`, `data:` SVG, a CSS `url()`, a `<script>`, an
   `onerror`, a `<meta http-equiv=refresh>`, a redirect; and that the
   fonts load.
2. **The converter can't emit markup from the content.** Raw HTML in
   the Markdown is text (a `<script>` comes out as those characters);
   every text and attribute value is escaped. It emits only these tags:
   `html head body` (its own frame), `p h1–h6 ul ol li table thead tbody
   tr th td pre code blockquote a strong em del hr br sup img nav section`,
   and only these attributes: `class` (its own names), `href` on `a`,
   `src` and `alt` on `img` (a chart's `llmtray-doc:` address only),
   `align` on table cells; the stylesheet is one `<link>` to the style
   it put there itself. Everything else (`style`, event handlers,
   `script`, `iframe`, `object`, `embed`, `svg`, `video`, `audio`,
   `source`, `form`, `meta`, `base`, `style`) never comes out. Images other than chart
   references become their alt text. Links: only `http`, `https` and
   `mailto` stay links; any other scheme (`javascript:`, `file:`,
   `data:`) becomes plain text. Where a link's text isn't its address,
   the address is printed after it in small type (as print stylesheets
   do), so the PDF never hides where a link goes.
3. **Limits on what goes in and what comes out.** In: at most 8 charts,
   12 series, 500 points per chart; values finite; labels and titles
   capped; content at most 200,000 characters. A bad chart is left out
   with a note in the tool's answer, the rest is made. Out: chart PNGs at
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
   further by the user's click. Making a document from project, folder
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
  loading adds one more such change, not a new kind. **Measured before
  the build**: prefill time of a 30K-token chat with and without a tool
  added (an M5 laptop, Gemma 4 26B). A loaded group is **never removed**
  for the rest of the chat, and `load_tools` stays declared (40 tokens)
  so loading doesn't cost a second change.
- **Three settings per group** in the profile ([0005](0005-profiles.md)):
  a new optional field `tools.toolLoading: [group: always | onDemand]`
  beside `enabledTools`, merged **per group**, not as a whole field: for
  each group, the overlay's value, else Default's, else on demand (so an
  overlay that sets one group doesn't wipe Default's others; the
  overlay's override count counts its groups). A group off is simply
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
  ordinary: declared while a switched-on group isn't loaded, and it runs
  anytime. A group loaded by a call made after outside text in the turn
  (`hasUntrustedText` or `networkText`, pinned files included) goes to
  `pendingToolGroups`, and pending groups become loaded at the start of
  the user's next message, unconditionally — else a chat with pinned
  files, untrusted every turn, could never load one. A file can't hand
  the model a new tool in its own turn; the answer says so. What a
  loaded tool may then do is still the trust barrier's to decide.
- **The other tools later** (web, weather, country) take the same
  setting; out of this ADR's first step. Groups are data, so adding one
  is a line.

## Verification

- A spike first (macOS 14 and 27): headless paginated PDF from a
  `WKWebView` with the hardening above, page breaks and a 30-page
  document; PDFKit header/footer stamping. Its result goes into this ADR
  before the build. Then the prefill measurement above.
- Unit tests (LLMTrayCore): the converter (every block, raw HTML
  escaped, no attribute but the allowed ones, link schemes, link
  addresses shown, chart references, unknown images to alt text); chart
  validation (caps, non-finite values, unknown types); the file-name
  sanitizer (NFC, separators, leading dot, collisions); `ToolSchema`
  list kinds; `load_tools` (sticky, saved with the chat, pending after
  file text until the next user message, with pinned files too); the
  profile field's per-group merge, an old profile, a bad hand edit.
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
  Make again; a temporary chat (nothing on disk until Save); a chat
  reopened after a restart keeps its documents and its loaded group.
