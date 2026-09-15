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
SIGN_UPDATE="$(find "$REPO_ROOT/.build/artifacts" -iname "sign_update" | head -1)"

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

cat > "$REPO_ROOT/docs/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>LLMTray</title>
    <link>https://ipsupport-llc.github.io/llmtray/appcast.xml</link>
    <description>LLMTray release updates</description>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/ipsupport-llc/llmtray/releases/latest/download/LLMTray.dmg"
                 $SIGNATURE_ATTRS
                 type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF

echo "--- wrote docs/appcast.xml ---"
cat "$REPO_ROOT/docs/appcast.xml"
