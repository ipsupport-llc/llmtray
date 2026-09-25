#!/usr/bin/env python3
"""Builds the Sparkle feed (appcast.xml) from the GitHub Releases themselves.

Nothing about the feed is kept in git: each release carries its own
LLMTray.dmg.sparkle.json (written and signed by scripts/sign_release.sh),
and the Pages workflow rebuilds the whole feed from scratch on every
deploy -- so re-running is idempotent, and deleting or editing a release
fixes the feed on the next deploy.

Usage:
  gh api --paginate --slurp 'repos/OWNER/REPO/releases?per_page=100' > releases.json
  render_appcast.py releases.json out.xml [--meta-dir DIR]

--meta-dir: read <tag>.json from DIR instead of downloading each release's
metadata asset (tests, offline runs).

Two channels, one item each: the highest stable (no <sparkle:channel>, so
every user gets it) and the highest beta (<sparkle:channel>beta</...>,
offered only to "beta updates" users) -- the beta only while it's newer
than the stable. Chosen by version number, never by date or /latest; the
channel comes from the tag (vX.Y.Z vs vX.Y.Z-beta.N), not from the
release's pre-release checkbox. Drafts are skipped (their assets 404
publicly). A release without the metadata asset is skipped with a warning.
"""
import json
import re
import sys
import urllib.request
from email.utils import format_datetime
from datetime import datetime
from pathlib import Path
from xml.sax.saxutils import escape

META_ASSET = "LLMTray.dmg.sparkle.json"
DMG_ASSET = "LLMTray.dmg"
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?$")
FEED_URL = "https://ipsupport-llc.github.io/llmtray/appcast.xml"


def version_key(tag: str):
    """0.6.9-beta.2 < 0.6.9-beta.10 < 0.6.9 < 0.6.10-beta.1."""
    m = TAG_RE.match(tag)
    if not m:
        return None
    major, minor, patch, beta = m.groups()
    return (int(major), int(minor), int(patch), beta is None, int(beta or 0))


def load_releases(path: str) -> list[dict]:
    data = json.loads(Path(path).read_text())
    # `gh api --paginate --slurp` gives a list of pages.
    if data and isinstance(data[0], list):
        data = [r for page in data for r in page]
    return data


def metadata(release: dict, meta_dir: str | None) -> dict | None:
    tag = release["tag_name"]
    if meta_dir:
        p = Path(meta_dir) / f"{tag}.json"
        return json.loads(p.read_text()) if p.exists() else None
    asset = next((a for a in release.get("assets", []) if a["name"] == META_ASSET), None)
    if not asset:
        return None
    with urllib.request.urlopen(asset["browser_download_url"], timeout=60) as r:
        return json.load(r)


def pick(releases: list[dict], meta_dir: str | None) -> dict[str, tuple[dict, dict]]:
    """channel -> (release, metadata) of the highest usable version."""
    candidates = []
    for r in releases:
        key = version_key(r.get("tag_name", ""))
        if r.get("draft") or key is None:
            continue
        if not any(a["name"] == DMG_ASSET for a in r.get("assets", [])):
            continue
        candidates.append((key, r))
    chosen: dict[str, tuple[dict, dict]] = {}
    for key, r in sorted(candidates, key=lambda c: c[0], reverse=True):
        channel = "stable" if key[3] else "beta"
        if channel in chosen:
            continue
        meta = metadata(r, meta_dir)
        if not meta:
            print(f"warning: {r['tag_name']} has no {META_ASSET}, skipped", file=sys.stderr)
            continue
        if meta.get("tag") != r["tag_name"]:
            print(f"warning: {r['tag_name']}: metadata is for {meta.get('tag')}, skipped", file=sys.stderr)
            continue
        # The DMG the feed points to must be the one that was signed: a
        # re-run replaces the DMG and its signature separately, and an
        # upload can fail halfway.
        dmg = next(a for a in r["assets"] if a["name"] == DMG_ASSET)
        if dmg.get("state", "uploaded") != "uploaded" or ("size" in dmg and int(dmg["size"]) != int(meta.get("length", -1))):
            print(f"warning: {r['tag_name']}: {DMG_ASSET} ({dmg.get('state')}, {dmg.get('size')} bytes) "
                  f"doesn't match its signature ({meta.get('length')} bytes), skipped", file=sys.stderr)
            continue
        chosen[channel] = (r, meta)
    return chosen


def item(release: dict, meta: dict, beta: bool) -> str:
    published = datetime.fromisoformat(release["published_at"].replace("Z", "+00:00"))
    url = f"https://github.com/ipsupport-llc/llmtray/releases/download/{release['tag_name']}/{DMG_ASSET}"
    channel = "\n      <sparkle:channel>beta</sparkle:channel>" if beta else ""
    return f"""    <item>
      <title>Version {escape(meta['shortVersion'])}</title>
      <pubDate>{format_datetime(published)}</pubDate>{channel}
      <sparkle:version>{escape(meta['sparkleVersion'])}</sparkle:version>
      <sparkle:shortVersionString>{escape(meta['shortVersion'])}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(meta.get('minimumSystemVersion', '13.0'))}</sparkle:minimumSystemVersion>
      <enclosure url="{url}"
                 sparkle:edSignature="{escape(meta['edSignature'])}" length="{int(meta['length'])}"
                 type="application/octet-stream"/>
    </item>
"""


def render(releases: list[dict], meta_dir: str | None = None) -> str:
    chosen = pick(releases, meta_dir)
    if "stable" not in chosen:
        raise SystemExit("error: no stable release with metadata -- refusing to publish an empty feed")
    items = [item(*chosen["stable"], beta=False)]
    beta = chosen.get("beta")
    if beta and version_key(beta[0]["tag_name"]) > version_key(chosen["stable"][0]["tag_name"]):
        items.append(item(*beta, beta=True))
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>LLMTray</title>
    <link>{FEED_URL}</link>
    <description>LLMTray release updates</description>
    <language>en</language>
{''.join(items)}  </channel>
</rss>
"""


def main() -> int:
    args = sys.argv[1:]
    meta_dir = None
    if "--meta-dir" in args:
        i = args.index("--meta-dir")
        meta_dir = args[i + 1]
        del args[i:i + 2]
    if len(args) != 2:
        print(__doc__)
        return 2
    Path(args[1]).write_text(render(load_releases(args[0]), meta_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
