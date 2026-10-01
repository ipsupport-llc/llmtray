#!/usr/bin/env bash
# The Mac App Store build (adr/0018): the APP_STORE flavor (no Sparkle, its
# own bundle id us.ipsupport.llmtray.appstore), the python.org framework and
# one folder of packages inside the bundle (no venv, nothing installed after
# install), signed with the sandbox's entitlements. It never uploads
# anything: App Store Connect / TestFlight only by hand, on the
# maintainer's say-so.
#
#   APPSTORE_PROFILE=~/Downloads/LLMTray_App_Store.provisionprofile \
#   SIGN_IDENTITY="Apple Distribution: IPSupport LLC (PP59UU9DSQ)" \
#   INSTALLER_IDENTITY="3rd Party Mac Developer Installer: IPSupport LLC (PP59UU9DSQ)" \
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
#   APPSTORE_PROFILE      the Mac App Store provisioning profile
#                         (.provisionprofile) for the bundle id, downloaded
#                         from the developer account (Profiles); embedded, and
#                         its app identifier and team go into the
#                         entitlements. Required with an App Store identity
#                         (Apple Distribution / 3rd Party Mac Developer
#                         Application) or INSTALLER_IDENTITY; optional for a
#                         local sandboxed run. PROVISIONING_PROFILE, its old
#                         name, still works.
#   INSTALLER_IDENTITY    "3rd Party Mac Developer Installer: ..." (Mac
#                         Installer Distribution): builds the signed .pkg
#   BUNDLE_ID             another bundle id than us.ipsupport.llmtray.appstore
#                         (a local test copy; the profile must be for it)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APP="$REPO_ROOT/.build/appstore/LLMTray.app"
ENTITLEMENTS="$REPO_ROOT/.build/appstore/app.entitlements"
# build_app.sh writes the same default (AppIdentity.appStoreBundleID).
BUNDLE_ID="${BUNDLE_ID:-us.ipsupport.llmtray.appstore}"
PROFILE="${APPSTORE_PROFILE:-${PROVISIONING_PROFILE:-}}"

fail() { echo "error: $*" >&2; exit 1; }

# 0. The profile, checked before a long build: there, readable, and for
#    this bundle id (one for us.ipsupport.llmtray, the standalone's, would
#    be accepted by codesign and refused only by App Store Connect).
case "${SIGN_IDENTITY:-}" in
  "Apple Distribution:"* | "3rd Party Mac Developer Application:"*) STORE_SIGNED=1 ;;
  *) STORE_SIGNED= ;;
esac
if [[ -z "$PROFILE" ]]; then
  if [[ -n "$STORE_SIGNED" || -n "${INSTALLER_IDENTITY:-}" ]]; then
    fail "APPSTORE_PROFILE isn't set: an App Store signature needs the Mac App Store provisioning profile for $BUNDLE_ID (developer account > Profiles; download it and pass its path)"
  fi
  echo "--- no APPSTORE_PROFILE: a local build, not for App Store Connect ---"
else
  [[ -f "$PROFILE" ]] || fail "APPSTORE_PROFILE=$PROFILE: no such file"
  PROFILE_PLIST="$(mktemp)"
  trap 'rm -f "$PROFILE_PLIST"' EXIT
  security cms -D -i "$PROFILE" > "$PROFILE_PLIST" 2>/dev/null \
    || fail "APPSTORE_PROFILE=$PROFILE: not a provisioning profile (security cms can't decode it)"
  APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$PROFILE_PLIST" 2>/dev/null)" \
    || fail "APPSTORE_PROFILE=$PROFILE: no application identifier in it (a Mac App Store profile has one)"
  TEAM="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "$PROFILE_PLIST")"
  [[ "$APP_IDENTIFIER" == "$TEAM.$BUNDLE_ID" ]] \
    || fail "APPSTORE_PROFILE=$PROFILE is for $APP_IDENTIFIER, not $TEAM.$BUNDLE_ID"
fi

# 1. The app, the App Store flavor (signed at the end, once).
SIGN_IDENTITY= LLMTRAY_APP_STORE=1 "$SCRIPT_DIR/build_app.sh"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"

# 2. The sandbox entitlements, plus the profile's identity when there is one.
cp "$SCRIPT_DIR/appstore/app.entitlements" "$ENTITLEMENTS"
if [[ -n "$PROFILE" ]]; then
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $APP_IDENTIFIER" "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENTITLEMENTS"
fi

# 3. The runtime inside the bundle, then everything signed inside-out: the
#    app with the sandbox's entitlements, the Python executables with only
#    app-sandbox + inherit (scripts/appstore/runner.entitlements).
APP_BUNDLE="$APP" RUNTIME_LAYOUT=packages \
  APP_ENTITLEMENTS="$ENTITLEMENTS" PYTHON_ENTITLEMENTS="$SCRIPT_DIR/appstore/runner.entitlements" \
  "$SCRIPT_DIR/build_full_app.sh"

# 4. The installer package for App Store Connect (built, never uploaded here).
if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
  productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$REPO_ROOT/.build/appstore/LLMTray.pkg"
  echo "--- built $REPO_ROOT/.build/appstore/LLMTray.pkg ---"
fi
echo "--- App Store build: $APP ($BUNDLE_ID) ---"
