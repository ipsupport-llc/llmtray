#!/usr/bin/env python3
"""Mutation smoke-fuzz: random byte flips / truncations / chunk duplications of
seed files, each run under `supervise` (timeout + jetsam). Tallies how runs
end: ok, handled failure (exit 2), crash (signal), timeout, memory kill.
usage: fuzz.py OUTDIR ITERATIONS SEED..."""
import collections
import json
import os
import random
import subprocess
import sys

B = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".build", "release")
out, iters, seeds = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
os.makedirs(out, exist_ok=True)
rng = random.Random(12345)
for seed in seeds:
    data = open(seed, "rb").read()
    tally = collections.Counter()
    worst = []
    for i in range(iters):
        b = bytearray(data)
        kind = rng.choice(["flip", "flip", "flip", "truncate", "dup"])
        if kind == "flip":
            for _ in range(rng.randint(1, 20)):
                b[rng.randrange(len(b))] = rng.randrange(256)
        elif kind == "truncate":
            b = b[: rng.randrange(1, len(b))]
        else:
            s = rng.randrange(len(b))
            e = min(len(b), s + rng.randint(1, 4096))
            b[s:s] = b[s:e] * rng.randint(1, 8)
        ext = os.path.splitext(seed)[1]
        path = os.path.join(out, f"m{ext}")
        open(path, "wb").write(b)
        p = subprocess.run([f"{B}/supervise", "--quiet", "--timeout", "5", "--jetsam", "512", "--",
                            f"{B}/extract", path], capture_output=True, timeout=30)
        s = json.loads(p.stderr.decode().strip().splitlines()[-1])
        if s["killed_by"] and s["killed_by"].startswith("timeout"):
            r = "timeout"
        elif s["signal"] == 9:
            r = "memory-kill"
        elif s["signal"]:
            r = f"crash-sig{s['signal']}"
        elif s["exit"] == 0:
            r = "ok"
        else:
            r = "handled-failure"
        tally[r] += 1
        if r not in ("ok", "handled-failure"):
            keep = os.path.join(out, f"{os.path.basename(seed)}.{r}.{i}{ext}")
            os.replace(path, keep)
            worst.append((r, os.path.basename(keep), s["stderr_tail"].strip().splitlines()[-1:] if s["stderr_tail"].strip() else ""))
    print(f"{os.path.basename(seed)[:32]:32s} n={iters} " + " ".join(f"{k}={v}" for k, v in sorted(tally.items())))
    for w in worst[:4]:
        print(f"    {w}")
