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
  - upload with the App Store Connect API key (the one notarization uses).
- **The same bundle id `us.ipsupport.llmtray`.** One app on one Mac: the
  App Store copy replaces the Developer ID one, and a first-run import
  (§3) brings the user's data into the container.

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
- **Preferences move, the rest doesn't (checked 2026-09-30).** The first
  time a sandboxed app runs, macOS **moves** a non-sandboxed app's
  preferences with the same bundle id (`~/Library/Preferences/<id>.plist`)
  into its container: a test app read the value, and the original file was
  gone. With `us.ipsupport.llmtray` for both builds, someone switching to
  the App Store build keeps their settings, but a Developer ID build still
  installed then starts over (setup wizard, defaults). **Open, the
  maintainer's call before the first upload:** keep one bundle id (switching
  is the common case) or give the App Store build its own (both side by
  side, settings imported by hand). Application Support isn't moved.
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
  change in free space. Settings arrive by themselves (above).
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
| image generation (mflux): z-image-turbo, FLUX.2 klein generation and editing | yes, bundled: our mflux fork without `opencv-python` and torch (below) |
| runtime "Check for Updates" | no: runtimes come with app updates |
| bundled runtime size | about 1.5–2.5 GB. Allowed; the listing says so |

**Image generation without GPL.** mflux (MIT) requires `opencv-python`
and torch. Every `opencv-python` wheel, `-headless` too (checked:
4.14.0.94), bundles FFmpeg built with `--enable-gpl` plus `libx264` and
`libx265` (GPL): it can't be in an App Store bundle. mflux uses OpenCV only
in the ControlNet/OpenPose preprocessors and torch only for PyTorch-format
weights, but imported both at module load. Our fork
(`ipsupport-llc/mflux`, branch `llmtray`, from v.0.20.0) imports them only
where they're used, and the App Store build installs mflux without its
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
   - an App ID `us.ipsupport.llmtray` with the In-App Purchase
     capability;
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
   - **open:** scipy (an mlx-audio dependency, in the bundle since step 2)
     ships `libgfortran`, `libgcc_s`, `libquadmath`: GPLv3 with the GCC
     Runtime Library Exception, which allows shipping them in non-GPL
     software. To settle before submission: confirm that's acceptable, or
     keep scipy out. It can't simply be left out: `mlx_audio/resample.py`
     imports `scipy.signal` at load, through `mlx_audio.utils` and
     `audio_io`, which the music runner uses. A lazy import there in our
     mlx-audio fork (the mflux way) would let it go wherever no runner
     actually resamples;
   - notices for every bundled runtime;
   - ~~mflux without GPL~~: done (§4, "Image generation without GPL").
5. **Tips** ([0017](0017-supporters.md)) in the App Store flavor.
6. **TestFlight for Mac** (internal testers), then submission with review
   notes (§5).
