#!/usr/bin/env python3
"""Approach (c) for legacy .xls/.ppt: Quick Look thumbnail (qlmanage -t) ->
Vision OCR. Word recall against the own parser's text, and time.
usage: ql_ocr.py OUTDIR FILE..."""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

B = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".build", "release")
out = sys.argv[1]
WORD = re.compile(r"\w{2,}", re.UNICODE)
for f in sys.argv[2:]:
    d = os.path.join(out, os.path.basename(f) + ".thumb")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    t0 = time.time()
    try:
        subprocess.run(["qlmanage", "-t", "-s", "2000", "-o", d, f], capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        print(f"{os.path.basename(f)[:40]:40s} thumbnail TIMEOUT")
        continue
    tq = time.time() - t0
    pngs = glob.glob(os.path.join(d, "*.png"))
    if not pngs:
        print(f"{os.path.basename(f)[:40]:40s} no thumbnail ({tq*1000:.0f} ms)")
        continue
    t1 = time.time()
    ocr = subprocess.run([f"{B}/probe", "ocr", pngs[0]], capture_output=True, timeout=120).stdout.decode()
    to = time.time() - t1
    own = subprocess.run([f"{B}/extract", f], capture_output=True, timeout=60).stdout.decode()
    own_text = "\n".join(json.loads(l)["text"] for l in own.splitlines() if l.strip())
    ow = set(w.lower() for w in WORD.findall(own_text))
    qw = set(w.lower() for w in WORD.findall(ocr))
    rec = len(ow & qw) / len(ow) if ow else 1.0
    print(f"{os.path.basename(f)[:40]:40s} images={len(pngs)} ql={tq*1000:5.0f}ms ocr={to*1000:5.0f}ms own_words={len(ow):5d} ocr_words={len(qw):5d} recall_of_own={rec:6.1%}")
