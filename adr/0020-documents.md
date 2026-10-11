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
    charts?: [ { id, type: bar|line|pie|table, title?,
                 labels: [..], series: [ {name, values: [..]} ],
                 unit? } ],
    format?: pdf                // the only one for now
  )
  ```

  A chart goes where the content says `![chart](chart:<id>)`; a chart the
  content never names goes at the end. The model sends numbers, never
  drawings.
- **The app renders, locally.** Markdown (GitHub flavour: headings,
  lists, tables, code, quotes, links, footnotes) goes to HTML through our
  own converter in LLMTrayCore — the same block rules as `ChatMarkdown`,
  no new package — then into a page laid out by the style's CSS (fonts,
  margins, header and footer with the title and page numbers, a table of
  contents for a long report), printed to PDF by WebKit (`WKWebView`
  `createPDF`, paginated with `NSPrintOperation` for real page breaks).
  Charts are drawn by Swift Charts (`ImageRenderer`, 2x) and embedded as
  PNG `data:` images. Styles are a few fixed CSS files in the app, not
  model input: the model picks one by name, it never sends CSS or HTML.
- **The result is a card in the chat**, like a generated image: the first
  page as a thumbnail, the title and page count, and Open (Preview),
  Show in Finder, Save As…, Add to Project (when the chat is in one,
  through `ProjectIndexer.addFiles`, the same path as a drop). The file
  lives with the chat's own data and goes with it when the chat is
  deleted; temporary chats keep it in the temp folder until the chat
  closes. Regenerate makes it again from the same call.
- **The model is told it's done**: the tool answers the file name and the
  page count, no path, and says the user sees it in the chat. It doesn't
  read the PDF back.
- Later, through the same tool: `format: docx` (Word, for editing) and
  `format: xlsx` for tables; `style` gains the user's own templates. Not
  in the first version.

## Hardening

A document is built from text the model wrote, and that text may come
from a project file, a folder file or a web page with instructions in it.

1. **Nothing executes, nothing loads.** The web view that prints has
   JavaScript off (`allowsContentJavaScript = false`), no network (a
   `WKURLSchemeHandler` serves only our styles and fonts; every other
   URL is refused, including `file:`), loads HTML from a string with no
   base URL. Images in the content are allowed only as the chart
   references above; any other `![...](...)` becomes its alt text. Links
   stay links in the PDF but are never fetched.
2. **The converter escapes everything.** Raw HTML in the Markdown is
   text, not markup (a `<script>` or `<iframe>` comes out as those
   characters); attribute values are escaped; link targets are kept only
   for `http`, `https` and `mailto`.
3. **The model's numbers are hostile** ([0007](0007-chat-tools.md),
   Lessons): at most 8 charts, 12 series, 500 points per chart; values
   must be finite; labels and titles are capped; a bad chart is left out
   with a note in the tool's answer, the rest of the document is made.
   Content is capped at 200,000 characters; a title becomes a file name
   only after the same sanitizing as a project file's name.
4. **It only writes its own new file.** No path comes from the model;
   the file goes into the chat's data folder under a fresh name
   (`O_EXCL`), never over anything. Getting it anywhere else is the
   user's click (Save As…, Add to Project).
5. **Trust kind: ordinary** (the barrier of
   [0012](0012-project-files-rag.md) and [0014](0014-folder-tools.md)).
   Making a document from project or folder text is the point of the
   tool ("summarise these files into a report"), and it can't reach the
   network or change a file, so it stays allowed after file text. If a
   later format ever fetches anything (a template from the web), that
   call becomes guarded.
6. **Per turn: one document**, like one image; a second call in the turn
   is refused with "already made — say if it should change".

## Tools loaded when needed

Every declared tool is tokens in every request, and small models choose
worse among many tools (the user's rule, [0007](0007-chat-tools.md)).
`make_document` with charts is one of the bigger declarations (an
estimated 250–300 tokens). Declaring it only when it's needed:

- **Why not just add it in the middle of a chat:** the tools sit at the
  start of the prompt (the chat templates put them in the system turn),
  so changing the list changes the prefix and the server's prompt cache
  misses: a 30K-token chat is prefilled again, tens of seconds on a
  laptop. So a tool is added **once and stays** for the rest of the chat,
  never toggled per turn.
- **Three ways it gets declared**, a tool's setting in the profile
  ([0005](0005-profiles.md)) — `always`, `on demand` (the default for
  documents), `off`:
  1. *On demand by the model.* With any on-demand tool switched on, one
     small tool `load_tools(group)` is declared (about 40 tokens with the
     group names and a phrase each: `documents: PDF documents with
     charts`). The model calls it on "оформи документ"; the answer says
     the tool is ready; the group is declared from the next request in
     this chat on, and saved with the chat. One cache miss, only in chats
     that need it.
  2. *By the user.* The composer's + menu gets "Document…": the group is
     declared from this message on, and the message gets a short hint
     that a document is wanted. For a model that wouldn't think of
     `load_tools`.
  3. *Always*, for a user who wants it in every chat and has the
     context.
- **The same mechanism for the other tools later** (web, weather,
  country): the profile says which are always on and which on demand.
  Out of this ADR's first step; the groups are data, so adding one is a
  line.
- `load_tools` is ordinary (it changes only what's declared); the trust
  barrier still decides what a loaded tool may do. A group loaded by a
  call that came after file text works only from the user's next message
  (a file can't hand the model a new tool in its own turn).

## Verification

- Unit tests (LLMTrayCore): the Markdown converter (every block, raw
  HTML escaped, links filtered, chart references resolved, unknown
  images to alt text); chart validation (caps, non-finite values, unknown
  types); file naming; `load_tools` (sticky, saved with the chat, after
  file text only from the next message).
- A rendering test: a fixed document in each style printed to PDF, page
  count and text extracted (PDFKit) checked; the web view's handler
  refuses a remote image, `file:` and a script.
- `--run-tool make_document '<json>'` writes the PDF (as the other
  tools); `scripts/eval_tool_choice.py` gets prompts that need a document
  (called, through `load_tools` when on demand) and ones that don't
  ("привет", "explain this" — not called).
- Measure: declaration tokens (`--dump-tool-definitions`), the cache
  miss on loading (prefill time before/after in a long chat).
- Manual: a report with a table and two charts from a project file, a
  letter, an invoice; Open, Save As…, Add to Project; a temporary chat;
  Regenerate.
