#!/usr/bin/env python3
"""App Store listing texts: one folder per locale, pushed in one go.

    appstore/metadata/<locale>/name.txt              30   (app, all platforms)
                               subtitle.txt          30   (app, all platforms)
                               keywords.txt         100   (version)
                               promotional_text.txt 170   (version)
                               description.txt     4000   (version)
                               release_notes.txt   4000   (version, optional)
    appstore/metadata/en-US/urls.txt                      (applied to every locale)

Folder names are App Store Connect locale codes (en-US, de-DE, ru, zh-Hans).

    asc_metadata.py check                  # limits and keyword rules, no network
    asc_metadata.py pull                   # App Store Connect -> files
    asc_metadata.py push                   # dry run: what would change
    asc_metadata.py push --apply           # write it
    asc_metadata.py push --apply --promo   # promotional text only, live version

--promo changes only the locales the live version already has; new locales
arrive with the next version.

Name and subtitle belong to the app and are shared by its platforms; they
are pushed only with --app-info. The other texts go to the version of
--platform that is still editable (Prepare for Submission, rejected, ...).
With no editable version only promotional text can change (--promo).

A locale new to a version that updates a released one needs "What's New":
release_notes.txt of that locale, else of en-US, else the text the version
already has for en-US.

Key (App Store Connect > Users and Access > Integrations > Team Keys, role
App Manager): ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8 file).
Needs only Python and openssl.
"""

import argparse
import base64
import json
import os
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "us.ipsupport.llmtray.appstore"
ROOT = pathlib.Path(__file__).resolve().parents[2]

# file stem -> (API attribute, limit)
INFO_FIELDS = {"name": ("name", 30), "subtitle": ("subtitle", 30)}
VERSION_FIELDS = {
    "keywords": ("keywords", 100),
    "promotional_text": ("promotionalText", 170),
    "description": ("description", 4000),
    "release_notes": ("whatsNew", 4000),
}
URL_FIELDS = {"Marketing URL": "marketingUrl", "Support URL": "supportUrl"}
REQUIRED = ["name", "subtitle", "keywords", "promotional_text", "description"]
# States in which a version's (or the app info's) texts can be edited.
EDITABLE = {
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
    "METADATA_REJECTED", "INVALID_BINARY", "WAITING_FOR_REVIEW_REJECTED",
}
LIVE = {"READY_FOR_SALE", "READY_FOR_DISTRIBUTION"}


# ---------------------------------------------------------------- files

def read_locales(folder):
    """{locale: {stem: text}} for every locale folder."""
    out = {}
    for d in sorted(p for p in folder.iterdir() if p.is_dir()):
        texts = {}
        for stem in list(INFO_FIELDS) + list(VERSION_FIELDS):
            f = d / f"{stem}.txt"
            if f.exists():
                texts[stem] = f.read_text(encoding="utf-8").strip()
        if texts:
            out[d.name] = texts
    return out


def read_urls(folder):
    f = folder / "en-US" / "urls.txt"
    urls = {}
    if f.exists():
        for line in f.read_text(encoding="utf-8").splitlines():
            label, _, value = line.partition(":")
            if label.strip() in URL_FIELDS and value.strip():
                urls[URL_FIELDS[label.strip()]] = value.strip()
    return urls


def words(text):
    return {w for w in re.split(r"[\s,;:.!?&/()«»\"'、，。・-]+", text.lower()) if w}


def check(locales):
    """Problems as (locale, message); errors start with 'error'."""
    problems = []
    if "en-US" not in locales:
        problems.append(("-", "error: no en-US folder"))
    for locale, texts in locales.items():
        for stem in REQUIRED:
            if not texts.get(stem):
                problems.append((locale, f"error: {stem}.txt is missing or empty"))
        for stem, (_, limit) in {**INFO_FIELDS, **VERSION_FIELDS}.items():
            n = len(texts.get(stem, ""))
            if n > limit:
                problems.append((locale, f"error: {stem} is {n} characters, limit {limit}"))
        keywords = texts.get("keywords", "")
        if keywords:
            if re.search(r",\s|\s,", keywords):
                problems.append((locale, "error: keywords have a space next to a comma"))
            items = [k for k in keywords.split(",")]
            if any(not k.strip() for k in items):
                problems.append((locale, "error: keywords have an empty item"))
            seen = [k for k in set(items) if items.count(k) > 1]
            if seen:
                problems.append((locale, f"error: keywords repeat: {', '.join(sorted(seen))}"))
            taken = words(texts.get("name", "")) | words(texts.get("subtitle", ""))
            wasted = sorted(k for k in items if k.lower() in taken)
            if wasted:
                problems.append((locale, f"warning: keywords already in the name or subtitle: {', '.join(wasted)}"))
            if len(keywords) < 85:
                problems.append((locale, f"warning: keywords use {len(keywords)} of 100 characters"))
        for stem in ("name", "subtitle"):
            if re.search(r"\b(mac|macos|iphone|ipad)\b", texts.get(stem, "").lower()):
                problems.append((locale, f"error: {stem} names an Apple device"))
    return problems


def report(locales):
    stems = REQUIRED + ["release_notes"]
    print(f"{'locale':9}" + "".join(f"{s[:11]:>12}" for s in stems))
    for locale, texts in locales.items():
        print(f"{locale:9}" + "".join(f"{len(texts[s]) if s in texts else '-':>12}" for s in stems))


# ---------------------------------------------------------------- API

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der):
    """An ECDSA DER signature as the 64 raw bytes a JWT wants."""
    def integer(at):
        assert der[at] == 0x02
        size = der[at + 1]
        value = der[at + 2: at + 2 + size].lstrip(b"\x00")
        return value.rjust(32, b"\x00"), at + 2 + size
    at = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    r, at = integer(at)
    s, _ = integer(at)
    return r + s


def token(key_id, issuer, key_path, now=None):
    now = int(now or time.time())
    head = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    body = b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 900,
                              "aud": "appstoreconnect-v1"}).encode())
    signing = f"{head}.{body}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                         input=signing, capture_output=True, check=True).stdout
    return f"{head}.{body}.{b64url(der_to_raw(der))}"


class Client:
    def __init__(self):
        missing = [v for v in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH") if not os.environ.get(v)]
        if missing:
            sys.exit(f"Set {', '.join(missing)} (see the top of this file).")
        self.jwt = token(os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"],
                         os.path.expanduser(os.environ["ASC_KEY_PATH"]))

    def call(self, method, path, body=None):
        url = path if path.startswith("http") else API + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {self.jwt}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            try:
                detail = "; ".join(f"{x.get('title')}: {x.get('detail')}" for x in json.loads(detail)["errors"])
            except (ValueError, KeyError):
                pass
            raise RuntimeError(f"{method} {path}: {e.code} {detail}") from None

    def all(self, path):
        items = []
        while path:
            page = self.call("GET", path)
            items += page["data"]
            path = page.get("links", {}).get("next")
        return items


def find_app(api):
    apps = api.all("/v1/apps?filter[bundleId]=" + BUNDLE_ID)
    if not apps:
        sys.exit(f"No app with bundle id {BUNDLE_ID} for this key.")
    return apps[0]["id"]


def state_of(item):
    a = item["attributes"]
    return a.get("appVersionState") or a.get("appStoreState") or a.get("state") or ""


def pick(items, states):
    return next((i for i in items if state_of(i) in states), None)


def targets(api, app, platform):
    """(editable app info, editable version, live version); each may be None."""
    infos = api.all(f"/v1/apps/{app}/appInfos")
    versions = api.all(f"/v1/apps/{app}/appStoreVersions?filter[platform]={platform}&limit=50")
    versions.sort(key=lambda v: v["attributes"].get("createdDate") or "", reverse=True)
    return pick(infos, EDITABLE), pick(versions, EDITABLE), pick(versions, LIVE)


def localizations(api, kind, parent):
    path = (f"/v1/appInfos/{parent}/appInfoLocalizations" if kind == "info"
            else f"/v1/appStoreVersions/{parent}/appStoreVersionLocalizations")
    return {i["attributes"]["locale"]: i for i in api.all(path + "?limit=200")}


def plan(wanted, existing, attributes):
    """[(locale, id or None, {attribute: new text})] for what differs."""
    steps = []
    for locale, values in wanted.items():
        have = existing.get(locale)
        current = have["attributes"] if have else {}
        change = {k: v for k, v in values.items()
                  if k in attributes and v and v != (current.get(k) or "")}
        if change:
            steps.append((locale, have["id"] if have else None, change))
    return steps


def send(api, kind, parent, steps):
    resource = "appInfoLocalizations" if kind == "info" else "appStoreVersionLocalizations"
    relation = "appInfo" if kind == "info" else "appStoreVersion"
    parent_type = "appInfos" if kind == "info" else "appStoreVersions"
    failed = 0
    for locale, ident, change in steps:
        try:
            if ident:
                api.call("PATCH", f"/v1/{resource}/{ident}",
                         {"data": {"type": resource, "id": ident, "attributes": change}})
            else:
                api.call("POST", f"/v1/{resource}", {"data": {
                    "type": resource, "attributes": {"locale": locale, **change},
                    "relationships": {relation: {"data": {"type": parent_type, "id": parent}}}}})
            print(f"  {locale}: done")
        except RuntimeError as e:
            failed += 1
            print(f"  {locale}: FAILED: {e}")
    return failed


def show(title, steps):
    print(f"{title}: {len(steps)} locale(s) to change")
    for locale, ident, change in steps:
        fields = ", ".join(f"{k} ({len(v)})" for k, v in change.items())
        print(f"  {locale}: {'update' if ident else 'new'}: {fields}")


def push(args, locales):
    errors = [p for p in check(locales) if p[1].startswith("error")]
    if errors:
        for locale, message in errors:
            print(f"{locale}: {message}")
        sys.exit("Fix these first.")
    api = Client()
    app = find_app(api)
    info, version, live = targets(api, app, args.platform)
    urls = read_urls(args.dir)
    failed = 0

    if args.app_info:
        if not info:
            print("Name and subtitle: no editable app info (they change with a new version).")
        else:
            wanted = {loc: {INFO_FIELDS[s][0]: t[s] for s in INFO_FIELDS if s in t} for loc, t in locales.items()}
            steps = plan(wanted, localizations(api, "info", info["id"]), {"name", "subtitle"})
            show("Name and subtitle", steps)
            if args.apply:
                failed += send(api, "info", info["id"], steps)

    target = live if args.promo else version
    if not target:
        which = "live" if args.promo else "editable"
        print(f"Version texts: no {which} {args.platform} version."
              + ("" if args.promo else " Create the next version first, or use --promo."))
    else:
        existing = localizations(api, "version", target["id"])
        notes = locales.get("en-US", {}).get("release_notes") or \
            (existing.get("en-US", {}).get("attributes", {}).get("whatsNew") or "")
        # A platform's first version has no "What's New".
        first = live is None
        wanted = {}
        for loc, t in locales.items():
            values = {VERSION_FIELDS[s][0]: t[s] for s in VERSION_FIELDS if s in t}
            if args.promo:
                # A released version takes no new locales.
                if loc not in existing:
                    continue
                values = {k: v for k, v in values.items() if k == "promotionalText"}
            else:
                values.update(urls)
                if "whatsNew" not in values and loc not in existing and notes and not first:
                    values["whatsNew"] = notes
                if first:
                    values.pop("whatsNew", None)
            wanted[loc] = values
        allowed = {"promotionalText"} if args.promo else \
            {"keywords", "promotionalText", "description", "whatsNew", "marketingUrl", "supportUrl"}
        steps = plan(wanted, existing, allowed)
        label = target["attributes"].get("versionString")
        show(f"{args.platform} {label} ({state_of(target)})", steps)
        if args.apply:
            failed += send(api, "version", target["id"], steps)

    if not args.apply:
        print("Dry run. Add --apply to write.")
    sys.exit(1 if failed else 0)


def pull(args):
    api = Client()
    app = find_app(api)
    info, version, live = targets(api, app, args.platform)
    infos = api.all(f"/v1/apps/{app}/appInfos")
    info = info or (infos[0] if infos else None)
    version = version or live
    wrote = 0
    for kind, parent, fields in (("info", info, INFO_FIELDS), ("version", version, VERSION_FIELDS)):
        if not parent:
            continue
        for locale, item in localizations(api, kind, parent["id"]).items():
            folder = args.dir / locale
            folder.mkdir(parents=True, exist_ok=True)
            for stem, (attribute, _) in fields.items():
                text = item["attributes"].get(attribute)
                if text:
                    (folder / f"{stem}.txt").write_text(text.strip() + "\n", encoding="utf-8")
                    wrote += 1
    print(f"Wrote {wrote} files to {args.dir}")


def main():
    p = argparse.ArgumentParser(description="App Store listing texts for every locale.")
    p.add_argument("command", choices=["check", "pull", "push"])
    p.add_argument("--dir", type=pathlib.Path, default=ROOT / "appstore" / "metadata")
    p.add_argument("--platform", default="MAC_OS", help="App Store Connect platform of the version")
    p.add_argument("--apply", action="store_true", help="write (push is a dry run without it)")
    p.add_argument("--app-info", action="store_true", help="also push the name and subtitle")
    p.add_argument("--promo", action="store_true", help="promotional text only, to the live version")
    args = p.parse_args()

    if args.command == "pull":
        return pull(args)
    locales = read_locales(args.dir)
    if args.command == "check":
        report(locales)
        problems = check(locales)
        for locale, message in problems:
            print(f"{locale}: {message}")
        sys.exit(1 if any(m.startswith("error") for _, m in problems) else 0)
    push(args, locales)


if __name__ == "__main__":
    main()
