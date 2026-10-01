# 0019 — A command-line tool, `llmtray`

**Status: accepted** (2026-09-30: the maintainer approved the design;
the standalone build only).

## Why

LLMTray's users live in terminals: coding agents, editors, scripts. Today
everything but the OpenAI API needs the menu bar: starting the server,
seeing what's loaded, downloading a model, making an image. An agent can't
click Start, and a script can't ask which port the API is on.

The API port can't carry these. The proxy listens only while a model
server runs (or is idle-unloaded, adr/0002), so it can't carry `start`; and
it's an HTTP port on localhost, optionally the LAN. Control over it (stop
the server, fill the disk with downloads) would be one CSRF away from any
web page the user opens, and one connection away from anyone on the LAN.

## Decision

### 1. A control socket, not a port

While the app runs, it listens on a **Unix domain socket** at
`<Application Support>/LLMTray/control.sock` (`RuntimePaths.externalRuntimeDir`):

- **Owner-only.** The socket file is bound, `chmod`ed to `0600` and only
  then `listen()`ed, so no connection can come in before it's private (a
  BSD `connect()` needs write permission on the file). Every accepted
  connection's peer is also checked with `getpeereid`: another user's
  process is closed at once, whatever the file's mode.
- **Not reachable from a browser.** A web page can't open a socket file:
  no CSRF against it, no DNS rebinding; the LAN can't see it at all.
- **Always on** while the app runs, from launch (after the single-instance
  check) to quit, independent of the model server.
- **One app.** A socket file left by a crash is stale: at start, if a
  `connect()` to it fails, it's removed and bound anew. If one succeeds,
  another LLMTray answers there (the app is single-instance, so this is a
  second copy during its hand-over) and this one leaves it alone.
- **POSIX sockets, not Network.framework.** `NWListener` can listen on a
  Unix path, but it binds and listens in one step: there's no moment to
  make the file private before connections are accepted. The listener is
  a few dozen lines of `socket`/`bind`/`listen`/`accept` with dispatch
  sources (`LLMTrayCore/ControlSocket.swift`). The transport is in
  LLMTrayCore, not the app, so the whole round trip is tested in-process
  (`ControlSocketTests`: a real socket, the CLI's own client, a stand-in
  handler), and the CLI shares the client half.

### 2. The protocol (`LLMTrayCore/ControlProtocol.swift`)

Newline-delimited JSON, versioned:

- A request is one line: `{"v":1,"cmd":"status"}`, with the command's own
  fields beside `cmd` (`model`, `repo`, `prompt`, `width`, `height`).
- The reply is one or more lines. Every reply ends with a final line,
  `{"done":true,...}` or `{"error":"..."}`; streaming commands send event
  lines first (`{"event":"state",...}`, `"progress"`, `"queued"`).
- Unknown fields are ignored both ways (a newer CLI or app can add one).
  An unknown `cmd`, a missing field or a version newer than the app's is a
  clear `error` line, not a dropped connection.
- Requests are capped at 1 MiB, replies (an image) at 64 MiB.

### 3. The commands (app side, `ControlCommands.swift`)

Each one is what the tray already does, called the same way:

| cmd | does | like |
|---|---|---|
| `status` | state (stopped/starting/running/failed and its message), the loaded and selected model, port, idle-unloaded, app version, the API base URL, and the app's request token | the popover's header |
| `models` | the catalog: path, request name, size, which is selected and loaded | the model picker |
| `start` (`model`?) | the model named (by request name, folder name or path, as the proxy resolves it) becomes the selected one, then: stopped → the tray's Start; running another or idle-unloaded → loaded as picking it does; starting → waits, then decides. Streams each state change until running (done) or failed (error) | Start / picking a model |
| `stop` | `ServerManager.stop()` | Stop |
| `pull` (`repo`) | `DownloadQueue.addChatModel`, then its progress until done or failed | the setup wizard's download |
| `image` (`prompt`, `width`?, `height`?, `model`?) | the generator queue's turn, the chat model unloaded if the profile says so, mflux, the model reloaded; progress events, then the PNG (base64) | the chat's `generate_image` |

**The request token.** `status` returns `AppRequestToken.value` (adr/0002:
the secret that marks the app's own requests to its proxy). The CLI's chat
sends it, so a model it names switches as in the in-app chat, without the
model-switch policy's prompt firing for the user's own terminal. It's safe
to hand out here: only the user's own processes can reach the socket, and
they could read the app's memory anyway.

**Images** run on the selected model's profile (its image model, quality
and "unload the chat model" setting). Without a downloaded image model the
error names Settings › Image generation: the CLI never downloads one
(features stay opt-in, downloaded only when turned on in Settings).

### 4. The CLI (`Sources/LLMTrayCLI`, installed as `llmtray`)

A separate executable depending on LLMTrayCore only (no AppKit), with its
argument parsing in LLMTrayCore (`CommandLineArguments.swift`, pure and
unit-tested; no swift-argument-parser: no new dependency).

```
llmtray status [--json]          llmtray start [model]     llmtray stop
llmtray models [--json]          llmtray pull <org/name>   llmtray api
llmtray chat "prompt" [--model M] [--system S] [--show-thinking] [--json]
llmtray image "prompt" [-o out.png] [--width N --height N] [--model M]
llmtray --version                llmtray help [command]
```

- **`chat`** talks to the OpenAI endpoint itself (`/v1/chat/completions`,
  `stream: true`), not through the socket: that's the API every other
  client uses, and the profile's sampling defaults are filled there
  (adr/0005). It starts the server first when it's stopped. The prompt is
  read from stdin when it's `-`, or absent and stdin isn't a terminal.
  Reasoning is hidden unless `--show-thinking`.
- **No app running:** the CLI launches it in the background (`open -g -j`
  on the app bundle the CLI is inside of, else by bundle id) and waits up
  to 20 s for the socket.
- **Exit codes:** 0 ok, 1 error, 2 usage, 130 after Ctrl-C. Errors go to
  stderr. Ctrl-C during `chat` cancels the request (the proxy stops
  generating); during `pull` and `image` it detaches: the download goes
  on, and an image already being made is finished but not saved (one
  still waiting in the queue leaves it).
- **Built as `LLMTrayCLI`**, renamed `llmtray` in the bundle: an `llmtray`
  product would overwrite `LLMTray` in `.build/release` on a
  case-insensitive volume. It links LLMTrayCore whole (~7.5 MB).

### 5. Bundling and installing

- `build_app.sh` copies the binary to **`Contents/Helpers/llmtray`**, not
  `Contents/MacOS`: `llmtray` and `LLMTray` are the same name on a
  case-insensitive volume. `codesign_app.sh` already signs every loose
  Mach-O inside-out with the hardened runtime; the CLI needs no
  entitlements.
- **Settings › General › Command-line tool**, Install / Uninstall: a
  symlink `~/.local/bin/llmtray` → `<this app>/Contents/Helpers/llmtray`
  (the directory created if needed; a file there that isn't a symlink is
  never replaced; our own link, stale after the app moved, is). If
  `~/.local/bin` isn't on the login shell's `PATH`, the line to add is
  shown. A symlink, not a copy: a Sparkle update replaces the app and the
  link follows it.

### 6. Not in the App Store build

The App Store build (adr/0018) neither bundles the CLI nor serves the
socket (`#if !APP_STORE`):

- the sandbox can't write a symlink to `~/.local/bin`, or anywhere on the
  user's `PATH`;
- its Application Support is inside the container
  (`~/Library/Containers/us.ipsupport.llmtray.appstore/Data/...`), and a CLI outside
  the container can't count on reaching a socket there (a sandboxed
  listener's socket path and its permissions are the sandbox's business).

If App Store users ask for it, the way is a separately distributed CLI and
an app-group container both can reach: its own decision.

## Consequences

- One more always-on listener in the app, reachable only by the user.
- The CLI's commands are the tray's: any change to Start, the download
  queue or image generation reaches it without a second copy of the logic.
- `llmtray chat` is an OpenAI client like any other; the socket carries
  control only.

## Steps

1. ~~This ADR.~~
2. ~~The protocol, the argument parser and the install decision in
   LLMTrayCore, with tests.~~
3. ~~The socket server and the command handler in the app.~~
4. ~~The CLI target; bundling in `build_app.sh`.~~
5. ~~Settings › General › Command-line tool; the README.~~
