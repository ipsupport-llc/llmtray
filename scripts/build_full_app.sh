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
APP="${APP_BUNDLE:-$REPO_ROOT/.build/app/LLMTray.app}"
# venv (the Full build: copied out to Application Support at first launch)
# or packages (the App Store flavor, adr/0018: no venv, one folder of
# packages for every runner -- the server's mlx-lm fork and mlx-audio --
# run from the bundle with PYTHONPATH).
RUNTIME_LAYOUT="${RUNTIME_LAYOUT:-venv}"
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

PINNED_REPO="$(python3 -c "import json; print(json.load(open('$REPO_ROOT/runtime/mlx_lm_runtime.json'))['repo'])")"
PINNED_REF="$(python3 -c "import json; print(json.load(open('$REPO_ROOT/runtime/mlx_lm_runtime.json'))['pinned_ref'])")"

if [[ "$RUNTIME_LAYOUT" == packages ]]; then
  PKG_DIR="$APP/Contents/Resources/python-packages"
  # The audio runtime's pins, from AudioRuntime.swift (one place for them).
  AUDIO_COMMIT="$(sed -n 's/.*static let bundledCommit = "\([0-9a-f]\{40\}\)".*/\1/p' "$REPO_ROOT/Sources/LLMTray/AudioRuntime.swift")"
  [[ -n "$AUDIO_COMMIT" ]] || { echo "error: no mlx-audio commit in AudioRuntime.swift" >&2; exit 1; }
  echo "--- installing $PINNED_REPO@$PINNED_REF + mlx-audio@$AUDIO_COMMIT into $PKG_DIR ---"
  rm -rf "$PKG_DIR"
  # python.org's framework has no pip (its installer adds it afterwards),
  # and none goes into this bundle: a throwaway venv of the same
  # interpreter, outside the bundle, installs into it.
  BUILD_VENV="$WORK_DIR/pip_venv"
  "$FRAMEWORK_PYTHON" -m venv "$BUILD_VENV"
  # Image generation: mflux (PyPI, its version pinned) without its dependencies, then every
  # dependency but runtime/mflux_runtime.json's "exclude" (opencv-python's
  # GPL FFmpeg, torch) in the one resolution below (adr/0018 §4).
  MFLUX_JSON="$REPO_ROOT/runtime/mflux_runtime.json"
  mflux_config() { python3 -c 'import json, sys; v = json.load(open(sys.argv[1]))[sys.argv[2]]; print(" ".join(v) if isinstance(v, list) else v)' "$MFLUX_JSON" "$1"; }
  MFLUX_URL="mflux==$(mflux_config version)"
  MFLUX_DIR="$WORK_DIR/mflux_target"
  MFLUX_DEPS_FILE="$WORK_DIR/mflux_deps.txt"
  rm -rf "$MFLUX_DIR"
  "$BUILD_VENV/bin/python" -m pip install --quiet --disable-pip-version-check --no-compile --no-deps --target "$MFLUX_DIR" "$MFLUX_URL"
  # Its Requires-Dist for this Python and platform, less "exclude", plus
  # "extra". To a file first: a failure in here stops the build.
  "$BUILD_VENV/bin/python" - "$MFLUX_DIR" "$MFLUX_JSON" > "$MFLUX_DEPS_FILE" <<'PY'
import glob, json, sys
from email.parser import Parser
from pip._vendor.packaging.requirements import Requirement
from pip._vendor.packaging.utils import canonicalize_name
target, config = sys.argv[1], json.load(open(sys.argv[2]))
exclude = {canonicalize_name(n) for n in config["exclude"]}
meta = Parser().parse(open(glob.glob(f"{target}/mflux-*.dist-info/METADATA")[0]))
for line in meta.get_all("Requires-Dist") or []:
    req = Requirement(line)
    if req.marker and not req.marker.evaluate({"extra": ""}):
        continue
    if canonicalize_name(req.name) in exclude:
        continue
    req.marker = None
    print(req)
for extra in config["extra"]:
    print(extra)
PY
  [[ -s "$MFLUX_DEPS_FILE" ]] || { echo "error: no dependencies read from mflux's metadata" >&2; exit 1; }
  MFLUX_DEPS=()
  while IFS= read -r dep; do MFLUX_DEPS+=("$dep"); done < "$MFLUX_DEPS_FILE"
  "$BUILD_VENV/bin/python" -m pip install --quiet --disable-pip-version-check --no-compile --target "$PKG_DIR" \
    "mlx-lm @ https://github.com/$PINNED_REPO/archive/$PINNED_REF.zip" \
    "mlx-audio @ https://github.com/ipsupport-llc/mlx-audio/archive/$AUDIO_COMMIT.tar.gz" \
    "transformers==5.17.0" pyyaml huggingface_hub "sentencepiece>=0.2.0" "${MFLUX_DEPS[@]}"
  cp -R "$MFLUX_DIR"/mflux "$MFLUX_DIR"/mflux-*.dist-info "$PKG_DIR"/
  # pip's own console scripts (their shebangs name this machine's path).
  rm -rf "$PKG_DIR/bin"
  # Every runner exits with the app (the sandbox can't stop a leftover one).
  cp "$REPO_ROOT/runtime/appstore/sitecustomize.py" "$PKG_DIR/sitecustomize.py"
  PYTHONPATH="$PKG_DIR" "$FRAMEWORK_PYTHON" -c "import mlx_lm, mlx_audio, sys; print('packages ok', sys.version.split()[0])"
  # The image models LLMTray runs load without the excluded packages.
  PYTHONPATH="$PKG_DIR" "$FRAMEWORK_PYTHON" -c "import mflux.models.z_image.variants.z_image, mflux.models.flux2.variants.txt2img.flux2_klein, mflux.models.flux2.variants.edit.flux2_klein_edit; print('mflux ok')"
  # Nothing excluded came back through another package -- by content, not
  # by name: every opencv-python variant (-headless, -contrib) ships the
  # same cv2 with FFmpeg's GPL build.
  for module in cv2 torch; do
    [[ ! -e "$PKG_DIR/$module" ]] || { echo "error: $module is in $PKG_DIR (runtime/mflux_runtime.json keeps it out)" >&2; exit 1; }
  done
  GPL_HIT="$(find "$PKG_DIR" -type f \( -name "*.dylib" -o -name "*.so" \) \( -name "libx264*" -o -name "libx265*" -o -name "libavcodec*" -o -name "libpostproc*" \) | head -1)"
  [[ -z "$GPL_HIT" ]] || { echo "error: FFmpeg/x264/x265 in the App Store bundle: $GPL_HIT" >&2; exit 1; }
  LICENSE_PYTHON=(env PYTHONPATH="$PKG_DIR" "$FRAMEWORK_PYTHON")
else
  VENV_DIR="$APP/Contents/Resources/runtime/.mlx_server_venv"
  echo "--- creating vendored venv at $VENV_DIR ---"
  rm -rf "$VENV_DIR"
  "$FRAMEWORK_PYTHON" -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --quiet --upgrade pip

  echo "--- installing $PINNED_REPO@$PINNED_REF into the vendored venv ---"
  "$VENV_DIR/bin/pip" install --quiet "git+https://github.com/$PINNED_REPO.git@$PINNED_REF"

  # venv links bin/python3.X to the framework by absolute path -- this
  # machine's. Codesign can't seal a link out of the bundle; relative, it
  # stays inside it. (The app copies the venv out and re-points the link at
  # the copied framework anyway: MLXRuntimeInstaller.relinkVendoredInterpreter.)
  while IFS= read -r -d '' link; do
    target="$(readlink "$link")"
    [[ "$target" == /* && "$target" == "$APP"/* ]] || continue
    rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' "$target" "$link")"
    ln -sfn "$rel" "$link"
    echo "  relinked ${link#$APP/} -> $rel"
  done < <(find "$VENV_DIR" -type l -print0)
  LICENSE_PYTHON=("$VENV_DIR/bin/python")
fi

# Everything redistributed in this bundle keeps its notices: CPython's
# license (with the summary of changes PSF §3 asks for) and every package
# in the venv, with its license files. Never vendor the image-generation
# venv (mflux_venv) this way: its opencv-python bundles GPL codecs.
echo "--- writing third-party notices for the vendored runtime ---"
# The framework's own libraries: python.org's license page (OpenSSL, expat,
# libffi, zlib, libmpdec, mimalloc, ...) from the installer's docs, Tcl/Tk
# from their frameworks, and libzstd / ncurses (dylibs the page doesn't
# cover) from scripts/licenses.
# Tcl/Tk with tkinter and IDLE out, in both builds (before the license list,
# so it lists only what ships): LLMTray has no Tk UI. Their frameworks carry
# unsigned files (*Config.sh, stub .a, headers): App Store Connect refuses
# them (ITMS-90284), and a Developer ID signature of a well-formed
# Tk.framework fails on them ("code object is not signed at all").
LIB="$VERSIONS_ROOT/lib/python$PY_SHORT_VERSION"
rm -rf "$VERSIONS_ROOT/Frameworks/Tcl.framework" "$VERSIONS_ROOT/Frameworks/Tk.framework" \
  "$LIB/tkinter" "$LIB/idlelib" "$LIB/turtledemo" "$LIB/turtle.py"
rm -f "$LIB"/lib-dynload/_tkinter.*.so "$VERSIONS_ROOT"/bin/idle3*
rmdir "$VERSIONS_ROOT/Frameworks" 2>/dev/null || true
if [[ "$RUNTIME_LAYOUT" != packages ]]; then
  "$VENV_DIR/bin/python" -c "import mlx_lm; print('venv after Tcl/Tk strip ok')"
fi

# App Store: build-time files out too. Nothing runs pip inside this bundle,
# so nothing builds an extension against them; the Developer ID build keeps
# them (its venv's pip may). Object files and static libraries (python.o and
# libpython in config-X.Y-darwin, numpy's .a) can't be signed (ITMS-90284).
if [[ "$RUNTIME_LAYOUT" == packages ]]; then
  rm -rf "$LIB/config-$PY_SHORT_VERSION-darwin"
  find "$APP" \( -type f -o -type l \) \( -name "*.o" -o -name "*.a" \) -print -delete | sed "s|^$APP/|  removed |"
  LEFT="$(find "$APP" \( -name "*.o" -o -name "*.a" -o -name "*Config.sh" \) -print -quit)"
  [[ -z "$LEFT" ]] || { echo "error: a build-time file is still in the App Store bundle: $LEFT" >&2; exit 1; }
  # What ships still imports (the checks above ran before the strip).
  PYTHONPATH="$PKG_DIR" "$FRAMEWORK_PYTHON" -c "import mlx_lm, mlx_audio, mflux, numpy; print('stripped packages ok')"
fi

DOC_LICENSE="$WORK_DIR/expanded/Python_Documentation.pkg/Payload/license.html"
[[ -f "$DOC_LICENSE" ]] || { echo "error: $DOC_LICENSE not found -- installer layout changed?" >&2; exit 1; }
textutil -convert txt -output "$WORK_DIR/python-bundled-licenses.txt" "$DOC_LICENSE"
FRAMEWORK_EXTRAS=("$WORK_DIR/python-bundled-licenses.txt")
while IFS= read -r -d '' terms; do FRAMEWORK_EXTRAS+=("$terms"); done < <(find "$VERSIONS_ROOT/Frameworks" -name license.terms -print0 2>/dev/null)
FRAMEWORK_EXTRAS+=("$SCRIPT_DIR/licenses/zstd-LICENSE.txt" "$SCRIPT_DIR/licenses/ncurses-COPYING.txt")
"${LICENSE_PYTHON[@]}" "$SCRIPT_DIR/generate_licenses.py" runtime "$APP/Contents/Resources" "$FRAMEWORK_ROOT" "$REPO_ROOT/LICENSE" "${FRAMEWORK_EXTRAS[@]}"

# Links to nothing (python.org's Tcl/Tk PrivateHeaders, in both builds):
# App Store Connect refuses them (ITMS-90332), and xattr -r below fails on one.
find "$APP" -type l ! -exec test -e {} \; -print -delete | sed "s|^$APP/|  removed link |"

# No extended attributes: a quarantine flag (a provisioning profile or a
# python.org file downloaded in a browser) is refused by App Store Connect
# (ITMS-91109), and codesign wants none on what it signs.
xattr -cr "$APP"

echo "--- re-signing app bundle with the added framework + venv ---"
"$SCRIPT_DIR/codesign_app.sh" "$APP"

rm -rf "$WORK_DIR"
echo "--- full runtime vendored into $APP ---"
