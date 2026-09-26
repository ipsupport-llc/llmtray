# 0006 — Chat: tabs, sessions, the library

## Decision

- **One `ChatClient` per tab** (`ChatTabs`): a tab keeps streaming while
  another is on screen. Tabs share the one server (the selected model)
  and the app's one image and music generator. Operations that restart
  the server wait for every tab (`isAnyBusy`); a closed tab still
  reloading the model after an image counts as busy until it's done
  (a9d3fb4). The saved chats open in tabs come back at launch
  (`Pref.openChatTabs`), with a new chat on screen as every launch.
- **A chat is one JSON file** per session,
  `Application Support/LLMTray/sessions/<uuid>.json` (`ChatSessionStore`,
  `ChatSessionFile`), written atomically after every completed turn and on
  Stop, a switch, a tab close and quit. Media is not inlined: images
  (`.png`) and music (`.m4a`; older songs `.wav`) are files in a sibling `<uuid>-images/`.
  Saved is a readable transcript (`PersistedMessage`): `tool` messages,
  tool-call plumbing and hidden `view_image` context are dropped.
- **Pins and projects live apart**, in `sessions/library.json`
  (`LLMTrayCore.ChatLibrary`, `ChatLibraryStore`): the session file is
  rewritten whole after every turn, so a pin set in between would be
  lost. A project today is only a named group (id, name, createdAt) and
  a chat → project map; nothing else is scoped to it.
- **A temporary chat writes nothing by itself**: `currentSessionID ==
  nil` makes saving a no-op, it isn't reopened as a tab, and its images
  and songs never touch disk — the runners stream them over stdout, no
  temp file (bd92ccc), and a song is encoded to AAC in memory. Only what
  the user sends out writes a file: Save…, and Copy / Share of a song or
  image (a temporary export, `MediaSharing`).

## Files and media

- **Filenames are stable and never reused.** A new image is
  `<message id>-<i>.png`; a loaded chat keeps the names it was read from
  (the reloaded message gets a new id: every reopen wrote all images
  again under new names, 572fcfc). A variant made by Regenerate gets a
  fresh `<UUID>.png`. A save writes only files that don't exist yet, so a
  new picture under an old name would never reach disk.
- **Unreferenced files are swept** after the JSON that no longer lists
  them is saved — compacted, removed or regenerated media.
- **A file that fails to write** (full disk) is left out of that save, the
  text kept, and retried on the next (91dd16f).
- **An unchanged chat isn't written**: re-saving bumped `updatedAt` and
  moved it to Today on merely opening another chat (c8123dc).
- **Old files decode**: fields added later default (`PersistedMessage`);
  `library.json` decodes element by element, so one bad pin or project
  drops itself, not the file; it's pruned by the session files present,
  not by the ones that decoded (ce50acc, c8123dc).
- The sidebar reads every session once off the main thread, then only the
  chat a save or delete names (`sessionsDidChange` carries its id).

## Turns and stale continuations

- **Conversation epoch** (`ChatClient.conversationEpoch`), bumped by a new
  chat, a load and a tab close: image generation, tool rounds,
  compaction and the auto-title outlive a switch, and used to land in
  whatever chat was on screen (adr/0003). Each captures the epoch before
  its first await and drops its result if it moved.
- **Turn token**, bumped by Stop: a tool round scheduled before a Stop
  doesn't run or send its follow-up (0339b8e, 2a503de). Stop answers
  every open tool call with "Cancelled by the user." so the next request
  stays valid under the OpenAI tool protocol.
- **Transport** (`ChatTransport`): one stream per client; a new one or
  `cancel()` makes the old one's late callbacks no-ops (keyed by task id).
  Text is split only at line ends, so a UTF-8 character cut by the network
  isn't lost. First-byte and end times are taken in the delegate itself:
  timing in the dispatched main-actor work once inflated tok/s.
- **Parsing** (`LLMTrayCore.SSEDecoder`, tested): `reasoning` and
  `reasoning_content`, multimodal content arrays with data-URI images
  (remote URLs ignored), tool calls — mlx_lm.server emits them whole, so
  no fragment merging — and the usage chunk for tok/s.
- **Turn end** is detected per tab by `ChatPresentation.TurnTracker`
  (auto-title, auto-compaction), outside the view: a popover never shown
  gets no `onChange`, so a turn ending with the window closed went
  unnoticed (3bcd048).

## Requests (`ChatRequestBuilder`)

- The profile's sampling is sent in full, `top_k` 0 included (adr/0005);
  the tool-use rule joins the system prompt only when tools are offered.
- Refused tool calls of earlier turns are left out: later they read as
  "the image wasn't made". A tool's image goes with the next request only.
- A text-only model gets the text of messages that had images: it
  refused every request of such a chat (572fcfc).
- Reasoning is shown (global `Pref.showReasoning`; open while thinking,
  folded once the answer starts) and saved, but never sent back.

## Compaction

`compactionRange` replaces the middle between `keepStart` and `keepEnd`
(global prefs) with one `isSummary` assistant message written by the
model. Whole turns only — a split tool round broke the protocol — and
stopping before the first message with media (its file would be swept).
An earlier summary is compacted again with the rest. A one-shot request
(temperature 0.3, max_tokens 2048); a cut-off (`finish_reason: length`)
or empty answer is rejected: with 512 tokens a thinking model spent them
all reasoning and an empty summary was saved (572fcfc).
