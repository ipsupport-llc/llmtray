# 0002 — The model proxy and the server lifecycle

## Why a proxy

`mlx_lm.server` serves one model per process and can't swap it. To let any
OpenAI-compatible client pick a local model by name (as LM Studio does),
LLMTray owns the public port: a small reverse proxy there reads each
request's `model` field, switches the model process if needed, and forwards
to it on an internal port (public + 10000).

It's hand-rolled on Network.framework rather than a dependency, scoped to
what the clients send: JSON bodies sized by `Content-Length` (no chunked
request bodies — refused with 411), a handful of endpoints. Parsing lives in
`LLMTrayCore.HTTPRequestParser` and is unit-tested against malformed
input; the proxy is reachable from the LAN when that's enabled, so it
refuses rather than trusts: negative / huge / conflicting Content-Length,
endless headers (431, one limit however TCP splits the head), and a request
not fully read within 120 s (its buffer is released).

## Lifecycle rules (ServerManager)

Found the hard way; each was a live bug:

- **Transitions are serialized** (start, switch, reload, restart, unload):
  two concurrent requests for different models used to overwrite each
  other's continuation and hang one.
- **A switch drains first**: it waits for requests still being served by the
  old model instead of cutting their generation off.
- **Stale process callbacks are ignored by identity.** Stop publishes
  `.stopped` at once, so a Start can launch before the old process has
  exited; the old process's late termination handler used to mark the new
  one stopped/failed. A replacement is only launched once the old process
  has exited (it holds the internal port).
- **SIGKILL only this exact process.** A delayed SIGKILL once hit the *new*
  model 3 s after a switch (status 9 mid-generation) because it checked
  "is the current process running".
- **Request counters belong to requests.** The termination handler used to
  zero them, marking a still-running request finished.
- **An explicit Stop is final**: requests (a connection accepted just
  before, image generation's reload) may only bring the model back while
  it's running or idle-unloaded.
- **Running means reachable**: `.running` is published only once the public
  listener is listening; a taken port fails the server.
- **The pipe handler is cleared on exit**, in the termination handler (the
  one place that runs whatever the cause): left installed, the pipe reads
  empty at EOF forever and libdispatch re-invokes it in a tight loop —
  seen live as 100% CPU with no server process left.

## Stall watchdog

No response headers and no streamed data for the stall threshold (default
60 s, Settings) means stuck — a hung process, a dead worker thread — not
slow: even long prefills stream within a minute. It fires well inside the
request's 300 s timeout, leaving a log line and a real 504 instead of a
silent hang. Several stalls in a row restart the process: a Metal OOM can
kill `mlx_lm.server`'s worker thread while the process stays alive, and
every later request would hang.
