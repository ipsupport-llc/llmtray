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

# python.org's installer assumes the framework lands at the standard
# system location and bakes that absolute path into affected binaries'
# link commands -- confirmed via otool on several: bin/python3.X, the
# Python.app launcher stub under Resources (which bin/python3.X re-execs
# into for some invocations), and -- less obviously -- the _ssl/_hashlib
# extension modules and libssl/libcrypto themselves, which reference each
# other via the same absolute .../Versions/X.Y/lib/libssl.3.dylib style
# path. Any of these missing means a dyld "Library not loaded" crash (for
# the ones actually exec'd) or a silently-disabled ssl module (pip's
# "ssl module in Python is not available" -- the failure mode that first
# exposed the lib* pair). So instead of special-casing "Python", every
# absolute reference anywhere under this framework version is discovered
# via otool and rewritten to an @loader_path-relative one (with the right
# number of "../" for that binary's own depth under Versions/X.Y),
# whatever file it happens to point at. Deliberately @loader_path, not
# @executable_path: the latter resolves against the process's *main*
# executable, and bin/python3.X actually re-execs into the bundled
# Resources/Python.app/Contents/MacOS/Python launcher for some
# invocations -- with @executable_path, a dlopen from deep inside (e.g.
# _ssl.so loading libssl) resolved relative to *that* launcher's
# location instead of its own, landing on a nonexistent path one
# directory off. @loader_path always resolves relative to the file doing
# the loading, regardless of which binary ends up as the process's entry
# point.
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

echo "--- re-signing app bundle with the added framework + venv ---"
codesign --force --deep --sign - "$APP"

rm -rf "$WORK_DIR"
echo "--- full runtime vendored into $APP ---"
