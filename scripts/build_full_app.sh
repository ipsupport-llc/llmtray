#!/usr/bin/env bash
# Builds the "Full" LLMTray variant: same .app as build_app.sh, but with
# the mlx-lm runtime already installed inside the bundle instead of left
# for first-run bootstrap. For anyone who'd rather not (or can't) let the
# app install Python packages on first launch, or who has no compatible
# Python on the machine at all (see ServerManager.findModernPython3's doc
# comment for why that's a real failure mode on a clean Mac).
#
# Only ever uses python.org's own official installers -- not a
# third-party redistribution -- auto-detecting the latest published 3.x
# release from the official FTP index so this doesn't need manual
# version bumps as new Python releases ship.
#
# Usage: VERSION=0.2.0 ./scripts/build_full_app.sh
# Must run after build_app.sh has already produced .build/app/LLMTray.app
# (this script assumes the base app -- icon, Info.plist, Sparkle.framework,
# runtime scripts -- is already assembled and just adds the vendored
# runtime on top).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APP="$REPO_ROOT/.build/app/LLMTray.app"
WORK_DIR="$REPO_ROOT/.build/full_runtime_work"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found -- run scripts/build_app.sh first" >&2
  exit 1
fi

# Pinned in runtime/python_runtime.json rather than "newest on python.org":
# a new CPython minor usually ships before MLX publishes wheels for it, so
# following python.org automatically would fail the first release after
# every CPython release (and Thin + Full are built in one job, so the whole
# release). PY_VERSION in the environment overrides the pin (for trying a
# bump). Checked with a real GET: python.org rate-limits rapid --head loops.
PY_VERSION="${PY_VERSION:-$(python3 -c "import json; print(json.load(open('$REPO_ROOT/runtime/python_runtime.json'))['version'])")}"
PKG_URL="https://www.python.org/ftp/python/$PY_VERSION/python-$PY_VERSION-macos11.pkg"
status="$(curl -s -o /dev/null -w '%{http_code}' "$PKG_URL")"
if [[ "$status" != "200" ]]; then
  echo "error: pinned Python $PY_VERSION has no macOS installer at $PKG_URL (HTTP $status)" >&2
  exit 1
fi
echo "--- using official Python $PY_VERSION ($PKG_URL) ---"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
curl -fsSL -o "$WORK_DIR/python.pkg" "$PKG_URL"

echo "--- expanding installer package (no install, no postinstall scripts) ---"
pkgutil --expand-full "$WORK_DIR/python.pkg" "$WORK_DIR/expanded"

# The installer is a distribution package containing several component
# .pkgs; the framework's own files live directly under
# Python_Framework.pkg/Payload (that Payload *is* the Python.framework
# root -- there's no literal directory named "Python.framework" inside
# the expanded package to search for).
FRAMEWORK_PAYLOAD="$WORK_DIR/expanded/Python_Framework.pkg/Payload"
if [[ ! -d "$FRAMEWORK_PAYLOAD/Versions" ]]; then
  echo "error: expected Python_Framework.pkg/Payload/Versions not found -- installer package layout may have changed" >&2
  exit 1
fi

echo "--- copying Python.framework into the app bundle ---"
mkdir -p "$APP/Contents/Frameworks"
rm -rf "$APP/Contents/Frameworks/Python.framework"
cp -R "$FRAMEWORK_PAYLOAD" "$APP/Contents/Frameworks/Python.framework"

# Computed directly from $PY_VERSION (e.g. "3.14.7" -> "3.14") rather than
# `find`-ing it inside the just-copied tree -- a `find` right after a large
# `cp -R` was intermittently coming up empty even though the file was
# there moments later (never pinned down why; APFS metadata/xattr
# settling after copying pkgutil-extracted files was the leading theory),
# and python.org's framework layout ("Versions/<major.minor>/bin/python<major.minor>")
# is stable enough to rely on directly.
PY_SHORT_VERSION="$(echo "$PY_VERSION" | cut -d. -f1,2)"
FRAMEWORK_PYTHON="$APP/Contents/Frameworks/Python.framework/Versions/$PY_SHORT_VERSION/bin/python$PY_SHORT_VERSION"
if [[ ! -x "$FRAMEWORK_PYTHON" ]]; then
  echo "error: expected python at $FRAMEWORK_PYTHON but it's not there (or not executable) -- installer package layout may have changed" >&2
  exit 1
fi
echo "--- framework python: $FRAMEWORK_PYTHON ---"

# Make the framework relocatable: rewrite every absolute
# /Library/Frameworks/Python.framework reference under it (found with
# otool -- incl. _ssl/_hashlib and libssl/libcrypto) to @loader_path, not
# @executable_path (python re-execs into the Python.app stub). Why, and what
# broke without each part: adr/0001-mlx-runtime.md.
FRAMEWORK_ROOT="$APP/Contents/Frameworks/Python.framework"
VERSIONS_ROOT="$FRAMEWORK_ROOT/Versions/$PY_SHORT_VERSION"
FRAMEWORK_PREFIX="/Library/Frameworks/Python.framework/Versions/$PY_SHORT_VERSION/"

echo "--- rewriting absolute framework references for relocatability ---"
while IFS= read -r -d '' bin; do
  file "$bin" 2>/dev/null | grep -q "Mach-O" || continue
  # `|| true` on the whole pipeline: under pipefail, grep finding zero
  # matches (the common case -- most files reference nothing absolute)
  # exits 1, and that would otherwise trip `set -e` right here even though
  # this assignment is exactly what's supposed to handle "no matches".
  refs="$(otool -L "$bin" 2>/dev/null | awk '{print $1}' | grep -F "$FRAMEWORK_PREFIX" | sort -u || true)"
  [[ -z "$refs" ]] && continue

  rel="${bin#$VERSIONS_ROOT/}"
  rel_dir="$(dirname "$rel")"
  # Pure-bash component count (no grep/wc pipeline) -- same pipefail trap
  # as above bit us here too when this was written as $(grep -o ... | wc -l).
  depth=1
  tmp="$rel_dir"
  while [[ "$rel_dir" != "." && "$tmp" == */* ]]; do
    depth=$((depth + 1))
    tmp="${tmp%/*}"
  done
  up=""
  for ((i = 0; i < depth; i++)); do up="../$up"; done

  echo "  fixing $rel (depth $depth)"
  while IFS= read -r old_ref; do
    suffix="${old_ref#$FRAMEWORK_PREFIX}"
    install_name_tool -change "$old_ref" "@loader_path/${up}${suffix}" "$bin"
  done <<< "$refs"
  # install_name_tool invalidates whatever signature python.org shipped
  # on this binary -- macOS then refuses to run it at all (a bare
  # SIGKILL, no useful error) until it's re-signed. codesign --deep on
  # the whole app at the very end re-signs everything again anyway, but
  # each binary needs to be individually valid *now*, since one of them
  # (bin/python3.X) is what's about to be used to create the venv below.
  codesign --force --sign - "$bin"
done < <(find "$FRAMEWORK_ROOT" -type f -perm -u+x -print0)

VENV_DIR="$APP/Contents/Resources/runtime/.mlx_server_venv"
echo "--- creating vendored venv at $VENV_DIR ---"
rm -rf "$VENV_DIR"
"$FRAMEWORK_PYTHON" -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --quiet --upgrade pip

PINNED_REPO="$(python3 -c "import json; print(json.load(open('$REPO_ROOT/runtime/mlx_lm_runtime.json'))['repo'])")"
PINNED_REF="$(python3 -c "import json; print(json.load(open('$REPO_ROOT/runtime/mlx_lm_runtime.json'))['pinned_ref'])")"
echo "--- installing $PINNED_REPO@$PINNED_REF into the vendored venv ---"
"$VENV_DIR/bin/pip" install --quiet "git+https://github.com/$PINNED_REPO.git@$PINNED_REF"

# Everything redistributed in this bundle keeps its notices: CPython's
# license (with the summary of changes PSF §3 asks for) and every package
# in the venv, with its license files. Never vendor the image-generation
# venv (mflux_venv) this way: its opencv-python bundles GPL codecs.
echo "--- writing third-party notices for the vendored runtime ---"
# The framework's own libraries: python.org's license page (OpenSSL, expat,
# libffi, zlib, libmpdec, mimalloc, ...) from the installer's docs, Tcl/Tk
# from their frameworks, and libzstd / ncurses (dylibs the page doesn't
# cover) from scripts/licenses.
DOC_LICENSE="$WORK_DIR/expanded/Python_Documentation.pkg/Payload/license.html"
[[ -f "$DOC_LICENSE" ]] || { echo "error: $DOC_LICENSE not found -- installer layout changed?" >&2; exit 1; }
textutil -convert txt -output "$WORK_DIR/python-bundled-licenses.txt" "$DOC_LICENSE"
FRAMEWORK_EXTRAS=("$WORK_DIR/python-bundled-licenses.txt")
while IFS= read -r -d '' terms; do FRAMEWORK_EXTRAS+=("$terms"); done < <(find "$VERSIONS_ROOT/Frameworks" -name license.terms -print0 2>/dev/null)
FRAMEWORK_EXTRAS+=("$SCRIPT_DIR/licenses/zstd-LICENSE.txt" "$SCRIPT_DIR/licenses/ncurses-COPYING.txt")
"$VENV_DIR/bin/python" "$SCRIPT_DIR/generate_licenses.py" runtime "$APP/Contents/Resources" "$FRAMEWORK_ROOT" "$REPO_ROOT/LICENSE" "${FRAMEWORK_EXTRAS[@]}"

echo "--- re-signing app bundle with the added framework + venv ---"
codesign --force --deep --sign - "$APP"

rm -rf "$WORK_DIR"
echo "--- full runtime vendored into $APP ---"
