#!/usr/bin/env bash
# Signs the thin DMG for Sparkle and writes the release's feed metadata,
# .build/app/LLMTray.dmg.sparkle.json -- uploaded next to the DMGs. The
# feed itself (appcast.xml) is never committed: the Pages workflow builds
# it from every release's metadata (scripts/render_appcast.py).
#
# Usage: VERSION=0.6.9-beta.7 TAG=v0.6.9-beta.7 SPARKLE_PRIVATE_KEY=... ./scripts/sign_release.sh
# SPARKLE_PRIVATE_KEY: the base64 EdDSA private key; piped to sign_update,
#   never written to disk. SIGN_UPDATE overrides the tool (CI dry runs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
DMG="$REPO_ROOT/.build/app/LLMTray.dmg"
OUT="$DMG.sparkle.json"
SIGN_UPDATE="${SIGN_UPDATE:-$(find "$REPO_ROOT/.build/artifacts" -iname "sign_update" | head -1)}"

: "${VERSION:?VERSION env var required}"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY env var required}"
TAG="${TAG:-v$VERSION}"
[[ -f "$DMG" ]] || { echo "error: $DMG not found -- run build_dmg.sh first" >&2; exit 1; }
[[ -n "$SIGN_UPDATE" ]] || { echo "error: Sparkle's sign_update not found under .build/artifacts" >&2; exit 1; }

# Prints: sparkle:edSignature="..." length="..."
ATTRS="$(printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$DMG")"
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$ATTRS")"
LENGTH="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$ATTRS")"
[[ -n "$SIGNATURE" && -n "$LENGTH" ]] || { echo "error: unexpected sign_update output: $ATTRS" >&2; exit 1; }
SPARKLE_VERSION="$("$SCRIPT_DIR/sparkle_version.sh" "$VERSION")"
if [[ "$VERSION" == *-* ]]; then CHANNEL=beta; else CHANNEL=stable; fi

# The feed's minimum is the app's own (an older macOS must not be offered
# an update that won't launch there).
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$(dirname "$0")/../Resources/Info.plist")"

TAG="$TAG" VERSION="$VERSION" SPARKLE_VERSION="$SPARKLE_VERSION" CHANNEL="$CHANNEL" MIN_SYSTEM="$MIN_SYSTEM" \
SIGNATURE="$SIGNATURE" LENGTH="$LENGTH" SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)" OUT="$OUT" \
python3 - <<'PY'
import json, os
e = os.environ
json.dump({
    "schema": 1,
    "tag": e["TAG"],
    "shortVersion": e["VERSION"],
    "sparkleVersion": e["SPARKLE_VERSION"],
    "channel": e["CHANNEL"],
    "minimumSystemVersion": e["MIN_SYSTEM"],
    "asset": "LLMTray.dmg",
    "length": int(e["LENGTH"]),
    "sha256": e["SHA256"],
    "edSignature": e["SIGNATURE"],
}, open(e["OUT"], "w"), indent=2)
PY
echo "--- wrote $OUT ($CHANNEL $SPARKLE_VERSION) ---"
