# 0018 — A Mac App Store build

**Status: accepted** (2026-09-29, the user: "describe what the App Store
needs and start moving"). Step 1, the sandbox spike, passed on 2026-09-29
(see "Spike results"); step 2 is next.

## Why

The **Developer ID build** stays: GitHub releases, Sparkle, notarized since
v0.8.3-beta.7. The App Store build is a second one beside it.

The App Store is where many Mac users look for software, and there is
room in it. LM Studio, Ollama, Jan and GPT4All all stay out, most likely
because their engines download and update separately from the app, which
guideline 2.5.2 forbids. A local AI runtime that follows the rules would
have little competition there.

The listing, in the user's words (memory: llmtray-positioning):

> **LLMTray — Local AI Runtime for macOS**
> Run local models. Serve an OpenAI-compatible API. Connect your coding
> agents and apps.

## What the App Store requires, and where LLMTray stands

| requirement | today (Developer ID build) | App Store build |
|---|---|---|
| **No downloading or installing code** (2.5.2) | the mlx-lm, mlx-audio and mflux runtimes are pip-installed after install | all runtimes **inside the bundle**, signed; they change only with an app update. Models are data and still download (as other App Store model runners do) |
| **App Sandbox** | not sandboxed | `com.apple.security.app-sandbox`, everything in the app's container |
| **No self-updates** (2.4.5) | Sparkle | Sparkle **not linked**; updates come from the App Store; no runtime "Check for Updates" |
| **Runtime exceptions** | vendored Python: `disable-library-validation` | none: every module in the bundle is signed by this team. Tested 2026-09-29: the vendored Python ran MLX on the GPU, mlx_lm generation, ctypes callbacks, tokenizers and numpy with **no** runtime exceptions |
| **Signing** | Developer ID Application, notarized | Apple Distribution plus a Mac App Store provisioning profile; the installer package signed with Mac Installer Distribution |
| **Payments** | none (tips via GitHub Sponsors, [0017](0017-supporters.md)) | StoreKit IAP tips only, and no external payment links |
| **Privacy label** | opt-in telemetry ([0015](0015-telemetry.md)), reviews | declared as-is: usage data, opt-in, not linked to the user; reviews (user content, moderated) |
| **Licences** | Full build: notices generated for the vendored runtime | the same, for every vendored runtime. **No GPL** in the bundle: mflux's `opencv-python` carries GPL codecs, so mflux ships without it (§4) |

## Decision

### 1. One codebase, two builds

**The app isn't rewritten.** The standalone (Developer ID) build stays as
it is: Sparkle, the pip-installed runtimes, plain paths, image generation.
Everything below applies to the App Store build only, behind
`#if APP_STORE`, which the standalone build doesn't compile. A change goes
into the shared code only if it's the same in both builds.

- A build flag `APP_STORE` (`swift build -Xswiftc -DAPP_STORE`). In
  `Package.swift`, the environment variable `LLMTRAY_APP_STORE=1` drops the
  Sparkle dependency, because an unused update framework is still a review
  risk.
- `#if APP_STORE` covers the small set of places that differ:
  - updates;
  - runtime installers and "Check for Updates";
  - the Support section (StoreKit vs the GitHub Sponsors link);
  - paths;
  - where folder access comes from.
- `scripts/build_appstore.sh` does what `build_full_app.sh` does, plus
  every runtime the app uses:
  - the python.org framework, and in it the mlx-lm venv, the mlx-audio
    venv, and mflux only without GPL parts (§4);
  - generated notices;
  - signing with the sandbox entitlements;
  - `productbuild` into a signed `.pkg`;
  - upload with the App Store Connect API key (the one notarization uses),
    by hand and only on the maintainer's say-so: the script never uploads.
  The provisioning profile is `APPSTORE_PROFILE` (a path, nothing
  personal in the script); with an App Store identity or
  `INSTALLER_IDENTITY` and no profile, or a profile for another app
  identifier than `<team>.us.ipsupport.llmtray.appstore`, it stops before
  building.
- **Its own bundle id, `us.ipsupport.llmtray.appstore`** (decided by the
  maintainer, 2026-10-01; the App ID and its Mac App Store profile exist).
  The standalone keeps `us.ipsupport.llmtray`. Both can be installed side
  by side, each with its own preferences, container, login item and
  notifications; the import (§3) brings the standalone's data **and
  settings** in. `AppIdentity` (LLMTrayCore) has both ids; `build_app.sh`
  writes the App Store one into that flavor's Info.plist, and a test keeps
  the scripts, `Resources/Info.plist` and `AppIdentity` in step. What
  depends on the bundle id, per build:

  | | standalone | App Store |
  |---|---|---|
  | `CFBundleIdentifier` | `us.ipsupport.llmtray` (Resources/Info.plist) | `us.ipsupport.llmtray.appstore` (build_app.sh) |
  | App ID / profile / `application-identifier` entitlement | Developer ID, none | `PP59UU9DSQ.us.ipsupport.llmtray.appstore`, from the profile |
  | preferences | `~/Library/Preferences/us.ipsupport.llmtray.plist` | `~/Library/Containers/us.ipsupport.llmtray.appstore/Data/Library/Preferences/…` |
  | data | `~/Library/Application Support/LLMTray` | the same path inside that container |
  | login item (`SMAppService.mainApp`), notifications, per-app language | its own | its own |
  | Keychain (the Hugging Face token) | its own item | its own; the standalone's isn't reachable (entered again) |
  | in-app purchase ids | — | `us.ipsupport.llmtray.tip.*`: **not** derived from the bundle id; App Store Connect and the supporters API know them by this prefix |
  | the CLI's `open -b` (adr/0019) | `us.ipsupport.llmtray` | no CLI |
  | Sparkle | yes | not linked |

  No app group or keychain access group: the two builds share nothing.
- **One of them runs at a time.** Both serve the same port and load the
  same models into the same memory. The single-instance check at launch
  looks for both ids (`AppIdentity.conflict`): another copy of the same
  build is brought forward and this one quits, as before; the other build
  gets an alert naming it ("The App Store version of LLMTray is open. Quit
  it first …") and this one quits. A sandboxed app can't quit another app,
  so the user does. With both set to open at login, whichever starts
  second shows that alert.

### 2. Sandbox entitlements

**The app:**
- `app-sandbox`;
- `network.client`: model downloads, the update check of the list, the
  reviews and supporters APIs;
- `network.server`: the local OpenAI-compatible API, localhost by default,
  and the LAN option;
- `device.audio-input`: Voice Lab;
- `files.user-selected.read-write` and `files.bookmarks.app-scope`: model
  folders, project folders, folder tools, attachments.

**The runners** (the Python server, music, voice, image): **only**
`app-sandbox` and `inherit`, which is Apple's rule for helpers a sandboxed
app launches. They run the bundle's interpreter, never a system or
Homebrew Python.

### 3. Files and folders (App Store build only)

- **Everything the app owns lives in the container:** models by default,
  chats, profiles, projects, caches, `HF_HOME`, `TMPDIR` and the runners'
  scratch space. `RuntimePaths` resolves these through the standard
  directories, so inside the sandbox they already point at the container.
- **Folders outside the container** are granted by the user in an open
  panel and kept as **security-scoped bookmarks**:
  - an extra models folder, for example an LM Studio one;
  - project folders;
  - the folder tools' grants ([0014](0014-folder-tools.md));
  - attachments.

  The existing grants model stays. In the App Store build a grant also
  keeps a bookmark; the standalone build keeps plain paths, as today.
- **Runners reaching a granted folder:** a child with `inherit` sees the
  parent's security-scoped access; the spike proved it. The app resolves
  the bookmark, calls `startAccessingSecurityScopedResource()`, and
  passes the path. No copying and no descriptor passing.
- **Preferences don't move by themselves (checked 2026-09-30).** The first
  time a sandboxed app runs, macOS **moves** a non-sandboxed app's
  preferences *with the same bundle id* (`~/Library/Preferences/<id>.plist`)
  into its container: a test app read the value, and the original file was
  gone, so a Developer ID build still installed started over. That's why
  the App Store build has its own id (§1): nothing is moved, the
  standalone keeps its settings, and the App Store build imports them
  (below). Application Support isn't moved either way. (A sandboxed test
  build made earlier with `us.ipsupport.llmtray` may have taken the
  standalone's preferences into `~/Library/Containers/us.ipsupport.llmtray`;
  that container can be deleted once they're copied back.)
- **Import from the Developer ID build.** The container can't read
  `~/Library/Application Support/LLMTray` on its own. Settings › General ›
  **Import from LLMTray (direct download)** asks the user to grant that
  folder once (for that import only) and copies chats, projects, profiles,
  tool stats and the downloaded image, music, voice and embedding models
  (`StandaloneImport`). Nothing already in the container is overwritten;
  three files are merged instead: the chat library (projects, pins,
  chat→project links), the model→profile assignments (the container's
  winning), and the Default profile (theirs replaces an untouched one,
  else comes as "Default (ipsupport.us)"). No runtime, pin, telemetry or
  folder grant comes along, nothing unfinished or discarded at any depth,
  and an interrupted copy never looks finished. It runs on the main actor
  (clones take well under a second) and the app relaunches right after, so
  no store it holds in memory is saved over what came in. Chat models stay
  where they are: the user grants the models folder as before. The copies are APFS clones: checked in the
  sandbox (2026-09-30), 48 GB of models imported in under a second with no
  change in free space.
- **Settings, in the same import.** The sandbox can't read another app's
  preference domain: `UserDefaults(suiteName: "us.ipsupport.llmtray")` and
  CFPreferences look inside the container, and the folder granted for the
  data (`Application Support/LLMTray`) doesn't cover
  `~/Library/Preferences`. What works is the domain's plist file, granted
  like any user-selected file: right after the data, a second open panel
  starts in `~/Library/Preferences` with `us.ipsupport.llmtray.plist`
  selected; Import reads it (binary or XML) and Cancel keeps the settings
  as they are. Considered and not taken: granting all of `~/Library` in
  one panel (one click less, far more access than the import needs), and
  the `temporary-exception.shared-preference.read-only` entitlement (no
  panel, but a temporary exception is a review risk and stays in every
  version for a one-time import).
  - **What comes:** LLMTray's own keys (`llmtray.*`, `selectedModelID`,
    the per-app `AppleLanguages`), **theirs in place of ours**, a true
    replace: an importable key they don't have (still at its default
    there) is removed here, so the result is their settings, defaults
    included. The user asked for their settings, and it's what the same-id
    move gave; the data import, by contrast, overwrites nothing. A file
    with none of LLMTray's keys changes nothing (removing ours would only
    reset them). The one-time migrations that run at launch
    (`KVSettings.migrateIfNeeded`, the only one keyed by a marker in the
    preferences) run again on what came in: their marker comes with their
    values, so values from a build before the migration are migrated, and
    a choice made after it isn't touched. That includes the models
    folder path (still to be granted in Settings › Models, as the alert
    says), the server, chat, voice and project settings, profiles' inputs,
    the telemetry opt-in itself and the setup wizard's "done".
  - **What doesn't** (`StandaloneImport.leftOutSettings`): state of the
    moment (the pane to reopen after a relaunch, a wizard mid-way, the
    download queue with the other build's destinations, the open chat tabs,
    which this app writes over as it quits), the update channel and every
    `SU*` key (no Sparkle), the telemetry install id and last report (a new
    install), `llmtray.supporters.*` (this build's proof is its
    purchases), the sandbox's own bookmarks, and anything of AppKit's or
    the system's (window frames, open-panel state).
  - **Limits:** the Hugging Face token is a Keychain item of the other
    app's and isn't reachable: entered again. Folder grants and the models
    folder need the user's OK again (no bookmark comes with a path). The
    file is read as it is on disk; with the standalone quit (it can't run
    beside this one) that's its latest. The second panel's preselection
    is the open panel's (a file URL as `directoryURL`); if a macOS version
    doesn't select it, the message names the file. Only that file in the
    user's real `~/Library/Preferences` is taken (links resolved; the real
    home, not the container's): a copy elsewhere, or a link to one, is
    refused. The final alert says what became of the settings: brought,
    the same already, none to bring, kept (the panel was cancelled), or
    refused.
- **The command-line tool** (adr/0019, standalone only) starts the
  standalone when no socket answers. With the App Store build running it
  fails at once instead ("the App Store version of LLMTray is running …
  quit it, or use its window"), without starting anything: the start
  would only show the other-build alert and time out. It finds the App
  Store build through libproc (the executable's bundle and its id), as it
  has no AppKit.
- **System tools** (in the App Store build only; the standalone build keeps
  them):
  - `/bin/sh` in Settings: a Foundation or `NSWorkspace` call instead;
  - `/usr/bin/ditto` in the bug reporter: an in-process zip instead;
  - locating a system Python: not compiled;
  - relaunching after a setting change: the new instance starts through
    `NSWorkspace` and waits for the old one to exit (`--after-pid`), with no
    shell;
  - the leftover-process scan (`OrphanScan`): not in the App Store build.
    Checked in the sandbox (2026-09-30): `/bin/ps` can't be run ("Operation
    not permitted"); `sysctl` `KERN_PROC_ALL` lists every process and
    `KERN_PROCARGS2` / `proc_pidinfo` read a leftover runner's marker and
    parent, but the app **may not signal it** (SIGTERM: "Operation not
    permitted"), so finding one would be of no use. None is left behind
    instead: every Python process the app starts exits when its parent goes
    away (`python-packages/sitecustomize.py`, for processes with
    `LLMTRAY_EXIT_WITH_PARENT=1`, which the app sets for itself at launch),
    also when the parent was already gone as it started. Checked: both
    exit within 0.5 s; a control without the variable stays.

### 4. What the first App Store version has

| feature | App Store v1 |
|---|---|
| chat, the OpenAI-compatible API, projects and RAG, tools, MTP drafters | yes |
| Voice Lab (mlx-audio) and music (ACE-Step, mlx-audio) | yes, bundled |
| image generation (mflux): z-image-turbo, FLUX.2 klein generation and editing | yes, bundled: mflux from PyPI without `opencv-python` and torch (below) |
| runtime "Check for Updates" | no: runtimes come with app updates |
| bundled runtime size | about 1.5–2.5 GB. Allowed; the listing says so |

**Image generation without GPL.** mflux (MIT) requires `opencv-python`
and torch. Every `opencv-python` wheel, `-headless` too (checked:
4.14.0.94), bundles FFmpeg built with `--enable-gpl` plus `libx264` and
`libx265` (GPL): it can't be in an App Store bundle. mflux uses OpenCV only
in the ControlNet/OpenPose preprocessors and torch only for PyTorch-format
weights, but imported both at module load. Since 0.21.0 mflux imports them
only where they're used (mflux-community/mflux#787, carrying our #782; our
fork `ipsupport-llc/mflux` served until that release, 2026-10-04), and the
App Store build installs mflux from PyPI without its
dependencies and then all of them but those two
(`runtime/mflux_runtime.json`; `jinja2`, which torch used to bring along,
is added). The models LLMTray runs are MLX-native and need neither; checked
with neither installed and no network (z-image-turbo 512² in 9 steps,
klein generation and editing in 4). The build fails if an excluded package
comes back through another one. It also saves torch's ~400 MB. The
standalone build keeps pip-installing mflux from PyPI on the user's Mac.

### 5. Review risks and how they're met

- **2.5.2, executable code:** everything that runs is in the signed
  bundle, and models are weights (data). The review notes say so in plain
  words.
- **1.1 / 1.2, objectionable content:**
  - The Hugging Face browser reaches third-party models. Model cards are
    labelled as third-party.
  - A content notice appears before downloading.
  - The review notes explain that the app ships no models.
- **The local server:** it binds localhost by default; LAN is opt-in with
  a warning. The review notes explain that it serves the user's own
  models to the user's own apps.
- **2.3, accurate metadata:** the screenshots show real features, and no
  other product's name is used in the name, keywords or text.
- **Size and first launch:** the app works right away; models are
  downloaded only when the user asks.

### 6. Metadata

- **Name:** LLMTray.
- **Subtitle:** Local AI Runtime for macOS (26 of 30 characters).
- **Promotional text:** "Run local models. Serve an OpenAI-compatible
  API. Connect your coding agents and apps."
- **Tips copy:** "No subscriptions. No feature locks. Support development
  if LLMTray is useful to you."
- **Category:** Developer Tools; secondary: Productivity.
- **Also needed:** a privacy policy URL and a support URL on ipsupport.us.

## Spike results (2026-09-29, MacBook Air M5, macOS 27)

`scripts/appstore/build_sandbox_spike.sh` builds `sandbox_spike.swift`
into a sandboxed app, with the entitlements of §2 and the Full build's
Python (runners signed with only `app-sandbox` + `inherit`, hardened
runtime). All passed:

| check | result |
|---|---|
| the sandbox is really on | the child is denied `~/.zshrc` (`Operation not permitted`) |
| bundled Python + MLX | runs on the GPU (`Device(gpu, 0)`) |
| `HF_HOME` | written in the container (`~/Library/Containers/…/Data/hf`) |
| local server | a child binds 127.0.0.1, the app connects |
| a user-granted folder | an app-scope bookmark resolves; the child lists it and **runs mlx_lm on the model in it** ("Paris.") |

What this settles:

- **Outside folders work through bookmarks** (§3), for models and
  projects alike.
- **No venv in the App Store build.** The framework's interpreter runs
  with the packages on `PYTHONPATH` (plus `PYTHONNOUSERSITE`,
  `PYTHONDONTWRITEBYTECODE`, and `HOME`, `TMPDIR`, `HF_HOME` in the
  container). That removes the absolute paths in `pyvenv.cfg` and the
  interpreter link.
- **The runners need nothing but `app-sandbox` + `inherit`**, as §2 says.
  Together with the runtime-exceptions test, the whole bundled stack runs
  with no exceptions at all.

### The runners in the sandbox (2026-09-30)

`scripts/appstore/build_runners_spike.sh`: a sandboxed test app with the
App Store build's Python, packages and runners (app-sandbox + inherit), the
models read through a read-only exception only it has. On the MacBook Air
M5, one after the other:

| check | result |
|---|---|
| image, z-image-turbo 512², 9 steps | PASS, 65 s |
| image, FLUX.2 klein 512², 4 steps | PASS, 21 s |
| music, ACE-Step turbo, 10 s | PASS, 23 s |
| voice, VoiceChat GPTQ-3 load + warm-up | PASS, 30 s (rtf 1.85 right after the others, on a fanless Mac: not compared cold) |

## Steps

0. **The user, in App Store Connect / Certificates:**
   - ~~an App ID `us.ipsupport.llmtray.appstore` with the In-App Purchase
     capability~~ and its Mac App Store provisioning profile: done
     (2026-10-01; §1);
   - the app record;
   - the Apple Distribution and Mac Installer Distribution certificates;
   - a Mac App Store provisioning profile;
   - the privacy policy and support URLs.
1. ~~**Sandbox spike (me).**~~ Passed; see "Spike results".
2. **`APP_STORE` flavor:**
   - the `Package.swift` switch;
   - `#if APP_STORE` around updates, installers and support;
   - `build_appstore.sh` with every runtime bundled;
   - the entitlements files.
3. **Sandbox fixes:**
   - security-scoped bookmarks for model, project and folder-tool
     folders;
   - no system tools;
   - the container paths for runners;
   - ~~the import from the Developer ID build~~: done (§3).
4. **Licences:**
   - scipy (an mlx-audio dependency: `mlx_audio/resample.py` needs
     `scipy.signal`) ships `libgfortran`, `libgcc_s`, `libquadmath`: GPLv3
     with the GCC Runtime Library Exception, which is there precisely so
     they can ship in non-GPL software. **Settled (maintainer, 2026-09-30):**
     kept;
   - notices for every bundled runtime;
   - ~~mflux without GPL~~: done (§4, "Image generation without GPL").
5. **Tips** ([0017](0017-supporters.md)) in the App Store flavor.
6. **TestFlight for Mac** (internal testers), then submission with review
   notes (§5).
