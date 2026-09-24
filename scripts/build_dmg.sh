#!/usr/bin/env bash
# Packages LLMTray.app into a standard drag-to-Applications .dmg -- the
# familiar macOS install experience instead of "unzip and figure out where
# to put it."
#
# Usage: ./scripts/build_dmg.sh [output-name.dmg]
# Requires scripts/build_app.sh to have already produced .build/app/LLMTray.app.
# output-name defaults to LLMTray.dmg -- the "Full" variant (build_app.sh
# then build_full_app.sh, both against the same .build/app/LLMTray.app)
# passes a different name so the two don't collide when built in the same job.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APP="$REPO_ROOT/.build/app/LLMTray.app"
STAGING="$REPO_ROOT/.build/dmg-staging"
DMG="$REPO_ROOT/.build/app/${1:-LLMTray.dmg}"

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
# hdiutil intermittently fails with "Resource busy" on CI runners (a
# disk image service still holding the previous volume) -- retry a few
# times before failing the release.
for attempt in 1 2 3 4; do
  if hdiutil create -volname "LLMTray" -srcfolder "$STAGING" -ov -format UDZO "$DMG"; then
    break
  fi
  if [ "$attempt" = 4 ]; then
    echo "hdiutil create failed after $attempt attempts" >&2
    exit 1
  fi
  echo "hdiutil create failed (attempt $attempt), retrying in $((attempt * 10))s"
  sleep $((attempt * 10))
done

rm -rf "$STAGING"
echo "--- built $DMG ---"
