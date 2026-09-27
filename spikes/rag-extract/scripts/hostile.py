#!/usr/bin/env python3
"""Every hostile sample through `supervise -- extract`, with the limits the
app would use. Prints one row per file: how it ended, time, peak memory.
usage: hostile.py [--jetsam MB | --mem MB] [--timeout S] [--max-out BYTES] [--extract-args "..."] FILE..."""
import json
import os
import shlex
import subprocess
import sys

B = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".build", "release")
args = sys.argv[1:]


def take(flag, default):
    if flag in args:
        i = args.index(flag)
        v = args[i + 1]
        del args[i:i + 2]
        return v
    return default


jetsam = take("--jetsam", None)
mem = take("--mem", None)
timeout = take("--timeout", "20")
maxout = take("--max-out", str(64 << 20))
xargs = shlex.split(take("--extract-args", ""))
sup = [f"{B}/supervise", "--quiet", "--timeout", timeout, "--max-out", maxout]
if jetsam:
    sup += ["--jetsam", jetsam]
if mem:
    sup += ["--mem", mem]
print(f"limits: timeout={timeout}s max-out={maxout} jetsam={jetsam} poll-mem={mem} extract-args={xargs}")
for f in args:
    p = subprocess.run(sup + ["--", f"{B}/extract", f] + xargs, capture_output=True, timeout=int(float(timeout)) + 30)
    s = json.loads(p.stderr.decode().strip().splitlines()[-1])
    if s["signal"]:
        how = f"KILLED sig{s['signal']} by {s['killed_by'] or {9: 'kernel (jetsam limit)', 24: 'RLIMIT_CPU (SIGXCPU)'}.get(s['signal'], 'crash')}"
    elif s["exit"] == 0:
        how = "ok"
    else:
        how = f"failed exit={s['exit']}"
    tail = s["stderr_tail"].strip().splitlines()[-1][:120] if s["stderr_tail"].strip() else ""
    print(f"{os.path.basename(f)[:34]:34s} {how:44s} {s['wall_ms']:6d}ms peak={s['peak_footprint_mb']:5d}MB out={s['out_bytes']:>10d}B  {tail}")
