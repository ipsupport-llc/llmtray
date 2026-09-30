#!/usr/bin/env bash
# The Mac App Store build (adr/0018): the APP_STORE flavor (no Sparkle), the
# python.org framework and one folder of packages inside the bundle (no
# venv, nothing installed after install), signed with the sandbox's
# entitlements.
#
#   ./scripts/build_appstore.sh
#
# Output: .build/appstore/LLMTray.app, plus .build/appstore/LLMTray.pkg when
# INSTALLER_IDENTITY is set.
#
# Environment:
#   VERSION               X.Y.Z (default 0.0.0-dev)
#   SIGN_IDENTITY         "Apple Distribution: IPSupport LLC (PP59UU9DSQ)" for
#                         the App Store; a Developer ID identity runs it
#                         sandboxed locally; unset: ad-hoc
#   PROVISIONING_PROFILE  the Mac App Store profile (.provisionprofile),
#                         embedded; its app identifier and team go into the
#                         entitlements
#   INSTALLER_IDENTITY    "3rd Party Mac Developer Installer: ..." (Mac
#                         Installer Distribution): builds the signed .pkg to
#                         upload
#   BUNDLE_ID             another bundle id (a local test beside an installed
#                         LLMTray, which the app would otherwise hand over to)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APP="$REPO_ROOT/.build/appstore/LLMTray.app"
ENTITLEMENTS="$REPO_ROOT/.build/appstore/app.entitlements"

# 1. The app, the App Store flavor (signed at the end, once).
SIGN_IDENTITY= LLMTRAY_APP_STORE=1 "$SCRIPT_DIR/build_app.sh"

if [[ -n "${BUNDLE_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
fi

# 2. The sandbox entitlements, plus the profile's identity when there is one.
cp "$SCRIPT_DIR/appstore/app.entitlements" "$ENTITLEMENTS"
if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
  cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  PROFILE_PLIST="$(mktemp)"
  security cms -D -i "$PROVISIONING_PROFILE" > "$PROFILE_PLIST"
  APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$PROFILE_PLIST")"
  TEAM="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "$PROFILE_PLIST")"
  rm -f "$PROFILE_PLIST"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $APP_IDENTIFIER" "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENTITLEMENTS"
fi

# 3. The runtime inside the bundle, then everything signed inside-out: the
#    app with the sandbox's entitlements, the Python executables with only
#    app-sandbox + inherit (scripts/appstore/runner.entitlements).
APP_BUNDLE="$APP" RUNTIME_LAYOUT=packages \
  APP_ENTITLEMENTS="$ENTITLEMENTS" PYTHON_ENTITLEMENTS="$SCRIPT_DIR/appstore/runner.entitlements" \
  "$SCRIPT_DIR/build_full_app.sh"

# 4. The installer package App Store Connect takes.
if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
  productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$REPO_ROOT/.build/appstore/LLMTray.pkg"
  echo "--- built $REPO_ROOT/.build/appstore/LLMTray.pkg ---"
fi
echo "--- App Store build: $APP ---"
