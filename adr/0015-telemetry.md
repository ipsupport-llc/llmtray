# 0015 — Usage telemetry (on by default for new installs)

## Decision

LLMTray can send an anonymous daily usage report to
`POST https://ipsupport.us/api/telemetry` while the setting is on: on
for a new install, never turned on by an update, off with one switch
(below). The server side, and what it may and may not receive, is
ipsupport-api's `docs/telemetry.md`, its `api/openapi.yaml`
(`TelemetryReport`) and its ADRs 9 (opt-in telemetry) and 10 (the
country of a report); the app follows them.

- **On by default for a new install** (the user's call, 2026-09-29; it was
  offered ticked in the first-run wizard since 2026-09-27):
  - On a first run the setting is written **on**, and the wizard's
    "Staying up to date" step shows it on, with the consent text and
    Show Reports…; unticking it there, or in Settings, turns it off.
    Skipping or closing the wizard leaves it on.
  - An install from before this that never chose is written **off** at
    its first launch of this version: an update never turns it on by
    itself. When the setup wizard opens by itself on such an install (no
    model was ever selected), it offers the box ticked as on a first run,
    and Finish turns it on: a choice the user sees and can clear (the
    user's call, 2026-10-10).
    `TelemetryDefault.settle` decides once, at launch: no data folder
    means a first run.
  - The first report still goes only after the first local day ends, so
    it can be turned off before anything is sent.
  - The App Store privacy label declares it: usage data, not linked to
    the user ([0018](0018-app-store-build.md)).
- Settings → General → Usage statistics: a "Share
  anonymous usage statistics" toggle with the consent text from
  `telemetry.md`, an expandable "What's sent" list of every field (with
  this Mac's values) and what's never sent, and Reset ID.
- **Turning it off** stops sending at once (the send in flight is
  cancelled and its answer ignored) and deletes the unsent counters and
  the install ID. **Turning it on** makes a new random install ID; Reset
  ID makes another (and cancels a send in flight under the old one).
- **One report per day, covering one local day.** Counters are kept per
  local day (`Application Support/LLMTray/telemetry.json`), at most 7
  days back. At launch (10 seconds in, so a quick look at the app still
  sends) and every 3 hours while running, the finished days are sent
  oldest first; today's only after it ends. Nothing is sent while the app
  isn't running: the days wait for its next launch. Older days, and days
  more than one after today (a clock set back), are dropped unsent;
  tomorrow is kept (a Mac moved west of where it counted sends it once
  it's over there). A wait (Retry-After, backoff) longer than two days
  was set by a clock that was ahead, and is ignored. "7
  days back" is also counted from the UTC day, as the server does: a Mac
  behind UTC would otherwise send a day it refuses. Days are Gregorian
  (`yyyy-MM-dd`) whatever calendar the user picked. A day the app ran on
  is reported even with nothing counted.
- **The fields** are the spec's: `product`, `install_id`, `day`,
  `app_version` (CFBundleShortVersionString), `os_version`
  (major.minor.patch), `chip` ("Apple M5"; anything else "other"),
  `memory_gb`, `locale` (the language only), `features` (counts of
  `chat`, `tool_calls`, `api_server`, `image_generate`, `image_edit`,
  `music`, `lora`, `model_download`) and `model_families` (a model's
  path or repo mapped to the spec's families, anything else "other"). The
  report is validated as the server validates it (`TelemetryReport`,
  mirroring `report.go`).
- **Never sent:** prompts, content, generated media, file names or paths,
  model names or repositories. Only the last two components of a model's
  path are looked at to find its family, and only the family is kept.
- **Nothing from temporary chats**, not even a count: `ChatClient`
  records only for a chat with a session. What counts: a chat answer that
  came through (`chat`), a tool the model called that ran (`tool_calls`:
  not a refusal, nor an unknown tool or one the chat doesn't offer),
  an image made or edited and a song made (in a turn or by Regenerate /
  Tweak), a request from an outside client through the proxy
  (`api_server`: requests with the app's token are the app's own), a
  model downloaded from the Hugging Face browser (`model_download`, a
  count only). `lora` has nothing to count yet.
- **Answers:** 204 sent; 400 (`invalid_*`), 413, 415 and other 4xx drop
  that day's report, not retried; 429 waits for Retry-After; 408, 5xx and
  no answer try again after an hour. A resend of a day replaces it on the
  server, so retrying needs no idempotency key.
- **Its own session**: ephemeral, no cookies or cache, 15 s timeout,
  `User-Agent: LLMTray/<version>`. Tests use a `URLProtocol` stub;
  `LLMTRAY_TELEMETRY_ENDPOINT` points a development build at a local
  server. Nothing is sent to ipsupport.us while developing.

## Why

We want to know how many people run the app, on which Macs and builds,
and which features they use, without undermining its promise of local,
private AI: shown before anything is sent, pseudonymous, coarse, and easy
to turn off for good.
