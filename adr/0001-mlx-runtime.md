# 0001 — The mlx-lm runtime

## Decision

- **Our fork only.** mlx-lm is installed exclusively from
  `ipsupport-llc/mlx-lm`, never from PyPI. The fork carries what upstream
  doesn't: NemotronH MTP self-speculative decoding, the Gemma 4 MTP
  drafter, RotatingKVCache quantization, prism Hadamard ternary models
  (and their JANG repacks), `--model-alias` / `--kv-bits` / disconnect
  safety in the server, and model-loading fixes (see that repo's
  `docs/FINDINGS.md`).
- **A pinned commit.** `runtime/mlx_lm_runtime.json` names one commit of the
  fork's `main`. Stable users get exactly that; Check for Runtime Updates
  moves it. Beta users track the fork's `beta` branch (falls back to
  `main`). A former Advanced toggle that tracked a feature branch tip was
  removed: it was a second, easy-to-forget place a fix could land without
  reaching the app.
- **A venv outside the bundle**, under
  `~/Library/Application Support/LLMTray/mlx_server_venv`. Sparkle replaces
  `Contents/` wholesale on every update, so a venv inside it would be
  reinstalled (network, minutes) after every update. A version marker file,
  written only after a fully successful install, distinguishes "ready" /
  "needs the new pin" from a half-built venv left by a crash.
- **The interpreter, not the console script.** The server runs as
  `python3 -m mlx_lm.server`, never `bin/mlx_lm.server`: pip bakes the
  interpreter's absolute path into that script's shebang — for the Full
  build a GitHub Actions runner path that exists nowhere else — and
  shebangs can't contain spaces, which `Application Support` guarantees.

## The Full build

`LLMTray-Full.dmg` vendors a python.org Python.framework and a ready venv
so the first launch needs no network and no system Python.

- **Relocatable framework.** python.org's installer bakes absolute
  `/Library/Frameworks/Python.framework/...` paths into `bin/python3.X`, the
  `Python.app` launcher stub it re-execs into, and — less obviously — the
  `_ssl`/`_hashlib` extensions and `libssl`/`libcrypto`, which reference each
  other by absolute path. Any one missed means a dyld "Library not loaded"
  crash or a silently disabled ssl module (pip: "ssl module is not
  available"). `build_full_app.sh` therefore rewrites *every* absolute
  reference under the framework (found with `otool`) to `@loader_path`
  with the right depth. `@loader_path`, not `@executable_path`: because of
  that re-exec, `@executable_path` resolved against the launcher stub and
  landed one directory off.
- **Copied out on first run.** The bundled venv and framework are copied to
  the external runtime directory (off the main thread — hundreds of MB).
  The venv's `bin/python3.X` is a symlink to the framework by absolute path,
  so after the copy it's re-pointed at the copied framework. Matched by the
  stable `Python.framework/` *suffix* of the target, not by prefix against
  the running app's path: the symlink was created on the build machine (a
  CI runner), which has nothing in common with where the app is installed —
  prefix matching silently matched nothing on a real release. Without the
  relink the venv works until the next Sparkle update removes the original
  app, then fails with a bare "no such file or directory".
- **The framework is kept too**, so a venv deleted later (Uninstall Runtime
  Data) can be recreated without a system Python.

## Finding a system Python (thin build)

GUI apps don't inherit the shell's PATH, so `python3` resolves to the Xcode
Command Line Tools Python 3.9, whose pip finds no `mlx` wheels — venv
creation succeeds and the install then fails. Known locations (Homebrew
both architectures, pyenv, MacPorts, conda) are probed for a real 3.10+.
`/usr/bin/python3` is deliberately never tried: on a clean Mac it's a stub
that pops an "Install Command Line Developer Tools" dialog.
