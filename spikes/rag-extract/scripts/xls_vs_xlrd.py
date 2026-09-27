#!/usr/bin/env python3
"""Completeness of `extract` on .xls against xlrd 2.0.1 (the reference BIFF reader).

For every non-empty cell xlrd reports, is that cell's text among the cells
`extract` printed for the same sheet? Numbers are compared by value, dates by
xlrd's own date conversion. Prints per-file and total recall.
usage: PYTHONPATH=<xlrd dir> xls_vs_xlrd.py FILE...
"""
import collections
import datetime
import json
import os
import subprocess
import sys

import xlrd

EXE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".build", "release", "extract")


def norm_num(s):
    try:
        return round(float(s), 6)
    except ValueError:
        return None


tot_ref = tot_hit = 0
for f in sys.argv[1:]:
    try:
        book = xlrd.open_workbook(f, formatting_info=False)
    except Exception as e:  # noqa: BLE001
        print(f"{os.path.basename(f)}: xlrd failed: {e}")
        continue
    p = subprocess.run([EXE, f], capture_output=True, timeout=60)
    pages = [json.loads(l) for l in p.stdout.decode().splitlines() if l.strip()]
    by_name = {pg.get("name"): pg for pg in pages}
    ref = hit = 0
    misses = []
    for sh in book.sheets():
        pg = by_name.get(sh.name)
        cells = collections.Counter()
        nums = collections.Counter()
        if pg:
            for line in pg["text"].split("\n"):
                for c in line.split(" | "):
                    c = c.strip()
                    cells[c] += 1
                    n = norm_num(c)
                    if n is not None:
                        nums[n] += 1
        for r in range(sh.nrows):
            for c in range(sh.ncols):
                cell = sh.cell(r, c)
                if cell.ctype in (xlrd.XL_CELL_EMPTY, xlrd.XL_CELL_BLANK):
                    continue
                v = cell.value
                if cell.ctype == xlrd.XL_CELL_TEXT:
                    v = v.replace("\n", " ").strip()
                    if not v:
                        continue
                    ok = v in cells or (pg is not None and v in pg["text"])  # a cell may contain " | "
                elif cell.ctype == xlrd.XL_CELL_NUMBER:
                    ok = round(v, 6) in nums
                elif cell.ctype == xlrd.XL_CELL_DATE:
                    try:
                        d = xlrd.xldate_as_datetime(v, book.datemode)
                        ok = any(k.startswith(d.strftime("%Y-%m-%d")) or k.startswith(d.strftime("%H:%M")) for k in cells)
                    except Exception:  # noqa: BLE001
                        ok = round(v, 6) in nums
                elif cell.ctype == xlrd.XL_CELL_BOOLEAN:
                    ok = ("TRUE" if v else "FALSE") in cells
                else:
                    ok = "#ERR" in cells
                ref += 1
                hit += ok
                if not ok and len(misses) < 3:
                    misses.append((sh.name, r, c, cell.ctype, str(v)[:40]))
    tot_ref += ref
    tot_hit += hit
    pct = 100.0 * hit / ref if ref else 100.0
    print(f"{os.path.basename(f)[:50]:50s} cells={ref:6d} found={hit:6d} {pct:6.2f}%  {misses if misses else ''}")
print(f"TOTAL cells={tot_ref} found={tot_hit} {100.0 * tot_hit / max(tot_ref, 1):.2f}%")
