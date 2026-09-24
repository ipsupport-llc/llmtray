#!/usr/bin/env bash
# Assembles LLMTray.app from the swift build output -- a bare SPM binary
# has no bundle, so nothing shows up in Spotlight/Launchpad, and macOS
# treats it as an anonymous unix process rather than "LLMTray." This
# packages it properly: a signed-ready .app with an Info.plist, icon, the
# embedded Sparkle.framework (for auto-updates), and the runtime/ scripts
# bundled inside Resources (RuntimePaths.swift checks there first before
# falling back to the dev-checkout-relative path).
#
# Usage: ./scripts/build_app.sh [--install]
#   --install copies the result into /Applications (overwriting any
#   existing LLMTray.app there).
#
# VERSION env var (e.g. "0.2.0", no leading "v") stamps
# CFBundleShortVersionString/CFBundleVersion -- release.yml sets this from
# the pushed tag. Without it, Sparkle would compare every running copy
# against the same hardcoded Info.plist version forever and never detect
# an update. Defaults to "0.0.0-dev" for plain local builds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$REPO_ROOT/.build/app"
APP="$BUILD_DIR/LLMTray.app"
VERSION="${VERSION:-0.0.0-dev}"

echo "--- building release binary (version $VERSION) ---"
cd "$REPO_ROOT"
swift build -c release

RELEASE_DIR="$REPO_ROOT/.build/release"
SPARKLE_FRAMEWORK="$(find "$REPO_ROOT/.build" -maxdepth 4 -iname "Sparkle.framework" -path "*/release/*" | head -1)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
  echo "error: could not locate built Sparkle.framework under .build/" >&2
  exit 1
fi

echo "--- assembling $APP ---"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime" "$APP/Contents/Frameworks"

cp "$RELEASE_DIR/LLMTray" "$APP/Contents/MacOS/LLMTray"
cp "$REPO_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$REPO_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Licenses.json (About LLMTray lists it) + THIRD_PARTY_NOTICES.txt, from
# the real license files of what's bundled (build_full_app.sh adds the
# vendored Python runtime).
python3 "$SCRIPT_DIR/generate_licenses.py" base "$REPO_ROOT" "$APP/Contents/Resources"
# Localizations: every Resources/Localization/<lang>.lproj is copied into the
# bundle and listed in CFBundleLocalizations -- adding a language is just
# adding a folder (see scripts/l10n.py). Keys are the English text, so a
# string a language hasn't translated shows in English.
LANGS=()
for lproj in "$REPO_ROOT"/Resources/Localization/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
  LANGS+=("$(basename "$lproj" .lproj)")
done
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
# Only the scripts + version pin -- never the venv itself, which is
# machine-specific and gets created fresh on first run.
cp "$REPO_ROOT/runtime/run_server.sh" \
   "$REPO_ROOT/runtime/mlx_lm_runtime.json" \
   "$REPO_ROOT/runtime/llmtray_mflux_runner.py" \
   "$APP/Contents/Resources/runtime/"

/usr/libexec/PlistBuddy -c "Delete :CFBundleLocalizations" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" "$APP/Contents/Info.plist"
for lang in "${LANGS[@]}"; do
  /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations: string $lang" "$APP/Contents/Info.plist"
done
/usr/libexec/PlistBuddy -c "Set :CFBundleDevelopmentRegion en" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
# CFBundleVersion is what Sparkle compares: see sparkle_version.sh for why
# a beta can't just reuse "X.Y.Z-beta.N" there.
BUNDLE_VERSION="$("$SCRIPT_DIR/sparkle_version.sh" "$VERSION")"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_VERSION" "$APP/Contents/Info.plist"

# The binary already carries an `@rpath/Sparkle.framework/...` load command
# (SPM linked against it), but SPM doesn't add the standard app-bundle
# rpath the way Xcode's "Embed Frameworks" build phase would -- without
# this, the executable can't actually find the framework we just copied
# into Contents/Frameworks at launch.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/LLMTray"

# Ad-hoc signing (no Developer ID here) -- enough for local use and for
# Gatekeeper's "right-click Open" bypass; a real release build needs a
# Developer ID cert + notarization on top of this. --deep resigns the
# embedded framework and its nested XPC services too, not just the outer
# app.
codesign --force --deep --sign - "$APP"

echo "--- built $APP ($VERSION) ---"

if [[ "${1:-}" == "--install" ]]; then
  echo "--- installing to /Applications ---"
  rm -rf "/Applications/LLMTray.app"
  cp -R "$APP" "/Applications/LLMTray.app"
  echo "--- installed to /Applications/LLMTray.app ---"
fi
