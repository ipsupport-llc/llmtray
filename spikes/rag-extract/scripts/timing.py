#!/usr/bin/env python3
"""Per-format timing: median of N runs of `supervise -- extract FILE`, with
the child's own extraction time (excludes process start) and peak footprint.
usage: timing.py [-n 3] FILE..."""
import json
import os
import statistics
import subprocess
import sys

B = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".build", "release")
args = sys.argv[1:]
n = 3
if args[:1] == ["-n"]:
    n = int(args[1])
    args = args[2:]
print(f"{'file':28s} {'size':>9s} {'kind':>5s} {'pages':>5s} {'chars':>9s} {'extract ms':>10s} {'wall ms':>8s} {'peak MB':>7s}")
for f in args:
    walls, inner, peaks = [], [], []
    kind = pages = chars = None
    for _ in range(n):
        p = subprocess.run([f"{B}/supervise", "--timeout", "120", "--", f"{B}/extract", f], capture_output=True, timeout=200)
        lines = [json.loads(l) for l in p.stdout.decode().splitlines() if l.strip()]
        s = json.loads(p.stderr.decode().strip().splitlines()[-1])
        walls.append(s["wall_ms"])
        peaks.append(s["peak_footprint_mb"])
        tail = s["stderr_tail"]
        if "kind=" in tail:
            kv = dict(x.split("=", 1) for x in tail.split() if "=" in x)
            kind, pages, ms = kv["kind"], int(kv["pages"]), int(kv["ms"])
            inner.append(ms)
        chars = sum(len(l.get("text", "")) for l in lines)
    size = os.path.getsize(f)
    print(f"{os.path.basename(f)[:28]:28s} {size:9d} {kind or '-':>5s} {pages or 0:5d} {chars:9d} "
          f"{statistics.median(inner) if inner else -1:10.0f} {statistics.median(walls):8.0f} {max(peaks):7d}")
