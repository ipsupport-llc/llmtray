#!/usr/bin/env bash
# Signs LLMTray.app. With SIGN_IDENTITY (a "Developer ID Application: ..."
# identity in the keychain): inside-out, every Mach-O file, then nested
# bundles (Sparkle's XPC services and Updater.app, frameworks), then the
# app -- hardened runtime and a secure timestamp throughout, as
# notarization requires. Without it: ad-hoc, as before (local builds, CI
# dry runs, forks without the certificate).
#
# Usage: SIGN_IDENTITY="Developer ID Application: IPSupport LLC (PP59UU9DSQ)" ./scripts/codesign_app.sh path/to/LLMTray.app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:?usage: codesign_app.sh path/to/LLMTray.app}"
IDENTITY="${SIGN_IDENTITY:-}"

if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP"
  echo "--- signed $APP ad-hoc (no SIGN_IDENTITY) ---"
  exit 0
fi

OPTS=(--force --timestamp --options runtime --sign "$IDENTITY")
PY_ENT="$SCRIPT_DIR/python.entitlements"

is_macho() { file -b "$1" | grep -q "Mach-O"; }

# 1. Loose Mach-O files, deepest paths first. Executables of the vendored
#    Python get its entitlements; the app's own executable is signed last.
count=0
while IFS= read -r -d '' f; do
  [[ -L "$f" ]] && continue
  [[ "$f" == "$APP/Contents/MacOS/LLMTray" ]] && continue
  is_macho "$f" || continue
  if [[ "$f" == *"/Python.framework/"*"/bin/"* || "$f" == *"/Python.app/Contents/MacOS/"* || "$f" == *"/.mlx_server_venv/bin/"* ]] \
     && [[ "$f" != *.so && "$f" != *.dylib ]]; then
    codesign "${OPTS[@]}" --entitlements "$PY_ENT" "$f"
  else
    codesign "${OPTS[@]}" "$f"
  fi
  count=$((count + 1))
done < <(find "$APP/Contents" -type f \( -perm -u+x -o -name "*.so" -o -name "*.dylib" \) -print0 | xargs -0 -n1 printf '%s\0' | sort -rz)
echo "--- signed $count Mach-O files ---"

# 2. Nested bundles, innermost first; Sparkle's XPC services keep their
#    own entitlements (the downloader's network client).
while IFS= read -r -d '' b; do
  [[ "$b" == "$APP" ]] && continue
  if [[ "$b" == *.xpc || "$b" == *.app ]]; then
    codesign "${OPTS[@]}" --preserve-metadata=entitlements "$b"
  else
    codesign "${OPTS[@]}" "$b"
  fi
done < <(find "$APP/Contents" -depth -type d \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" \) -print0)

# 3. The app.
codesign "${OPTS[@]}" --entitlements "$SCRIPT_DIR/LLMTray.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "--- signed $APP with $IDENTITY ---"
