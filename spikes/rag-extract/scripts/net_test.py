#!/usr/bin/env python3
"""Which extraction paths touch the network? Each case runs against samples
whose remote references point at the local listener (listen.py); the new
log lines after each case are the connections it made.
usage: net_test.py GENDIR LOGFILE"""
import os
import subprocess
import sys
import time

gen, log = sys.argv[1], sys.argv[2]
B = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".build", "release")
cases = [
    ("own HTML parser (extract)", [f"{B}/extract", f"{gen}/html_remote.html"]),
    ("NSAttributedString .html, main thread", [f"{B}/probe", "attr", f"{gen}/html_remote.html", "html", "main"]),
    ("NSAttributedString .html, main, child sandboxed no-network",
     [f"{B}/extract", "--no-network", f"{gen}/html_remote.html", "--kind", "html"]),
    ("NSAttributedString .docx external image (extract)", [f"{B}/extract", f"{gen}/docx_external_image.docx"]),
    ("NSAttributedString .rtf INCLUDEPICTURE (extract)", [f"{B}/extract", f"{gen}/rtf_remote.rtf"]),
    ("XMLParser external entity, resolve=on (probe)", [f"{B}/probe", "xmlraw", f"{gen}/xml_xxe.xml", "--resolve"]),
    ("XMLParser external entity, resolve=off (probe)", [f"{B}/probe", "xmlraw", f"{gen}/xml_xxe.xml"]),
    ("qlmanage -p .html", ["qlmanage", "-p", "-o", f"{gen}/../qlnet", f"{gen}/html_remote.html"]),
    ("qlmanage -p .docx external image", ["qlmanage", "-p", "-o", f"{gen}/../qlnet", f"{gen}/docx_external_image.docx"]),
]


def count():
    try:
        with open(log) as f:
            return f.read().splitlines()
    except FileNotFoundError:
        return []


os.makedirs(f"{gen}/../qlnet", exist_ok=True)
for name, cmd in cases:
    before = len(count())
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=40)
        out = (p.stdout.decode(errors="replace").strip().splitlines() or [""])[0][:110]
    except subprocess.TimeoutExpired:
        out = "TIMEOUT"
    time.sleep(3)
    new = count()[before:]
    print(f"{name:58s} connections={len(new):2d}  {out}")
    for l in new:
        print(f"      {l}")
