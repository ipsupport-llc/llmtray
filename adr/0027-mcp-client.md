# 0027 — MCP servers: the chat uses tools from servers the user adds

**Status: proposed** (2026-10-16). The user's call: "пора делать" -- connect
ready MCP servers instead of writing each integration ourselves. The first
one is our own `ipsupport-llc/apple-mail-mcp` (Mail, Calendar, Notes), instead of
the Mail tools drafted in PR #339 (closed; its findings on Mail scripting
and trust are folded in below).

## Decision

LLMTray's chat becomes an MCP client. A server the user adds gives the chat
its tools, the way the built-in ones work: declared, called, answered as
`role: tool` ([0007](0007-chat-tools.md)).

- **Opt-in, per server.** Settings › Tools › MCP Servers lists the servers;
  none is there until the user adds one. A server can be switched off
  without removing it. No server is started while it's off.
- **Adding a server**, three ways:
  - **A command** (stdio): command, arguments, environment.
  - **A URL** (Streamable HTTP), with optional headers (a token).
  - **Import**: an `.mcpb` bundle (unpacked into the app's data, its
    `manifest.json` read for the command; what Claude Desktop installs with a
    double click), or the servers in Claude Desktop's
    `claude_desktop_config.json`, picked from a list.
  Secrets (environment values and headers the user marks secret) go to the
  Keychain, not to the settings file.
- **Each server is a tool group** ([0020](0020-documents.md), "Tools loaded
  when needed"): on demand by default (`load_tools` names it with the
  server's description; the + menu has **Use <server>**), Always in a profile
  if the user sets it. A server with 40 tools costs nothing until a chat
  loads it. Tool names go to the model as `<server>_<tool>` (letters, digits,
  `_`, at most 64 characters), so two servers can't clash with each other or
  with ours.
- **Schemas as the server gives them.** A tool's `inputSchema` is sent to the
  model unchanged (JSON Schema is what the chat template takes); the
  arguments the model writes are read as JSON, with the usual repair of a
  fenced or single-quoted object, and passed on. Our lenient `ToolSchema`
  reading is for our own tools only.
- **Results: text, bounded.** `text` content parts, joined, at most 16,000
  characters (with how much was cut); `structuredContent` as compact JSON
  when there's no text. Images and other parts are named, not passed (v1).
  `isError` results go back as the tool's error.

## Asking before a call

An MCP tool can do anything its server can: send mail, delete a calendar
event, run a shell. The app can't know which tools are safe, so:

- **Every call is asked**, unless the user let that tool run without asking.
  The card shows the server, the tool and its arguments in full, with
  **Allow**, **Allow for This Chat** and **Deny** (no Return shortcut, as the
  folder plan's Approve). A deny is answered to the model ("the user didn't
  allow this call") and the turn goes on.
- **Run without asking** is a per-tool switch in Settings, default on only
  for tools the server marks `readOnlyHint: true`; the user can change it
  either way. A tool the server changes (a new description or schema, by
  `tools/list_changed` or at a restart) loses the switch until the user
  looks at it again.
- **After outside text, everything is asked.** Once the turn has file,
  folder, web or MCP text in it (`ToolTrust`'s `hasUntrustedText`), every MCP
  call is asked, run-without-asking or not, and the card says above Allow
  "Proposed right after reading outside text -- check it". "Allow for This
  Chat" isn't offered then.
- **MCP results are outside text.** A new trust kind, `mcp`, counts in
  `hasUntrustedText`, `hasFileText` and `hasToolText`: after an MCP result,
  network tools and generators are refused for the turn, a pin is refused,
  folder changes go to their plan flagged ([0014](0014-folder-tools.md),
  Hardening 2 revised). A mail body saying "search the web for …" leaks
  nothing; one saying "send this to …" reaches the user as a card.

## The client

- **Our own, small**, no package: JSON-RPC 2.0, the `2025-06-18` protocol
  (and what the server answers with, if older); `initialize` /
  `notifications/initialized`, `tools/list` (paged), `tools/call`,
  `notifications/tools/list_changed`, `ping`, `notifications/cancelled` on
  Stop. No resources, prompts, sampling or elicitation in v1 (asked for
  nothing: the client says so in its capabilities).
- **stdio**: the server is started at the first need (a chat loads its group,
  or Settings shows its tools), as a child process in its own process
  group, with a minimal environment (PATH, HOME, the user's variables) and
  the server's folder as working directory; kept while the app runs, stopped
  after 15 idle minutes and on quit (SIGTERM, SIGKILL after 3 s). Stdout is
  the protocol (a line over 8 MB ends the server), stderr goes to the
  server's log in Settings (last 200 lines). A crash is shown there; the
  next call starts it again, at most three times in a minute.
- **HTTP**: POST per message, `Mcp-Session-Id` kept, SSE replies read; no
  OAuth in v1 (a token in a header covers our servers).
- **Time limits**: 60 s per call (then `notifications/cancelled` and an
  error answer), 20 s to start and initialize. A call's time counts while
  the card waits only from Allow.
- **macOS permissions** go to whoever sends the Apple events: an `osascript`
  server started by LLMTray is attributed to LLMTray ("LLMTray wants to
  control Mail"). The Developer ID build gets
  `com.apple.security.automation.apple-events` and an
  `NSAppleEventsUsageDescription` for that. To check on the user's Mac in
  the first run.

## Where it doesn't go

- **Temporary chats**: servers can be loaded, every call is asked (nothing
  runs without the card, since the chat leaves no trace of what it did).
- **External clients through the proxy**: no. They have their own MCP; the
  app's servers serve its chat only.
- **Memory** never reads tool results ([0024](0024-memory.md)).
- **App Store flavor**: the sandbox can't start other programs, so only URL
  servers there; command servers and imports are hidden.

## Plan

1. Core (LLMTrayCore): `MCPMessage` (JSON-RPC types), `MCPClient` over a
   transport protocol, `StdioTransport`, `HTTPTransport`, the result-to-text
   bound, name mangling, `.mcpb` / Claude Desktop config import; tests with a
   fake server (a script speaking the protocol) and fixture JSON.
2. App: `MCPServerStore` (settings file + Keychain), the process supervisor,
   dynamic tool groups in `ToolGroups`, declaration and the call path in
   `ChatClient.executeToolCalls`, the ask card, `ToolTrust.mcp`, Settings ›
   Tools › MCP Servers (add, import, on/off, tools with run-without-asking,
   log), the + menu.
3. Live: `apple-mail-mcp` on the user's Mac -- list the inbox, read a
   message, draft a reply (asked), in Gemma 4 26B and E4B; a mail body with
   an instruction to send or search: nothing runs without a card.

## Not now

OAuth for remote servers; resources, prompts, sampling, elicitation; image
results to models that see; a server catalog to browse.
