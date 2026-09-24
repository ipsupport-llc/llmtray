#!/usr/bin/env python3
"""Offline checks for render_appcast.py (run by CI's release dry run)."""
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import render_appcast as ra  # noqa: E402


def release(tag, draft=False, dmg=True, published="2026-09-01T10:00:00Z"):
    assets = [{"name": ra.META_ASSET, "browser_download_url": "unused"}]
    if dmg:
        assets.append({"name": ra.DMG_ASSET, "browser_download_url": "unused"})
    return {"tag_name": tag, "draft": draft, "prerelease": "-" in tag, "published_at": published, "assets": assets}


def meta(tag, sparkle):
    return {"tag": tag, "shortVersion": tag[1:], "sparkleVersion": sparkle, "edSignature": f"sig-{tag}", "length": 123}


def run(releases, metas):
    with tempfile.TemporaryDirectory() as d:
        for m in metas:
            Path(d, f"{m['tag']}.json").write_text(json.dumps(m))
        return ra.render(releases, d)


def check(cond, what):
    if not cond:
        raise SystemExit(f"FAIL: {what}")


# Ordering: beta.10 > beta.9; a stable outranks its own betas.
assert ra.version_key("v0.6.9-beta.10") > ra.version_key("v0.6.9-beta.9")
assert ra.version_key("v0.6.9") > ra.version_key("v0.6.9-beta.10")
assert ra.version_key("v0.6.10-beta.1") > ra.version_key("v0.6.9")
assert ra.version_key("v1.0.0-rc1") is None

feed = run(
    # pages of `gh api --paginate --slurp` are flattened by load_releases;
    # render() takes the flat list.
    [release("v9.9.8"), release("v9.9.9-beta.1"), release("v9.9.9-beta.2"),
     release("v9.9.9-beta.3", draft=True), release("v9.9.9-rc1"), release("v9.9.9-beta.4", dmg=False)],
    [meta("v9.9.8", "9.9.8"), meta("v9.9.9-beta.1", "9.9.9b1"), meta("v9.9.9-beta.2", "9.9.9b2"),
     meta("v9.9.9-beta.3", "9.9.9b3"), meta("v9.9.9-beta.4", "9.9.9b4")],
)
check(feed.count("<item>") == 2, "one stable + one beta item")
check("<sparkle:version>9.9.8</sparkle:version>" in feed, "highest stable")
check("<sparkle:version>9.9.9b2</sparkle:version>" in feed, "highest published beta with a DMG (not draft/rc/assetless)")
check(feed.count("<sparkle:channel>beta</sparkle:channel>") == 1, "only the beta item has the channel")
check("releases/download/v9.9.9-beta.2/LLMTray.dmg" in feed, "enclosure points at the exact tag")

# A beta older than the stable is left out.
feed = run([release("v9.9.9"), release("v9.9.9-beta.2")], [meta("v9.9.9", "9.9.9"), meta("v9.9.9-beta.2", "9.9.9b2")])
check(feed.count("<item>") == 1, "stale beta dropped")

# A release whose metadata is missing falls back to the next one.
feed = run([release("v9.9.9"), release("v9.9.8")], [meta("v9.9.8", "9.9.8")])
check("<sparkle:version>9.9.8</sparkle:version>" in feed, "falls back when metadata is missing")

# Paginated input is flattened.
with tempfile.TemporaryDirectory() as d:
    p = Path(d, "r.json")
    p.write_text(json.dumps([[release("v1.0.0")], [release("v1.0.1")]]))
    check(len(ra.load_releases(str(p))) == 2, "pages flattened")

# No stable at all: refuse rather than publish an empty feed.
try:
    run([release("v9.9.9-beta.1")], [meta("v9.9.9-beta.1", "9.9.9b1")])
    raise SystemExit("FAIL: empty-stable feed was rendered")
except SystemExit as e:
    check("no stable release" in str(e), "refuses a feed without stable")

print("render_appcast: all checks passed")
