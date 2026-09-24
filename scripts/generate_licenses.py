#!/usr/bin/env python3
"""Third-party licenses for the app bundle, generated at build time.

Writes <out>/Licenses.json (what the About window lists) and
<out>/THIRD_PARTY_NOTICES.txt (the same, as plain text).

    generate_licenses.py base <repo> <out>
        LLMTray itself, the Swift packages in Package.resolved (license
        files from SwiftPM's checkouts / artifacts), and the web services
        the chat tools use.

    <venv>/bin/python generate_licenses.py runtime <out> <Python.framework> <apache-license.txt> [extra ...]
        Appends the bundled Python runtime (Full build): CPython, with the
        summary of changes PSF §3 asks for, the licenses of the libraries
        the framework ships (`extra` files: python.org's license page for
        OpenSSL, expat, libffi, ...; Tcl/Tk; zstd; ncurses), and every
        package in the venv this runs from, with the license files it
        ships. A package that ships none but declares Apache-2.0 gets the
        Apache text; any other gets a pointer to its project page and a
        warning on stderr.

Standard library only. Fails rather than leaving out CPython's license or
writing an entry without a name.
"""
import importlib.metadata as md
import json
import pathlib
import sys

# Services the chat tools call at run time (nothing of theirs is bundled):
# their terms ask for this attribution.
SERVICES = [
    {"name": "ExchangeRate-API", "license": "Attribution required", "url": "https://www.exchangerate-api.com",
     "text": "Currency rates by ExchangeRate-API (https://www.exchangerate-api.com), used by the convert_currency tool."},
    {"name": "Wikipedia", "license": "CC BY-SA 4.0", "url": "https://creativecommons.org/licenses/by-sa/4.0/",
     "text": "Article summaries from Wikipedia (https://www.wikipedia.org), licensed CC BY-SA 4.0; used by the Wikipedia tool."},
    {"name": "Wikidata", "license": "CC0 1.0", "url": "https://www.wikidata.org",
     "text": "Country facts from Wikidata (https://www.wikidata.org), CC0; used by the country info tool."},
    {"name": "Open-Meteo geocoding", "license": "CC BY 4.0", "url": "https://open-meteo.com",
     "text": "City lookup by Open-Meteo (https://open-meteo.com), data CC BY 4.0, based on GeoNames (https://www.geonames.org); used by the time-in-city tool."},
    {"name": "Nager.Date", "license": "Service terms", "url": "https://date.nager.at",
     "text": "Public holidays from Nager.Date (https://date.nager.at); used by the holidays tool."},
    {"name": "Hacker News API", "license": "Service terms", "url": "https://github.com/HackerNews/API",
     "text": "Stories from the Hacker News API (https://github.com/HackerNews/API); used by the Hacker News tool."},
]


def load(out):
    path = out / "Licenses.json"
    return json.loads(path.read_text()) if path.exists() else {"groups": []}


def save(out, data):
    (out / "Licenses.json").write_text(json.dumps(data, indent=1, ensure_ascii=False))
    rule = "=" * 78
    lines = ["LLMTray -- third-party notices", "Generated at build time; also shown in About LLMTray.", ""]
    for group in data["groups"]:
        lines += [rule, group["title"].upper(), rule, ""]
        for e in group["entries"]:
            head = f"{e['name']} {e.get('version') or ''}".strip()
            lines += [f"--- {head} -- {e['license']}" + (f" ({e['url']})" if e.get("url") else "") + " ---", e.get("text", "").rstrip(), ""]
    (out / "THIRD_PARTY_NOTICES.txt").write_text("\n".join(lines))


def guess_license(text):
    """The common licenses by their telltale sentence; else "see text"."""
    for marker, name in (("Permission is hereby granted, free of charge", "MIT"),
                         ("Apache License", "Apache-2.0"),
                         ("Redistribution and use in source and binary forms", "BSD")):
        if marker in text[:3000]:
            return name
    return "see text"


def base(repo, out):
    entries = [{"name": "LLMTray", "license": "Apache-2.0", "url": "https://github.com/ipsupport-llc/llmtray",
                "text": (repo / "LICENSE").read_text()}]
    pins = json.loads((repo / "Package.resolved").read_text())["pins"]
    for pin in pins:
        name = pin["location"].rstrip("/").split("/")[-1].removesuffix(".git")
        candidates = [repo / ".build" / d / sub for d in ("checkouts", "artifacts") for sub in (name, f"{pin['identity']}/{name}")]
        texts = [f.read_text(errors="replace") for c in candidates if c.is_dir()
                 for f in sorted(c.iterdir()) if f.is_file() and f.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE"))]
        texts = list(dict.fromkeys(texts))   # checkouts and artifacts carry the same files
        if not texts:
            sys.exit(f"error: no license file found for Swift package {name} (resolve packages first)")
        entries.append({"name": name, "version": pin["state"].get("version") or pin["state"]["revision"][:7],
                        "license": guess_license(texts[0]), "url": pin["location"], "text": "\n\n".join(texts)})
    data = {"groups": [
        {"id": "app", "title": "LLMTray and its libraries", "entries": entries},
        {"id": "services", "title": "Services the chat tools use", "entries": SERVICES},
    ]}
    save(out, data)


def license_of(dist):
    meta = dist.metadata
    if meta.get("License-Expression"):
        return meta["License-Expression"]
    classifiers = [c.split("::")[-1].strip() for c in meta.get_all("Classifier") or [] if c.startswith("License ::")]
    if classifiers:
        return ", ".join(classifiers)
    text = (meta.get("License") or "").strip()
    return text.splitlines()[0][:100] if text else "UNKNOWN"


def license_texts(dist):
    """License files in the .dist-info and anywhere in the package itself
    (vendored code ships its own, e.g. mlx's metal_cpp)."""
    out = []
    for f in dist.files or []:
        s = str(f)
        parts = [p.lower() for p in f.parts]
        name = f.name.lower()
        is_license = name.startswith(("license", "licence", "copying", "notice")) and not name.endswith((".py", ".pyc"))
        if (".dist-info" in s and ("licenses" in parts or is_license or name.startswith("authors"))) or (".dist-info" not in s and is_license):
            path = pathlib.Path(dist.locate_file(f))
            if path.is_file():
                out.append(f"--- {s} ---\n" + path.read_text(errors="replace").rstrip())
    return out


def label(path):
    """Tcl's and Tk's files are both license.terms: named by framework."""
    return next((p for p in path.parts if p.endswith(".framework") and p != "Python.framework"), path.name)


def runtime(out, framework, apache, extras):
    licenses = sorted(framework.glob("Versions/*/lib/python*/LICENSE.txt"))
    if not licenses:
        sys.exit(f"error: no CPython LICENSE.txt under {framework}")
    entries = [{"name": "CPython (Python.framework from python.org)", "version": sys.version.split()[0], "license": "PSF-2.0",
                "url": "https://docs.python.org/3/license.html",
                "text": "Modified: install names rewritten to @loader_path so the framework is relocatable inside the app "
                        "bundle, and the binaries re-signed.\n\n" + licenses[0].read_text(errors="replace")
                        + "".join(f"\n\n=== Bundled with the framework: {label(e)} ===\n\n" + e.read_text(errors="replace") for e in extras)}]
    apache_text = apache.read_text()
    for dist in sorted(md.distributions(), key=lambda d: (d.metadata["Name"] or "").lower()):
        name = dist.metadata["Name"]
        if not name:
            sys.exit(f"error: a distribution without a name at {dist.locate_file('')}")
        lic = license_of(dist)
        texts = license_texts(dist)
        if not texts:
            if "apache" in lic.lower():
                texts = [apache_text]
            else:
                print(f"warning: {name} ships no license file ({lic})", file=sys.stderr)
                texts = [f"No license file shipped; see https://pypi.org/project/{name}/"]
        entries.append({"name": name, "version": dist.version or "", "license": lic,
                        "url": f"https://pypi.org/project/{name}/", "text": "\n\n".join(texts)})
    data = load(out)
    data["groups"] = [g for g in data["groups"] if g["id"] != "runtime"]
    data["groups"].insert(1, {"id": "runtime", "title": "Bundled Python runtime", "entries": entries})
    save(out, data)


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "base" and len(sys.argv) == 4:
        base(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
    elif mode == "runtime" and len(sys.argv) >= 5:
        runtime(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4]),
                [pathlib.Path(a) for a in sys.argv[5:]])
    else:
        sys.exit(__doc__)
