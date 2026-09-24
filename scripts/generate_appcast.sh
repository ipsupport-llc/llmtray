#!/usr/bin/env bash
# Writes docs/appcast.xml -- the feed Sparkle polls (SUFeedURL in
# Info.plist) to decide whether a newer version exists. Deliberately a
# single hand-built <item>, not Sparkle's own generate_appcast tool: that
# tool wants a whole directory of *every* past release's archive to
# support delta updates and multi-version pruning, which would mean
# keeping every historical DMG around somewhere persistent. This app just
# needs "here's the newest version" -- Sparkle doesn't need history for
# that, only the latest item in the feed.
#
# Usage: VERSION=0.2.0 SPARKLE_PRIVATE_KEY="<key>" ./scripts/generate_appcast.sh
# VERSION: the version being released (no leading "v").
# SPARKLE_PRIVATE_KEY: the base64 EdDSA private key (same one generate_keys
#   produced), used only to sign this one DMG -- never written to disk.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
DMG="$REPO_ROOT/.build/app/LLMTray.dmg"
# Overridable for CI dry runs (a stub that prints fixed signature attrs).
SIGN_UPDATE="${SIGN_UPDATE:-$(find "$REPO_ROOT/.build/artifacts" -iname "sign_update" | head -1)}"

: "${VERSION:?VERSION env var required}"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY env var required}"

if [[ ! -f "$DMG" ]]; then
  echo "error: $DMG not found -- run build_dmg.sh first" >&2
  exit 1
fi
if [[ -z "$SIGN_UPDATE" ]]; then
  echo "error: could not locate Sparkle's sign_update tool under .build/artifacts" >&2
  exit 1
fi

echo "--- signing $DMG ---"
SIGNATURE_ATTRS="$(echo "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$DMG")"
echo "signature attrs: $SIGNATURE_ATTRS"

PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"

# Two channels, one item each: a version with a pre-release suffix
# (0.6.8-beta.1) is a beta. Its item carries <sparkle:channel>beta, which
# Sparkle only offers to apps that opt into that channel (see
# UpdateChannelDelegate); the stable item has no channel, so everyone gets
# it. Each release rewrites only its own channel's item and keeps the
# other, so a beta never replaces the stable entry (and vice versa).
# The enclosure points at this exact tag's asset, not releases/latest
# (which skips pre-releases, and could move to a newer file than the one
# this signature is for).
if [[ "$VERSION" == *-* ]]; then CHANNEL=beta; else CHANNEL=stable; fi
SPARKLE_VERSION="$("$SCRIPT_DIR/sparkle_version.sh" "$VERSION")"
TAG="${TAG:-v$VERSION}"
URL="https://github.com/ipsupport-llc/llmtray/releases/download/$TAG/LLMTray.dmg"

APPCAST="$REPO_ROOT/docs/appcast.xml" CHANNEL="$CHANNEL" VERSION="$VERSION" SPARKLE_VERSION="$SPARKLE_VERSION" PUB_DATE="$PUB_DATE" \
URL="$URL" SIGNATURE_ATTRS="$SIGNATURE_ATTRS" python3 - <<'PY'
import os, re
path, channel = os.environ["APPCAST"], os.environ["CHANNEL"]
old = open(path).read() if os.path.exists(path) else ""
items = re.findall(r"    <item>.*?</item>\n", old, re.S)
def is_beta(item): return "<sparkle:channel>beta</sparkle:channel>" in item
# Keep the other channel's item. An old beta left next to a newer stable
# is harmless: Sparkle offers the newest version the user is allowed, and
# a beta of an older version is never newer than stable.
kept = [i for i in items if is_beta(i) != (channel == "beta")]
v, sv, date, url, sig = (os.environ[k] for k in ("VERSION", "SPARKLE_VERSION", "PUB_DATE", "URL", "SIGNATURE_ATTRS"))
chan = "\n      <sparkle:channel>beta</sparkle:channel>" if channel == "beta" else ""
item = f"""    <item>
      <title>Version {v}</title>
      <pubDate>{date}</pubDate>{chan}
      <sparkle:version>{sv}</sparkle:version>
      <sparkle:shortVersionString>{v}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="{url}"
                 {sig}
                 type="application/octet-stream"/>
    </item>
"""
items = ([item] + kept) if channel == "stable" else (kept + [item])
open(path, "w").write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>LLMTray</title>
    <link>https://ipsupport-llc.github.io/llmtray/appcast.xml</link>
    <description>LLMTray release updates</description>
    <language>en</language>
{''.join(items)}  </channel>
</rss>
""")
PY

echo "--- wrote docs/appcast.xml ($CHANNEL channel) ---"
cat "$REPO_ROOT/docs/appcast.xml"
