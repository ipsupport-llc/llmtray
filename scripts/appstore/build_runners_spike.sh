#!/usr/bin/env bash
# adr/0018: a sandboxed test app with the App Store build's Python, packages
# and runners (build_appstore.sh first), which runs the image, music and
# voice runners inside the sandbox on the standalone LLMTray's downloaded
# models. Results go to stdout.
#
# Usage: SIGN_IDENTITY="Developer ID Application: ..." ./scripts/appstore/build_runners_spike.sh
#        open -W -n --stdout /tmp/runners.txt --stderr /tmp/runners.err .build/spike/RunnersSpike.app
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$ROOT/.build/appstore/LLMTray.app/Contents"
A="$ROOT/.build/spike/RunnersSpike.app"
: "${SIGN_IDENTITY:?SIGN_IDENTITY required (a Developer ID Application identity)}"
[[ -d "$SRC/Resources/python-packages" ]] || { echo "error: no App Store build at $SRC -- run build_appstore.sh" >&2; exit 1; }

rm -rf "$A"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Frameworks" "$A/Contents/Resources"
swiftc -O "$HERE/runners_spike.swift" -o "$A/Contents/MacOS/RunnersSpike"
ditto "$SRC/Frameworks/Python.framework" "$A/Contents/Frameworks/Python.framework"
ditto "$SRC/Resources/python-packages" "$A/Contents/Resources/python-packages"
ditto "$SRC/Resources/runtime" "$A/Contents/Resources/runtime"
cp "$HERE/runners_spike_harness.py" "$A/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string us.ipsupport.llmtray.runners-spike" \
  -c "Add :CFBundleExecutable string RunnersSpike" -c "Add :CFBundlePackageType string APPL" \
  -c "Add :CFBundleShortVersionString string 0.1" -c "Add :CFBundleVersion string 1" \
  -c "Add :LSMinimumSystemVersion string 14.0" -c "Add :NSPrincipalClass string NSApplication" "$A/Contents/Info.plist" >/dev/null

# The app's entitlements plus a read-only exception for the standalone
# LLMTray's models (this test app only; the App Store build has none).
ENT="$ROOT/.build/spike/runners.entitlements"
cp "$HERE/app.entitlements" "$ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.files.home-relative-path.read-only array" \
  -c "Add :com.apple.security.temporary-exception.files.home-relative-path.read-only:0 string /Library/Application Support/LLMTray/" "$ENT"

O=(--force --options runtime --timestamp=none --sign "$SIGN_IDENTITY")
while IFS= read -r -d '' f; do
  [[ -L "$f" || "$f" == */MacOS/RunnersSpike ]] && continue
  file -b "$f" | grep -q Mach-O || continue
  if [[ "$f" == */Python.framework/Versions/*/bin/python* || "$f" == */Python.app/Contents/MacOS/Python ]]; then
    codesign "${O[@]}" --entitlements "$HERE/runner.entitlements" "$f"
  else
    codesign "${O[@]}" "$f"
  fi
done < <(find "$A/Contents" -type f \( -perm -u+x -o -name "*.so" -o -name "*.dylib" \) -print0)
while IFS= read -r -d '' b; do codesign "${O[@]}" "$b"; done < <(find "$A/Contents/Frameworks" -depth -type d \( -name "*.app" -o -name "*.framework" \) -print0)
codesign "${O[@]}" --entitlements "$ENT" "$A"
codesign --verify --deep --strict "$A"
echo "--- $A ---"
