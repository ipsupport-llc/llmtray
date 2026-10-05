# Releasing LLMTray

Two products from one codebase (adr/0018):

| | Website build | Mac App Store build |
|---|---|---|
| Bundle id | `us.ipsupport.llmtray` | `us.ipsupport.llmtray.appstore` |
| Signed with | Developer ID Application, notarized | Apple Distribution + 3rd Party Mac Developer Installer |
| Ships as | `LLMTray.dmg`, `LLMTray-Full.dmg` on GitHub Releases | `.pkg`, uploaded to App Store Connect in Transporter |
| Updates | Sparkle (stable / beta channels) | the App Store |
| Built by | `release.yml`, on every `v*` tag | `appstore.yml`, **by hand** |
| Command-line tool | yes | no |

## Website release

1. Merge to `main` through PRs only (review + green checks; read every check as *pass*, not "no checks reported").
2. Beta: tag `vX.Y.Z-beta.N` on `main` and push it. `release.yml` builds, signs, notarizes, publishes a GitHub **pre-release** and the Sparkle beta feed. Beta DMGs can be downloaded straight from the release page (a clean Mac needs no beta channel).
3. Test the beta. For a clean-install test use **`LLMTray-Full.dmg`** (Python inside; the thin DMG needs a system Python).
4. Stable: tag `vX.Y.Z` on the **same commit** as the tested beta and push it. Users of the stable channel get it through Sparkle; the site's download buttons always point at the latest stable.

Tags `v*` are admin-only. Never retag a published version: make a new one.

## Mac App Store release

### One-time setup

**App Store Connect record.** Apps > + New App > macOS, Name *LLMTray*, Bundle ID **`us.ipsupport.llmtray.appstore`** ("LLMTray App Store"). Not `us.ipsupport.llmtray` — that's the website build; a record with it makes Transporter fail with *"No suitable application records were found"*. A record's bundle id can't be changed: remove it and create a new one.

**CI secrets** (repo Settings > Secrets, or `gh secret set`):

| Secret | What |
|---|---|
| `APPSTORE_P12_BASE64` | One `.p12` with **both** identities: *Apple Distribution: IPSupport LLC* and *3rd Party Mac Developer Installer: IPSupport LLC*. Keychain Access: select both certificates > Export 2 items. |
| `APPSTORE_P12_PASSWORD` | That `.p12`'s password. |
| `APPSTORE_PROFILE_BASE64` | The "LLMTray App Store" Mac App Store provisioning profile (developer.apple.com > Profiles). |

```bash
base64 -i appstore.p12 | gh secret set APPSTORE_P12_BASE64 -R ipsupport-llc/llmtray
gh secret set APPSTORE_P12_PASSWORD -R ipsupport-llc/llmtray
base64 -i LLMTray_Mac_App_Store.provisionprofile | gh secret set APPSTORE_PROFILE_BASE64 -R ipsupport-llc/llmtray
rm appstore.p12
```

When a certificate or the profile expires (yearly), export again and replace the secrets.

### Every App Store version

1. Make the website release first (stable tag `vX.Y.Z`). App Store versions are numbers only: no betas.
2. **Build the pkg:** GitHub > Actions > **App Store pkg** > Run workflow.
   - `tag`: the stable tag, e.g. `v0.8.6`.
   - `build_number`: empty for a version's first upload. Another upload of the **same** version needs a **higher** build number with at most three numbers, e.g. `0.8.601`, then `0.8.602`.
   - The app is built from the tag; the build scripts from `main` (packaging fixes apply to older tags too).
   - The job checks the bundle (every Mach-O signed, no `.o`/`.a`, version, bundle id, installer signature) and attaches **`LLMTray-X.Y.Z-AppStore.pkg`** as the run's artifact (kept 30 days).
3. **Upload:** download the artifact, unzip, open **Transporter** (signed in with an Apple ID of the IPSupport LLC team), drag the `.pkg` in, **Deliver**. Nothing uploads automatically.
4. Wait for *Delivered* then *Processing* (10–30 min, an email when done). The build shows up under TestFlight > macOS. Export compliance: standard HTTPS only ("None of the algorithms mentioned above"; the Info.plist already answers it).
5. **The version page in App Store Connect:** select the build, then fill in what's new. Metadata is kept in this repo:
   - `appstore/metadata/en-US/`: `promotional_text.txt` (≤170), `description.txt` (≤4000), `keywords.txt` (≤100, comma-separated, no other products' names), `urls.txt`, `review_notes.txt` (App Review Information > Notes).
   - `appstore/screenshots/`: 2880×1800, sRGB, no alpha — upload in file order.
6. **App Privacy:** Usage Data (anonymous statistics, optional) — not linked to the user, not used for tracking. Everything else: not collected.
7. Add for Review > Submit.

### Building the pkg locally (fallback)

```bash
VERSION=0.8.6 \
APPSTORE_PROFILE=~/Downloads/LLMTray_Mac_App_Store.provisionprofile \
SIGN_IDENTITY=<Apple Distribution identity hash> \
INSTALLER_IDENTITY=<3rd Party Mac Developer Installer identity hash> \
./scripts/build_appstore.sh        # -> .build/appstore/LLMTray.pkg
```

Identity hashes: `security find-identity -v`. Use hashes, not names: renewed certificates repeat the name. Build from a checkout of the tag (`git worktree add <dir> vX.Y.Z`) with current `scripts/` copied in. App Store builds delete `Package.resolved`: restore it (`git checkout -- Package.resolved`) and never commit with `-a` after one.

Check before uploading — the same checks `appstore.yml` runs:

```bash
APP=.build/appstore/LLMTray.app
codesign --verify --deep --strict "$APP"
find "$APP" -type f -print0 | while IFS= read -r -d '' f; do
  file "$f" | grep -q Mach-O && { codesign -v "$f" 2>/dev/null || echo "UNSIGNED $f"; }
done
find "$APP" \( -name '*.o' -o -name '*.a' \)          # must print nothing
```

The bundled Python is signed with `inherit` and exits 133 outside the app. To smoke-test it, copy the app, ad-hoc re-sign `bin/python3.X` in the copy, run it with `PYTHONPATH=…/Contents/Resources/python-packages`.

### Screenshots

Raw captures: 2880×1800 (a VM at 2880×1800, 220 PPI, for the UI; the host for image and music, which a VM makes slowly). Close popovers and menus, hide the Dock. Then convert them to sRGB without alpha, and compose the store images:

```bash
python3 scripts/appstore/compose_screenshots.py <raw dir> appstore/screenshots   # needs Pillow
```

Titles, subtitles and crops are in the script's `shots` list.

## Known problems and their fixes

| Symptom | Cause / fix |
|---|---|
| Transporter: *No suitable application records were found. Verify your bundle identifier "us.ipsupport.llmtray.appstore"* | The App Store Connect record has the website build's bundle id, or Transporter is signed in with an Apple ID outside the team. See One-time setup. |
| Transporter: *Invalid Code Signing … python.o must be signed … (90284)* | Unsigned Mach-O files (object files, static libraries) in the bundle. `build_full_app.sh` removes them in the App Store layout; the CI check fails if any is left. |
| A re-upload is refused as a duplicate build | Same `CFBundleVersion`: run the workflow again with a higher `build_number`. |
| Local `build_full_app.sh` on macOS 27: `Killed: 9` while creating the venv, and `.build/app/LLMTray.app` disappears | macOS 27 kills an ad-hoc-signed binary run inside a bundle already signed with Developer ID, and removes the bundle. Build the base unsigned (`env -u SIGN_IDENTITY ./scripts/build_app.sh`), then run `build_full_app.sh` with `SIGN_IDENTITY` (it signs everything at the end). CI (macOS 15) isn't affected. |
| A fresh install isn't treated as fresh (no Getting Started project) | Leftovers of an earlier install: `defaults delete us.ipsupport.llmtray` and move `~/Library/Application Support/LLMTray/{sessions,projects}` aside. |
