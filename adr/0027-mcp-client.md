# 0027 — MCP servers: the chat uses tools from servers the user adds

**Status: accepted** (2026-10-16, by the user). The user's call: "пора делать" -- connect
ready MCP servers instead of writing each integration ourselves. The first
one is our own `ipsupport-llc/apple-mail-mcp` (Mail, Calendar, Notes), instead of
the Mail tools drafted in PR #339 (closed; its findings on Mail scripting
and trust are folded in below).

## Decision

LLMTray's chat becomes an MCP client. A server the user adds gives the chat
its tools, the way the built-in ones work: declared, called, answered as
`role: tool` ([0007](0007-chat-tools.md)). Our own tools stay native (0007's
reasons hold for them: images, songs, the generator queue); 0007's "no MCP
client" now means "not for our own tools", and its limits apply to MCP calls
too (rounds and calls per turn, dangling calls closed on Stop).

- **Opt-in, per server.** Settings › Tools › MCP Servers lists the servers;
  none is there until the user adds one. A server can be switched off
  without removing it. No server is started while it's off.
- **Adding a server**, three ways:
  - **A command** (stdio): command, arguments, environment.
  - **A URL** (Streamable HTTP), with optional headers (a token).
  - **From the catalog** (below).
  - **Import**: an MCP Bundle (`.mcpb`, the open one-file format servers
    ship in), or a pasted JSON config in the common `mcpServers` shape that
    servers' READMEs give, its servers picked from a list. The app never
    names or reads another app's settings. A bundle is a zip:
    unpacked into a fresh folder in the app's data, entries whose path
    leaves it or that are links refused, at most 200 MB unpacked. Its
    `manifest.json` `server.mcp_config` gives the command, with
    `${__dirname}`, `${HOME}` and `${user_config.<key>}` filled in (the
    user is asked for `user_config` values at import; `sensitive` ones go to
    the Keychain); a bundle needing anything else is refused with what.
  Nothing runs before the user confirms: adding shows the command or URL in
  full; **Start and Review** then starts the server once and shows its name,
  description and every tool with its description and arguments, and the
  user turns the server on. Environment values and headers marked secret
  (default for names with KEY, TOKEN, SECRET, PASSWORD, AUTH) go to the
  Keychain and are blanked in the server's log.
- **Each server is a tool group** ([0020](0020-documents.md), "Tools loaded
  when needed"): on demand by default (`load_tools` names it with the
  server's description; the + menu has **Use <server>**), Always in a profile
  if the user sets it. A server with 40 tools costs nothing until a chat
  loads it. 0020's rules hold: after outside text in a turn a load waits for
  the user's next message (`pendingToolGroups`); a call to a server's tool
  before its group is loaded is answered "call load_tools first"; a server
  switched off answers that it is off. Tool names go to the model as
  `<server>_<tool>` within MCP's `[A-Za-z0-9_-]{1,64}`; the app hands them
  out and keeps the exact map back to (server, tool), adding a number to a
  name already taken (ours included), so a call never reaches another tool.
- **Schemas as the server gives them.** A tool's `inputSchema` is sent to the
  model unchanged (JSON Schema is what the chat template takes); the
  arguments the model writes are read as JSON, with the usual repair of a
  fenced or single-quoted object, and passed on. Our lenient `ToolSchema`
  reading is for our own tools only.
- **Results: text, bounded.** `text` content parts, joined, at most 16,000
  characters (with how much was cut); `structuredContent` as compact JSON
  when there's no text. Images and other parts are named, not passed (v1).
  `isError` results go back as the tool's error.

## The catalog

No catalog of our own to run. Settings › Tools › MCP Servers › **Browse**
reads the official MCP Registry (`registry.modelcontextprotocol.io`, open,
vendor-neutral, a public API: `GET /v0/servers?search=…`), like the Hugging
Face browser does for models:

- **Featured first**: a short list kept in the app (our `apple-mail-mcp`
  first), then search results.
- **Only what can run here**, by the entry's own description: a remote
  (`streamable-http`) URL; an `mcpb` package; an `npm` package when `npx`
  is found, a `pypi` one when `uvx` is found (else "needs Node" / "needs
  uv", with nothing installed for it); `oci` (Docker) isn't offered.
  Latest version only, `active` status only.
- **Installing is adding**: the command or URL the entry gives goes into the
  same review as a hand-added server (shown in full, Start and Review, then
  on). An entry's text is the publisher's, shown as theirs; the registry
  vouches for a name's owner, not for the code.
- The registry is read only when the user opens Browse; nothing about the
  user is sent beyond the search words.

## Install, Update, Uninstall (2026-10-16, the user: "больше юзера спрашивать ничего нельзя")

The first build's review step (a sheet with the command, Start and Review,
Turn On) was too much. Now, as in an app store:

- **Install is one click** (Settings › Tools › Discover, a dropped or chosen
  `.mcpb`, a pasted config, + Add): the server is added, started, its tools
  listed and taken as reviewed, and switched on. The user is asked only for
  a setting the server needs that has no default (a key); every other
  setting starts at its default and can be changed under Configure.
- **Update** shows on the row when there is a newer version (a bundle's
  GitHub release, a registry entry's), checked at most hourly while the pane
  is open; one click installs it with the settings kept, its tools taken as
  they are then. **Uninstall** removes it at once (settings, secrets, files).
- What stays: every call is asked unless allowed per action; tools a server
  changes by itself (`tools/list_changed`, a restart) are hidden until the
  user accepts them under Configure; everything is asked after outside text.

The pane: Installed | Discover, a search, + Add. Installed is a table (icon,
name and version, This Mac / Web, status, Update, Configure, ⋯ with Turn
On/Off, Show Log, Uninstall). Discover is a grid of cards (icon, name,
description, by whom, +). Configure: on/off, the bundle's settings, each
tool with what it reads or changes and its Run without asking, changed
tools to accept, Details (command, versions, log), Uninstall.

## Asking before a call

An MCP tool can do anything its server can: send mail, delete a calendar
event, run a shell. The app can't know which tools are safe, so:

- **Every call is asked**, unless the user let that tool run without asking.
  The card shows the server, the tool and its arguments in full, with
  **Allow**, **Allow for This Chat** and **Deny** (no Return shortcut, as the
  folder plan's Approve), and says the server may do more than the
  arguments show (a mail reply's recipients and quoted text are Mail's).
  A deny is answered to the model ("the user didn't allow this call; don't
  ask again unless the user does") and that tool is refused for the rest of
  the turn: no consent loop ([0014](0014-folder-tools.md), Hardening 9).
- **Run without asking** is a per-tool switch in Settings, off for every
  tool until the user turns it on. A server's `readOnlyHint` is shown next
  to it ("the server says it only reads") but decides nothing: a server
  vouches for itself, and a "read" can still send its arguments away or
  change a little (marking a message read).
- **Per action, where a tool has them.** A tool whose schema has a
  top-level string field with a fixed list of values (`action`, `mode`, as
  `apple-mail-mcp`'s `read` / `write` do) is approved per value: Run without
  asking for `write` / `set_read` says nothing about `write` /
  `create_rule`. Settings lists the values under the tool.
- **Approval is bound to what was reviewed.** Each tool's definition (name,
  description, schema) has a hash; Run without asking and Allow for This
  Chat hold for that hash only, and a card waiting for an answer is dropped
  if the server changes the tool. A tool or server changed or added since the
  review (`tools/list_changed`, a restart, an update) is hidden from the
  model until the user reviews it in Settings. Just before sending a call
  the app checks again that the server is on and the hash is the same.
- **After outside text, everything is asked.** Once the turn has file,
  folder, web or MCP text in it (`hasUntrustedText || networkText`), every
  MCP call is asked, run-without-asking or Allow for This Chat or not, and
  the card says above Allow "Proposed right after reading outside text --
  check it". "Allow for This Chat" isn't offered then.
- **MCP results are outside text.** A new trust kind, `mcp`, counts in
  `hasUntrustedText`, `hasFileText` and `hasToolText`: after an MCP result,
  network tools and generators are refused for the turn, a pin is refused,
  folder changes go to their plan flagged (0014, Hardening 2 revised). In
  that turn a mail body saying "search the web for …" can't make a search;
  one saying "send this to …" reaches the user as a card. Later turns are
  the user's: the barrier is per turn, as everywhere.
- **In `ToolTrust`**: a `.mcp` kind and an `mcpText` turn flag that
  `record` sets after an MCP result, counted in `hasUntrustedText`,
  `hasFileText` and `hasToolText`. `allows(.mcp, …)` is always true -- the
  card is the gate -- and `refusedUpFront` treats an MCP call in a batch as
  outside text for the calls beside it (a web search next to a mail read is
  refused, as next to a project read).
- **A record in the chat.** Saved chats keep no tool calls or results, so
  each MCP call leaves a small line under the answer, saved with the
  message: server, tool (and action), the arguments as approved, and
  done / failed / outcome unknown / denied.
- **Descriptions are reviewed, not barred.** What a server says about its
  tools goes into every request of a chat that loaded it; it is trusted as
  far as the user trusted it when reviewing (above), not treated as text
  read this turn -- else loading a mail server would switch off web search
  for the whole chat.

**Reading on this Mac after outside text, and Always Allow (2026-10-16,
the user).** "Everything" allowed still asked at the second step of every
read ("accounts", then "messages"), the first result being mail. Now an
allowance (Settings, Always Allow, Allow for This Chat) still holds after
outside text for a tool the server marks read-only on a command server: what
it reads comes back into the chat, its arguments go nowhere. A tool that
changes things, or any tool of a server on the web, is asked after outside
text, as before. The card gets **Always Allow <action>** (the same as
Configure's checkbox); after outside text it, and Allow for This Chat, show
only where an allowance would hold.

## The client

- **Our own, small**, no package: JSON-RPC 2.0. Protocol versions
  `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05` (what
  `apple-mail-mcp` answers): we ask for the newest, accept one of these back, and refuse any
  other; `initialize` /
  `notifications/initialized`, `tools/list` (paged), `tools/call`,
  `notifications/tools/list_changed`, `ping`, `notifications/cancelled` on
  Stop. No resources, prompts, sampling or elicitation in v1 (asked for
  nothing: the client says so in its capabilities).
- **The server's key** (the `<server>` in tool names) is made once, when it's
  added, from its name: ASCII letters and digits, lowercase, at most 20
  (`apple_mail`), `server1`, `server2`… when nothing is left; renaming it
  later doesn't change the key.
- **stdio**: a bare command (`npx`, `node`, `uvx`) is looked up once, when
  the server is added, through the user's login shell (`zsh -lc 'command -v
  …'`), and stored as the absolute path -- the app's own PATH has no
  Homebrew or nvm. The server is started at the first need (a chat loads its group,
  or Settings shows its tools), as a child process in its own process
  group, with a minimal environment (PATH, HOME, the user's variables) and
  the server's folder as working directory; kept while the app runs, stopped
  after 15 idle minutes and on quit (SIGTERM, SIGKILL after 3 s). Stdout is
  the protocol (a line over 8 MB ends the server), stderr goes to the
  server's log in Settings (last 200 lines, secret values blanked). A crash is shown there; the
  next call starts it again, at most three times in a minute; then it stays
  off ("keeps crashing -- see its log") until started in Settings.
- **HTTP**: POST per message; a reply is plain JSON or an SSE stream, either
  read; `Mcp-Session-Id` kept and `MCP-Protocol-Version` sent after
  initialize; a 404 for the session means initialize again for the next
  call -- a call that got it is answered as outcome unknown, never resent.
  Tool changes come on the server's GET stream when it offers one; when it
  doesn't, the tools are listed again before a standing approval is used. No OAuth in v1
  (a token in a header covers our servers).
- **Time limits**: 20 s to start and initialize; 60 s per call, counted
  from Allow. Then `notifications/cancelled` -- which a server may ignore,
  and a busy one can't read -- and the answer says the outcome is unknown:
  "it may have happened; check before trying again, and don't repeat it
  without asking the user". The same after Stop. Nothing is retried by the
  app, ever. A server whose call timed out is restarted before the next
  call.
- **macOS permissions** go to whoever sends the Apple events: an `osascript`
  server started by LLMTray is attributed to LLMTray ("LLMTray wants to
  control Mail"). The Developer ID build gets
  `com.apple.security.automation.apple-events` and an
  `NSAppleEventsUsageDescription` for that. That the prompt names LLMTray,
  not `osascript`, is to be checked on the user's Mac in the first run; if
  it names `osascript`, the permission is still per app pair and works, only
  the wording differs.

## Where it doesn't go

- **Temporary chats**: no MCP. They leave no trace, so a send or delete
  from one couldn't be looked up later; the folder tools there only read.
- **External clients through the proxy**: no. They have their own MCP; the
  app's servers serve its chat only.
- **Memory** never reads tool results ([0024](0024-memory.md)).
- **App Store flavor**: only URL servers. A command server there would run
  inside our sandbox (children inherit it) and couldn't reach what it's
  for; command servers and imports are hidden (a scope choice, for now).

## Plan

1. Core (LLMTrayCore): `MCPMessage` (JSON-RPC types), `MCPClient` over a
   transport protocol, `StdioTransport`, `HTTPTransport`, the result-to-text
   bound, name mangling, `.mcpb` and pasted-config import, the registry
   client; tests with a
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
results to models that see; Docker servers.
