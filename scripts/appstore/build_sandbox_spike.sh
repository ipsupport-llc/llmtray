#!/usr/bin/env bash
# adr/0018 step 1: a sandboxed test app running the Full build's vendored
# Python (app-sandbox + inherit only) -- GPU, a localhost port, HF_HOME in
# the container, and a model from a folder the user grants in an open
# panel. Needs a Full build (build_app.sh + build_full_app.sh) and a
# Developer ID identity; results go to stdout.
#
# Usage: SIGN_IDENTITY="Developer ID Application: ..." ./scripts/appstore/build_sandbox_spike.sh
#        open -W -n --stdout /tmp/spike.txt --stderr /tmp/spike.txt .build/spike/SandboxSpike.app
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FULL="$ROOT/.build/app/LLMTray.app/Contents"
A="$ROOT/.build/spike/SandboxSpike.app"
: "${SIGN_IDENTITY:?SIGN_IDENTITY required (a Developer ID Application identity)}"
[[ -d "$FULL/Frameworks/Python.framework" ]] || { echo "error: no Full build at $FULL -- run build_full_app.sh" >&2; exit 1; }
PYV="$(ls "$FULL/Frameworks/Python.framework/Versions" | grep -v Current | head -1)"

rm -rf "$A"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Frameworks" "$A/Contents/Resources"
swiftc -O "$HERE/sandbox_spike.swift" -o "$A/Contents/MacOS/SandboxSpike"
ditto "$FULL/Frameworks/Python.framework" "$A/Contents/Frameworks/Python.framework"
# No venv in the App Store build: the packages on PYTHONPATH.
ditto "$FULL/Resources/runtime/.mlx_server_venv/lib/python$PYV/site-packages" "$A/Contents/Resources/site-packages"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string us.ipsupport.llmtray.spike" \
  -c "Add :CFBundleExecutable string SandboxSpike" -c "Add :CFBundlePackageType string APPL" \
  -c "Add :CFBundleShortVersionString string 0.1" -c "Add :CFBundleVersion string 1" \
  -c "Add :LSMinimumSystemVersion string 14.0" -c "Add :NSPrincipalClass string NSApplication" "$A/Contents/Info.plist" >/dev/null

O=(--force --options runtime --timestamp=none --sign "$SIGN_IDENTITY")
while IFS= read -r -d '' f; do
  [[ -L "$f" || "$f" == */MacOS/SandboxSpike ]] && continue
  file -b "$f" | grep -q Mach-O || continue
  if [[ "$f" == */Python.framework/Versions/*/bin/python* || "$f" == */Python.app/Contents/MacOS/Python ]]; then
    codesign "${O[@]}" --entitlements "$HERE/runner.entitlements" "$f"
  else
    codesign "${O[@]}" "$f"
  fi
done < <(find "$A/Contents" -type f \( -perm -u+x -o -name "*.so" -o -name "*.dylib" \) -print0)
while IFS= read -r -d '' b; do codesign "${O[@]}" "$b"; done < <(find "$A/Contents/Frameworks" -depth -type d \( -name "*.app" -o -name "*.framework" \) -print0)
codesign "${O[@]}" --entitlements "$HERE/app.entitlements" "$A"
codesign --verify --deep --strict "$A"
echo "--- $A ---"
