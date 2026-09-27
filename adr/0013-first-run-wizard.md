# 0013 — The first-run wizard

**Status: accepted** (2026-09-26, by the user). Nothing here is built yet; the facts
about today's first launch are from the code as of v0.7.3-beta.1.

## Why

A fresh install today does nothing visible. `quickStart` returns
silently when there is no saved model (`LLMTrayApp.swift`,
`attemptStart`): the popover shows an empty model picker, a disabled
Start and "No messages yet". The runtime is installed lazily on the
first Start, with progress only in the server log; a Light build without
Python 3.10+ fails there, in the header's status line. Images, music,
Creator mode, the web tools, the API and its switching policy are spread
over four Settings panes, and nothing says they exist. There is no
first-run flag at all (`Preferences.swift`).

## Decision

A **setup window** (not the popover) that opens on the first launch and
walks through the app in a few short steps. Every step can be skipped,
and nothing is downloaded or turned on without the user choosing it
([0009](0009-media-generators.md), [0012](0012-project-files-rag.md):
every heavy feature and each of its models is opt-in, with its size
shown). What it sets is exactly what Settings sets: the wizard is a
guided front end to the same code, not a second configuration path.

### When it opens

- `Pref.onboardingCompleted` (a version number) is unset **and** no
  model is selected: a fresh install. It opens once the status item
  exists, before `quickStart`.
- Existing users (a model selected) never get it on their own; Settings
  → General and the menu bar's right-click menu offer **Set Up
  LLMTray…** to open it again, starting from their current settings.
- Closing it (or Skip on the first step) counts as done: it doesn't come
  back, the entry point stays.
- Progress through the steps is saved, so a relaunch mid-wizard resumes.

### The steps

1. **Welcome** — the banner (the "Welcome to LLMTray" artwork, in the
   app's current branding), one line per capability (chat, images,
   music, agents, API), and the privacy line: models run on this Mac;
   only the optional web tools reach the internet.
2. **Your Mac** — chip, memory, the GPU memory limit (Metal's
   `recommendedMaxWorkingSetSize`; the app reads none of it today, only
   `iogpu.wired_limit_mb` in the bug report), free disk. The runtime:
   Full build → "ready"; Light → the Python found (`PythonLocator`), or
   none, with how to get one or the Full DMG, and **Check again**. The
   runtime installs here in the background (`MLXRuntimeInstaller.
   ensureReady`) with visible progress, instead of on the first Start.
3. **Models folder** — `~/.llmtray/models` by default; LM Studio's
   folder offered when it exists and has models (today only a button in
   Settings, never detected). Models already there are listed.
4. **A chat model** — pick one of the models found, or a recommended
   download: a curated list (`runtime/recommended_models.json`: HF repo,
   what it's good at, vision / tools / reasoning, languages, licence,
   minimum memory) filtered by this Mac's GPU memory with the HF
   browser's fit estimate (`ModelFitLevel`), sizes read live from the
   Hub (`HubModelInfo`); or **Browse Hugging Face…** (the existing
   `HFBrowserView`); or skip. The download is started here (it's the one
   thing needed to chat) and continues in the background.
5. **What else** — each an opt-in with its size, off by default:
   image generation (model choice), image editing, music (model choice),
   Creator mode (and its countdown), the web tools (marked as using the
   internet), project files (once shipped), with one line of what each
   does and a small example.
6. **Apps and agents** — the local API: port, local network on/off, the
   model switching policy (switch / ask / keep), and a copyable
   `OPENAI_BASE_URL=http://localhost:<port>/v1` snippet.
7. **Staying up to date** — launch at login, update checks, the beta
   channel, and (when it exists) the opt-in telemetry with its exact
   field list.
8. **Done** — a summary of what was chosen and what is downloading. The
   chosen downloads run **after** Finish, one at a time, in a queue shown
   in the popover (the chat model first); the wizard can be closed while
   they run. When the chat model is ready, the server starts on its own.

### How it's built

- **One setup service shared with Settings.** Today the "download, then
  enable" flows are private methods of `ProfilesPane`
  (`confirmAndDownload`, `confirmMusicDownload`) and launch-at-login is
  private to `GeneralPane`. They move to a `FeatureSetup` service
  (image/edit/music model download + enable on the Default profile,
  launch at login, models folder) that both Settings and the wizard call;
  the wizard writes profile values through `ProfileManager` (the Default
  profile), prefs through the same `Pref` keys.
- **A download queue** for the wizard's choices (and reusable by
  Settings): sequential, resumable, visible in the popover, each item
  through its existing path — `HFModelBrowser.download` for the chat
  model (posting `.modelsDidChange` as `HFBrowserView` does),
  `MfluxManager.downloadModel`, `MusicManager.download`, the embedder
  manager ([0012](0012-project-files-rag.md)). Free space checked
  before each.
- **Pure logic in LLMTrayCore, tested:** when the wizard opens, the
  recommendation filter (memory tiers, fit), the plan (choices → the
  ordered list of downloads and settings), resuming.
- **Hardware probe** in LLMTrayCore (chip, memory, Metal working set,
  free disk), replacing the bug reporter's private `sysctl` helper.
- **Gated models** in the curated list are marked; a direct download of
  one needs a token (`HFToken`), which the step says instead of failing
  on a 401.

## Plan

1. **Refactor PR** (no visible change): `FeatureSetup` out of the
   Settings panes, the hardware probe, the download queue.
2. **The curated list** `runtime/recommended_models.json`, with the user
   (which models, per memory tier), and its filter + tests.
3. **The wizard** window and steps, the trigger and the entry points,
   the resume state; l10n.
4. **Polish**: the banner asset, accessibility, a packaged-app test of
   a fresh first launch (a clean user account or a wiped Application
   Support folder).

## Built so far (steps 1 and 2)

- `FeatureSetup` (app): state and async operations; the Settings panes
  keep their confirmation alerts and error lines. `DownloadQueue` (app)
  over `LLMTrayCore.DownloadQueueState` (tested): one at a time, a chat
  model ahead of what's waiting, free space (plus a 2 GB margin) checked
  before each. An image or music download can't be stopped part way (a
  pip / `snapshot_download` child): cancelled, it finishes and its
  feature stays off. `HardwareProbe` (Core) also feeds the bug report.
- `runtime/recommended_models.json`, bundled by `build_app.sh`: each
  entry lists its memory `tiers` (a Mac's tier is its RAM: under 12 GB
  → 8, under 20 → 16, under 32 → 24, else 32) and a `minMemoryGB`; one
  entry per tier is `recommended`. `ModelRecommendations.picks` offers a
  tier's models that the Mac has the memory for, whose weights fit the
  GPU limit (the wired limit if the user set one, else Metal's working
  set) and that `ModelFitLevel` (moved to Core) doesn't call unlikely;
  recommended first, then the file's order. Repos were checked on the
  Hub (exist, ungated, sizes from `?blobs=true`) and against the pinned
  mlx-lm's model code: no gpt-oss (no harmony tool parser there), no
  `gemma4_unified` conversions.

## Decided with the user (2026-09-26)

- The curated list goes by memory tier (8 / 16 / 24 / 32+ GB), and **our
  own GPTQ checkpoints lead it as the recommended picks**: Gemma 4
  26B-A4B (`roman220220/gemma-4-26B-A4B-it-gptq-mlx-jang`) for 24 GB and
  up, Gemma 4 E4B (`roman220220/gemma-4-E4B-it-gptq-mlx-jang`) below;
  the rest of each tier filled in PR 2 from what fits.
- The chat-model download **starts at step 4**, right when it's picked,
  and runs on while the wizard continues; everything else after Finish.
- The banner: `docs/assets/welcome-banner.jpg` (the app's green-brain
  branding), shown on the Welcome step.
