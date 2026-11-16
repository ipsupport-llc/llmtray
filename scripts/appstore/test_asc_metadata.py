#!/usr/bin/env python3
"""Offline checks for asc_metadata.py: no network, a throwaway key."""
import base64
import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import asc_metadata as am  # noqa: E402

failures = 0


def expect(what, ok):
    global failures
    print(("ok   " if ok else "FAIL ") + what)
    failures += 0 if ok else 1


# The repo's own texts pass.
locales = am.read_locales(am.ROOT / "appstore" / "metadata")
errors = [p for p in am.check(locales) if p[1].startswith("error")]
expect(f"repo texts have no errors {errors}", not errors)
expect("en-US is there", "en-US" in locales)

# The rules catch what they should.
good = {"name": "App: Local Chat", "subtitle": "Private", "keywords": "a" * 90,
        "promotional_text": "p", "description": "d"}


def messages(**over):
    return " | ".join(m for _, m in am.check({"en-US": {**good, **over}}))


expect("clean set passes", not messages())
expect("long name", "name is 31" in messages(name="x" * 31))
expect("long keywords", "keywords is 101" in messages(keywords="k" * 101))
expect("space after comma", "space next to a comma" in messages(keywords="one, two" + "x" * 90))
expect("repeated keyword", "repeat: one" in messages(keywords="one,one," + "x" * 90))
expect("keyword from the name", "already in the name" in messages(keywords="chat," + "x" * 90))
expect("device name", "names an Apple device" in messages(subtitle="For your Mac"))
expect("missing file", "description.txt is missing" in messages(description=""))

version_only = {k: v for k, v in good.items() if k not in ("name", "subtitle")}
expect("a folder without name and subtitle passes", not am.check({"en-US": version_only}))

# Only what differs is sent; a new locale is created.
existing = {"en-US": {"id": "1", "attributes": {"keywords": "old", "description": "same"}}}
wanted = {"en-US": {"keywords": "new", "description": "same"}, "ru": {"keywords": "ключ"}}
steps = am.plan(wanted, existing, {"keywords", "description"})
expect("plan", steps == [("en-US", "1", {"keywords": "new"}), ("ru", None, {"keywords": "ключ"})])

# The token is a valid ES256 JWT for the key.
with tempfile.TemporaryDirectory() as tmp:
    key, pub = f"{tmp}/k.p8", f"{tmp}/k.pub"
    subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", key],
                   check=True, capture_output=True)
    subprocess.run(["openssl", "pkey", "-in", key, "-pubout", "-out", pub], check=True, capture_output=True)
    head, body, sig = am.token("KEYID", "ISSUER", key, now=1_000).split(".")
    raw = base64.urlsafe_b64decode(sig + "=" * (-len(sig) % 4))
    expect("signature is 64 bytes", len(raw) == 64)

    def der_int(b):
        b = b.lstrip(b"\x00") or b"\x00"
        if b[0] & 0x80:
            b = b"\x00" + b
        return b"\x02" + bytes([len(b)]) + b
    seq = der_int(raw[:32]) + der_int(raw[32:])
    Path(f"{tmp}/sig").write_bytes(b"\x30" + bytes([len(seq)]) + seq)
    verified = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", f"{tmp}/sig"],
                              input=f"{head}.{body}".encode(), capture_output=True)
    expect("signature verifies", verified.returncode == 0)
    claims = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
    expect("claims", claims == {"iss": "ISSUER", "iat": 1000, "exp": 1900, "aud": "appstoreconnect-v1"})

sys.exit(1 if failures else 0)
