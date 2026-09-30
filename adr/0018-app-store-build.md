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
| **Licences** | Full build: notices generated for the vendored runtime | the same, for every vendored runtime. **No GPL** in the bundle: mflux's `opencv-python` carries GPL codecs (never vendored today) |

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
- **First-run import from the Developer ID build.** The container can't
  read `~/Library/Application Support/LLMTray` on its own. An **Import
  from LLMTray (direct download)** button asks the user to grant that
  folder once, then copies chats, profiles and settings; models are
  optional because of their size.
- **System tools** (in the App Store build only; the standalone build keeps
  them):
  - `/bin/sh` in Settings: a Foundation or `NSWorkspace` call instead;
  - `/usr/bin/ditto` in the bug reporter: an in-process zip instead;
  - locating a system Python: not compiled.

### 4. What the first App Store version has

| feature | App Store v1 |
|---|---|
| chat, the OpenAI-compatible API, projects and RAG, tools, MTP drafters | yes |
| Voice Lab (mlx-audio) and music (ACE-Step, mlx-audio) | yes, bundled |
| image generation (mflux) | **only if** its dependencies can ship without GPL code (`opencv-python` has GPL codecs); otherwise it's left out of v1 and the Developer ID build keeps it |
| runtime "Check for Updates" | no: runtimes come with app updates |
| bundled runtime size | about 1.5–2.5 GB. Allowed; the listing says so |

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
   - the import from the Developer ID build.
4. **Licences:**
   - notices for every bundled runtime;
   - mflux without GPL, or image generation left out of v1.
5. **Tips** ([0017](0017-supporters.md)) in the App Store flavor.
6. **TestFlight for Mac** (internal testers), then submission with review
   notes (§5).
