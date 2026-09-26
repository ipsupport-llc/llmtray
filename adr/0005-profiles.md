# 0005 — Config profiles

## Decision

A **profile** is a named bundle of per-model settings; each model is
assigned one, and one profile can serve many models. Everything else is
global (`LLMTrayCore.Pref`, UserDefaults).

- **In a profile** (`LLMTrayCore.Profile`): request settings (temperature,
  top_p, top_k, max_tokens, system prompt), in-app chat tools (which tools,
  image / edit / music models and knobs, Creator mode, unload during image
  generation, the tool-use rule) and `mlx_lm.server` launch settings (KV
  bits / group / start, prefill step, decode concurrency, prompt cache,
  MTP drafter, extra arguments).
- **Global**: port, LAN, idle unload, stall watchdog, auto-start, verbose
  server logging, reasoning display, compaction, chat UI, updates.
  Verbose logging started as a profile field and moved out (45a783e): it
  is diagnostics for the machine, not a model setting. Old files that
  still carry it decode; unknown keys are ignored.

## Layered resolution

`Default` is the base and normally sets every field; any other profile is
an **overlay** that sets only what it changes. Per field
(`LLMTrayCore.ProfileResolver`): overlay → `Default` → `Profile.builtIn`.
Every field is optional for that reason, and so a file written by an
older version, or by hand (`{"name": "Hot", "request": {"temperature":
1.3}}`), still loads. Resolved values are clamped (temperature 0-2, KV
bits to valid ones...): a hand edit must not reach the server as is.
Model-derived guards come last and win over the profile's fields:
`ModelDiscovery.disallowsQuantizedKV` forces KV quantization off
(`ServerLaunch.Context.disallowQuantizedKV`), `--max-tokens` is
capped at the model's trained context, and the drafter is used only if
one is known for the model and the installed runtime supports it.
`extraServerArgs` is appended as written, after the guards: an explicit
conflicting flag there is the user's call, not overridden.

## Storage

`Application Support/LLMTray/profiles/<id>.json` (UUID ids, `default.json`
for Default) and `assignments.json` (`{"<model path>": "<profile id>"}`),
pretty-printed JSON meant to be hand-edited and copied
(`LLMTrayCore.ProfileStore`). `ProfileManager` (app side, one shared
instance for ServerManager, the chat, auto-tune and Settings) re-reads
them when Settings opens.

- **Migration**: a missing `default.json` is created once from the
  pre-profiles `llmtray.*` keys (`ProfileStore.migratedDefault`); the old
  keys are left alone, so a downgrade loses nothing.
- **A broken file is never overwritten.** A `default.json` that doesn't
  decode used to be replaced by the old settings on every Settings open
  (834c7c2): now it's reported, built-ins are used, and Default can't be
  edited until it's fixed. Other unreadable profiles are skipped and
  reported. An unreadable `assignments.json` is moved aside
  (`.corrupt-<time>.json`), not rewritten from an empty table.
- **Assignments survive a missing profile.** Filtering out assignments to
  a profile that didn't load, then saving, lost them for good (deded30);
  they're kept and lookups fall back to Default.
- **Edits are debounced** (400 ms) and flushed at quit and before any
  re-read: a synchronous atomic write per keystroke / slider tick ran on
  the main thread (e502968). Launches read the in-memory profiles.
- **Uninstall Runtime Data keeps `profiles/`** (and `sessions/`): deleting
  it would re-migrate Default from stale pre-profiles settings.
- A former built-in tool rule left unedited in Default is replaced by the
  current one (`formerDefaultToolUsePolicies`): the old rule forbade the
  question-answering tools added later (5bce133).

## Where it applies

- **Launch settings are resolved per launch** from the launched model's
  profile (`ServerManager.launchServerProcess` → `ServerLaunch.arguments`).
  This fixed proxy-driven switches reusing the first start's KV bits: a
  KV-shared model reached through the proxy got quantized KV (0155b6b).
- **No automatic restart.** A profile edit or switch that changes the
  running server's arguments shows a "Restart Server" banner
  (`ServerManager.pendingLaunchChange`) instead of restarting: a restart
  kills in-flight requests (45a783e). The comparison ignores the
  generated sampling flags (`ServerLaunch.restartKey`) and the guards'
  effect (a KV change on a KV-shared model restarts nothing).
- **In-app chat**: `ChatSettings(profile:)` from the resolved profile, sent
  in full with every request; re-resolved before each tool call and
  follow-up, so a tool switched off mid-turn stops at once.
- **External clients**: the proxy fills temperature / top_p / top_k /
  max_tokens from the loaded model's *current* profile only where the body
  lacks them (`ProxyRequestBody.rewrite`, `ServerLaunch.requestDefaults`);
  never the system prompt or tools. First they were only launch flags
  (`--temp` etc.), so moving a slider asked for a restart (3c87a1f).
  Edited at byte level: re-serializing turned a client's `0.0` into `0`,
  which mlx_lm refuses for float params. `top_k` 0 is sent too (else a
  stale launch-time `--top-k` applies); `max_tokens` yields to a client's
  `max_completion_tokens`; a null sampling field is dropped; a sampling
  flag in the profile's extra arguments stays the server's default.
- Auto-tune writes into the profile pinned at the sweep's start; its trial
  values live in memory only (`ServerManager.LaunchTrial`).

## Divergence from the plan

The plan named files by profile name, re-read them on disk change, had
the proxy re-serialize the body and a profile switch restart the server.
The code uses ids, re-reads when Settings opens, edits bytes, and asks.
