#!/usr/bin/env python3
"""Quick Look (qlmanage -p, Apple's OfficeImport HTML preview) vs the own
parser on legacy .xls/.ppt: time per file, and word-level recall each way.

usage: ql_compare.py OUTDIR FILE...
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

EXE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".build", "release", "extract")
out = sys.argv[1]
WORD = re.compile(r"\w{2,}", re.UNICODE)


def words(t):
    return set(w.lower() for w in WORD.findall(t))


def own(f):
    t0 = time.time()
    p = subprocess.run([EXE, f], capture_output=True, timeout=60)
    dt = time.time() - t0
    text = "\n".join(json.loads(l)["text"] for l in p.stdout.decode().splitlines() if l.strip())
    return text, dt, p.returncode


def ql(f):
    d = os.path.join(out, os.path.basename(f) + ".ql")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    t0 = time.time()
    try:
        subprocess.run(["qlmanage", "-p", "-o", d, f], capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        return "", 60.0, "timeout"
    dt = time.time() - t0
    htmls = sorted(glob.glob(os.path.join(d, "*.qlpreview", "*.html")))
    texts = []
    for h in htmls:
        p = subprocess.run([EXE, h, "--kind", "html"], capture_output=True, timeout=60)
        texts += [json.loads(l)["text"] for l in p.stdout.decode().splitlines() if l.strip()]
    return "\n".join(texts), dt, f"{len(htmls)} html"


tot = {"own_t": 0, "ql_t": 0}
print(f"{'file':44s} {'own ms':>7s} {'ql ms':>7s} {'own words':>9s} {'ql words':>9s} {'ql⊂own':>7s} {'own⊂ql':>7s}")
for f in sys.argv[2:]:
    ot, odt, rc = own(f)
    qt, qdt, info = ql(f)
    ow, qw = words(ot), words(qt)
    q_in_o = len(qw & ow) / len(qw) if qw else 1.0
    o_in_q = len(qw & ow) / len(ow) if ow else 1.0
    tot["own_t"] += odt
    tot["ql_t"] += qdt
    print(f"{os.path.basename(f)[:44]:44s} {odt*1000:7.0f} {qdt*1000:7.0f} {len(ow):9d} {len(qw):9d} {q_in_o:7.1%} {o_in_q:7.1%}  rc={rc} {info}")
print(f"total own {tot['own_t']:.2f}s, quick look {tot['ql_t']:.2f}s")
