#!/usr/bin/env python3
"""Stamps the site's structured data with the latest stable release.

    stamp_site.py releases.json _site/index.html

releases.json: the GitHub releases API, as pages.yml fetches it for the
feed. The highest vX.Y.Z (no pre-release, no draft) goes into
__LATEST_VERSION__, its publish date into __LATEST_DATE__.
"""
import json
import re
import sys


def main() -> None:
    releases_path, page_path = sys.argv[1], sys.argv[2]
    pages = json.load(open(releases_path))
    releases = [r for page in pages for r in (page if isinstance(page, list) else [page])]
    stable = []
    for r in releases:
        m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", r.get("tag_name", ""))
        if m and not r.get("draft") and not r.get("prerelease"):
            stable.append((tuple(map(int, m.groups())), r))
    if not stable:
        sys.exit("no stable release")
    version, release = max(stable, key=lambda x: x[0])
    page = open(page_path).read()
    page = page.replace("__LATEST_VERSION__", ".".join(map(str, version)))
    page = page.replace("__LATEST_DATE__", release["published_at"][:10])
    if "__LATEST_" in page:
        sys.exit("unreplaced placeholder")
    open(page_path, "w").write(page)
    print("stamped", ".".join(map(str, version)), release["published_at"][:10])


if __name__ == "__main__":
    main()
