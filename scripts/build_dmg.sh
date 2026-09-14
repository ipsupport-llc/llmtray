#!/usr/bin/env bash
# Packages LLMTray.app into a standard drag-to-Applications .dmg -- the
# familiar macOS install experience instead of "unzip and figure out where
# to put it."
#
# Usage: ./scripts/build_dmg.sh
# Requires scripts/build_app.sh to have already produced .build/app/LLMTray.app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APP="$REPO_ROOT/.build/app/LLMTray.app"
STAGING="$REPO_ROOT/.build/dmg-staging"
DMG="$REPO_ROOT/.build/app/LLMTray.dmg"

if [[ ! -d "$APP" ]]; then
  echo "LLMTray.app not found at $APP -- run scripts/build_app.sh first" >&2
  exit 1
fi

echo "--- staging DMG contents ---"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "--- building $DMG ---"
hdiutil create -volname "LLMTray" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

rm -rf "$STAGING"
echo "--- built $DMG ---"
