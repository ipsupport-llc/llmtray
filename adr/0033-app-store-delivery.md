# 0033 — App Store delivery from CI

**Status: proposed** (2026-11-15, the user: "так мы можем это все сделать
через cicd?", "работай"). No code before the user has read this.

## Why

A version reaches the App Store by hand today: `App Store pkg` builds the
package ([0018](0018-app-store-build.md)), the user downloads it, uploads it
in Transporter, creates the version in App Store Connect, pastes the texts
and submits. The texts are now in 19 languages (`appstore/metadata`), which
nobody will paste by hand: 19 locales times five fields.

The listing also needs to change often while it is being tuned for search
(139 impressions and 2 downloads in the first two weeks), and each change
rides on a version.

## Decision

`App Store pkg` gets two more jobs after the build. Both talk to App Store
Connect with an API key and both stop for the user's approval.

```
build pkg ──> deliver (approval) ──> submit (approval, separate run)
```

### 1. Build

As today. The package is still kept as a workflow artifact.

### 2. Deliver (input `deliver`, off by default)

Runs in the GitHub environment `app-store`, which has the user as a
required reviewer, so nothing reaches Apple until the user approves the run.

1. **Upload** the package: `xcrun altool --upload-package` with the API key.
   Skipped when App Store Connect already has a build with this number, so
   a failed run can be started again.
2. **Wait** until Apple has processed the build (the builds endpoint,
   `processingState` `VALID`; up to 30 minutes, then fail with the state).
3. **Version**: find the macOS version with this number, or create it. A
   version that is in review or released is an error, not something to
   replace.
4. **Texts**: `asc_metadata.py push --app-info --apply`: name, subtitle,
   keywords, promotional text and description for every locale, and
   "What's New" (below).
5. **Attach** the build to the version.

The job ends with the version in "Prepare for Submission", complete, and a
link to it in the run summary. The user can look at it in App Store Connect
before anything is reviewed.

### 3. Submit (a separate workflow, `App Store submit`)

Input: the version. It runs in a second environment, `app-store-submit`,
with the same required reviewer, and sends the version to App Review.
It is a separate run on purpose: submitting can only be undone by pulling
the version from review, and the user should have seen the version first.

The release after approval stays as it is set in App Store Connect
(manual). CI does not release.

### "What's New"

`appstore/metadata/en-US/release_notes.txt` is written for each release, in
the same PR as the version bump, and is required for a delivery. Other
locales use their own `release_notes.txt` when there is one and the English
text otherwise. Translating the notes with the `Translate` workflow is a
later step; it does not block delivery.

### The key

- An App Store Connect team key with the **App Manager** role: enough to
  upload builds, edit versions and submit; it cannot touch agreements,
  banking or users.
- Stored as **environment** secrets (`ASC_KEY_ID`, `ASC_ISSUER_ID`,
  `ASC_KEY_P8`) of `app-store` and `app-store-submit`, not as repository
  secrets: only a job that names the environment, and that the user has
  approved, can read them.
- Both environments are limited to the `main` branch. The workflow runs
  only by hand (`workflow_dispatch`); there is no pull-request trigger, so
  a fork never runs it.
- The key is written to a temp file for the job and removed at the end,
  like the signing material.

### Not automated

- Agreements, pricing, in-app purchases, age rating, privacy answers.
- Screenshots: the English set is used for every locale. Localized
  screenshots can be added later with the same API.
- Replies to App Review and anything after a rejection.
- Releasing an approved version.

## Code

- `scripts/appstore/asc_metadata.py` (PR #424): the client and the texts.
- `scripts/appstore/asc_release.py`, new, on the same client: `upload`,
  `wait`, `version`, `attach`, `submit`. Every command prints what it will
  do and needs `--apply` to do it, like `push`.
- Offline tests for both in `build.yml`, with recorded responses; the
  deliver job itself can only be proven by a real run.

## Steps

1. Texts and the push script: PR #424.
2. `asc_release.py` with offline tests.
3. The `deliver` job. First real run: the next stable version, with the
   user watching; Transporter stays as the fallback.
4. `App Store submit`.
5. Later: translated release notes, localized screenshots.

## Risks

- **A wrong text goes live in 19 languages.** The delivery stops at
  "Prepare for Submission"; `push` without `--apply` shows the changes
  first; the texts are reviewed in the PR that changes them.
- **The key leaks.** It is revoked in App Store Connect in one click; it
  cannot change payments or users. Environment secrets and the manual
  trigger keep it away from pull requests.
- **Apple's API changes or is down.** The job fails before the step it
  could not do, and every step can be repeated. Transporter and the App
  Store Connect site keep working.
