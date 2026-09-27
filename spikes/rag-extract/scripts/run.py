#!/usr/bin/env python3
"""Runs the built `extract` over files and prints a compact summary per file.

usage: run.py [--full] [--width N] FILE...   (globs are expanded by the shell or here)
"""
import glob
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
EXE = os.path.join(HERE, "..", ".build", "release", "extract")

args = sys.argv[1:]
full = "--full" in args
width = 200
if "--width" in args:
    i = args.index("--width")
    width = int(args[i + 1])
    del args[i:i + 2]
args = [a for a in args if a != "--full"]
extra = []
if "--" in args:
    i = args.index("--")
    extra = args[i + 1:]
    args = args[:i]
files = []
for a in args:
    files += sorted(glob.glob(a)) or [a]

for f in files:
    t0 = time.time()
    p = subprocess.run([EXE, f] + extra, capture_output=True, timeout=120)
    dt = (time.time() - t0) * 1000
    lines = [json.loads(l) for l in p.stdout.decode("utf-8", "replace").splitlines() if l.strip()]
    print(f"== {os.path.basename(f)}  exit={p.returncode} wall={dt:.0f}ms  {p.stderr.decode(errors='replace').strip()[:200]}")
    for l in lines:
        t = l.get("text", "")
        shown = t if full else t.replace("\n", " / ")[:width]
        extra_s = f" name={l['name']!r}" if l.get("name") else ""
        err = f" ERROR={l['error']}" if l.get("error") else ""
        print(f"  p{l['page']} junk={l['junk_score']:.2f} chars={len(t)}{extra_s}{err}: {shown}")
