# 0008 — Localization and releases

## Localization

- **Keys are the English text.** SwiftUI literals (`Text("...")`,
  `Button`, `.help`, ...) and `NSLocalizedString("...", comment:)`, with
  `String(format:)` for arguments (`%lld` for Int, `%@` for String). A
  string a language lacks shows in English; an edited English string is a
  new key. Keep interpolations in UI text to Ints or plain Strings: the
  extractor guesses the specifier from the expression. Only
  `Sources/LLMTray` is scanned — LLMTrayCore has no UI text.
- **One folder per language**: `Resources/Localization/<lang>.lproj/
  Localizable.strings`. `build_app.sh` copies every folder and lists it in
  `CFBundleLocalizations`; adding a language adds a folder. The in-app
  language picker sets the app's own `AppleLanguages` (`SettingsPanes`).
- **`scripts/l10n.py`**: `extract` regenerates `en.lproj` from the
  sources; `check` (in `build.yml`) fails on a stale English base, an
  invalid file or mismatched format arguments — missing keys are only
  reported; `translate`, `fix-order`, `missing`, `import-missing`.
- **Translated in CI, not by hand.** `translate.yml` runs on pushes to
  `main` touching the UI sources, the localizations or the script:
  missing keys go to OpenAI, the result is a PR from the one
  `translations/auto` branch. The key is only the `OPENAI_API_KEY`
  repository secret, in that one step's environment (without it: a
  warning, no translation); the `languages` input is validated and passed
  as data, not shell source. Existing translations are never overwritten,
  so a native speaker's fix sticks; keys gone from the code are dropped.

### Lessons

- **A translation must read the same arguments as its key.** Comparing
  sorted specifiers let a reordered `%d ... %@` through, and
  `String(format:)` read an Int as an object: crashes in ja/ko/tr/hi/
  zh-Hant (c234545). Arguments are compared by position, `%d` vs `%lld`
  width too (b99c7e3); `fix-order` rewrites reorders as `%1$@`.
- **Cost.** The first full run (15 languages, ~9k characters) cost
  dollars: gpt-5.5 bills hidden reasoning as output, and 25-string batches
  repeated the prompt ~165 times. Now gpt-5-mini, minimal reasoning,
  batches of 100 (5ffee5b); an open proposal's translations are reused,
  not bought again, importing only keys `main` still lacks (a3780f6,
  b99c7e3).

## Releases

- **Tags**: `vX.Y.Z` stable, `vX.Y.Z-beta.N` beta (a GitHub pre-release,
  so `releases/latest` stays stable). Creating, moving or deleting a `v*`
  tag is admin-only; `main` takes PRs only, with one approval and the
  `build` and `release-dry-run` checks. These are GitHub rulesets, not in
  the repo: as read from the rulesets API when this was written.
- **`release.yml`** on a tag: one build, two DMGs — `LLMTray.dmg`, then
  `build_full_app.sh` turns the same app into `LLMTray-Full.dmg` (thin
  first; see [0001](0001-mlx-runtime.md)). Unversioned asset names keep
  `releases/latest/download/...` a permanent link. Ad-hoc signed, not
  notarized. Uploaded to a draft, published only once every file is up;
  `make_latest: legacy` goes with the publish request (a draft's is
  ignored). The feed: [0004](0004-update-feed.md).
- **`release-dry-run`** (`build.yml`) runs the same steps on every PR with
  a stub signature: release scripts only ran on a real tag, so v0.6.7's
  build died there of SIGPIPE (`head` in a pipefail pipeline, bd809f8).
- **The Full build's Python is pinned** (`runtime/python_runtime.json`):
  a new CPython minor ships before MLX wheels do (51e9997).

### CI builds on an older toolchain

The app's build workflows run on `macos-14` (the Pages feed job on
`ubuntu-latest`), an older Xcode than local builds (Swift
6.3/6.4, macOS 27 SDK). What users get is what CI compiles. Seen:

- A `Timer` closure capturing `self` into `Task { @MainActor in }`:
  rejected; target/selector instead (91dd16f, `AudioPlayback`).
- `WritableKeyPath<...> & Sendable` can't be inferred (56d54ed,
  `ProfileField`); some closure types must be spelled out (db0c383,
  8c73234); a View without property wrappers needs an explicit
  `@MainActor` (8bbaa70).
- Same code, different behavior: a `Button` with `onDrag` dragged locally
  and not in the CI build — published betas couldn't drag chats
  (35eaed1).
- The other way: Swift 6.4 builds into `.build/out/Products/Release`,
  which `build_app.sh`'s Sparkle lookup missed (88ff4ca).
