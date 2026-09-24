# 0004 — The Sparkle update feed

## Decision

The feed (`appcast.xml`) is never committed. Each release uploads its own
signed metadata (`LLMTray.dmg.sparkle.json`, from `scripts/sign_release.sh`)
next to the DMGs; `.github/workflows/pages.yml` rebuilds the whole feed from
the GitHub Releases (`scripts/render_appcast.py`) and deploys it with the
site. Release runs used to rewrite `docs/appcast.xml` and push it to `main`
as a bot commit — a commit per release, a feed diff in every pull, and a
fetch/rebase/retry against `main` inside each release.

## Rules

- Two channels: the highest stable (no channel, everyone) and the highest
  beta newer than it (`<sparkle:channel>beta</...>`, beta users only).
- Chosen by version number, never date or `/latest`; the channel comes from
  the tag (`vX.Y.Z` / `vX.Y.Z-beta.N`), not the pre-release checkbox. Drafts
  and releases without metadata are skipped; no stable → no deploy.
- `CFBundleVersion` for `X.Y.Z-beta.N` is `X.Y.ZbN` (`sparkle_version.sh`):
  Sparkle treats `0.6.8-beta.1` as *equal* to `0.6.8` and to every other
  `-beta.N`, so betas would never update.
- A release made with `GITHUB_TOKEN` doesn't fire `release` events;
  `release.yml` dispatches `pages.yml` (on `main`, which the `github-pages`
  environment requires).
