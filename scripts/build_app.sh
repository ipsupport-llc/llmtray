#!/usr/bin/env bash
# Assembles LLMTray.app from the swift build output -- a bare SPM binary
# has no bundle, so nothing shows up in Spotlight/Launchpad, and macOS
# treats it as an anonymous unix process rather than "LLMTray." This
# packages it properly: a signed-ready .app with an Info.plist, icon, and
# the runtime/ scripts bundled inside Resources (RuntimePaths.swift checks
# there first before falling back to the dev-checkout-relative path).
#
# Usage: ./scripts/build_app.sh [--install]
#   --install copies the result into /Applications (overwriting any
#   existing LLMTray.app there).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$REPO_ROOT/.build/app"
APP="$BUILD_DIR/LLMTray.app"

echo "--- building release binary ---"
cd "$REPO_ROOT"
swift build -c release

echo "--- assembling $APP ---"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime"

cp "$REPO_ROOT/.build/release/LLMTray" "$APP/Contents/MacOS/LLMTray"
cp "$REPO_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$REPO_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Only the scripts + version pin -- never the venv itself, which is
# machine-specific and gets created fresh on first run.
cp "$REPO_ROOT/runtime/run_server.sh" \
   "$REPO_ROOT/runtime/mlx_lm_runtime.json" \
   "$REPO_ROOT/runtime/patch_mlx_server_kv.py" \
   "$REPO_ROOT/runtime/patch_mlx_tool_parser.py" \
   "$APP/Contents/Resources/runtime/"

# Ad-hoc signing (no Developer ID here) -- enough for local use and for
# Gatekeeper's "right-click Open" bypass; a real release build needs a
# Developer ID cert + notarization on top of this.
codesign --force --deep --sign - "$APP"

echo "--- built $APP ---"

if [[ "${1:-}" == "--install" ]]; then
  echo "--- installing to /Applications ---"
  rm -rf "/Applications/LLMTray.app"
  cp -R "$APP" "/Applications/LLMTray.app"
  echo "--- installed to /Applications/LLMTray.app ---"
fi
