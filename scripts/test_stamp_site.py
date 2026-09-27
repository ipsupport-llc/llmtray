#!/usr/bin/env python3
"""Offline checks for stamp_site.py (run by CI's release dry run)."""
import json
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import stamp_site as ss  # noqa: E402

PAGE = (Path(__file__).parent.parent / "docs" / "index.html").read_text()
failures = 0


def check(cond, what):
    global failures
    if not cond:
        failures += 1
        print("FAIL:", what)


def ld(page):
    return json.loads(ss.LD_JSON.search(page).group(2))


def review(i, rating=5, text="Great", author="", created="2026-09-20T10:00:00Z", version="0.7.1"):
    return {"id": f"r{i}", "rating": rating, "text": text, "version": version, "author": author, "created_at": created}


# No reviews: nothing rendered, no rating in the structured data.
page, shown = ss.stamp(PAGE, "0.7.1", "2026-09-01", {"summary": {"count": 0, "average": None}, "reviews": []})
check(shown == 0 and "<!-- REVIEWS -->" not in page and 'id="reviews"' not in page, "empty: no section")
data = ld(page)
check("aggregateRating" not in data and "review" not in data, "empty: no aggregateRating")
check(data["softwareVersion"] == "0.7.1" and data["dateModified"] == "2026-09-01", "release stamped")

# Fetch failed (feed None) or garbage: same as none.
for feed in (None, {"summary": "x"}, [], {"summary": {"count": "3"}}):
    page, shown = ss.stamp(PAGE, "0.7.1", "2026-09-01", feed)
    check(shown == 0 and "aggregateRating" not in ld(page) and "<!-- REVIEWS -->" not in page, f"fail-soft {feed!r}")

# Reviews: escaped, anonymous, newest first, 10 shown; 5 in the structured data.
evil = '</script><script>alert(1)</script> & <b>"x"</b>\nline two'
reviews = [review(0, 4, evil, author="<Ann>"), review(1, 5, "Nice", author="")] + [review(i) for i in range(2, 14)]
reviews.append({"id": "bad", "rating": 9, "text": "x"})
page, shown = ss.stamp(PAGE, "0.7.1", "2026-09-01", {"summary": {"count": 14, "average": 4.9286}, "reviews": reviews})
check(shown == 10, f"10 shown, got {shown}")
section = page[page.index('<section id="reviews">'):]
section = section[:section.index("</section>")]
check(section.count('class="card review"') == 10, "10 cards")
check("<script>alert" not in page and "&lt;/script&gt;" in section, "text escaped in HTML")
check("<br>line two" in section, "newlines as <br>")
check("<strong>&lt;Ann&gt;</strong>" in section and "<strong>Anonymous</strong>" in section, "author / Anonymous")
check("4.9 out of 5 · 14 reviews" in section, "summary line")
check("★★★★☆" in section and "LLMTray 0.7.1 · 2026-09-20" in section, "stars and meta")
check(section.index("&lt;Ann&gt;") < section.index("Anonymous"), "newest first")
data = ld(page)
check(data["aggregateRating"] == {"@type": "AggregateRating", "ratingValue": 4.93, "reviewCount": 14,
                                  "bestRating": 5, "worstRating": 1}, "aggregateRating")
check(len(data["review"]) == 5, "5 structured reviews")
check(data["review"][0]["reviewBody"] == evil.strip() and data["review"][0]["author"]["name"] == "<Ann>", "review body kept")
check(data["review"][1]["author"] == {"@type": "Person", "name": "Anonymous"}, "anonymous person")
check(data["review"][0]["reviewRating"]["ratingValue"] == 4 and data["review"][0]["datePublished"] == "2026-09-20", "rating, date")
block = ss.LD_JSON.search(page).group(2)
check("</" not in block and "<" not in block, "no markup inside the ld+json script")
check(data["name"] == "LLMTray" and data["offers"]["price"] == "0", "rest of the structured data kept")

# A count with no average: listed, but no aggregateRating (nothing computed).
page, shown = ss.stamp(PAGE, "0.7.1", "2026-09-01", {"summary": {"count": 1, "average": None}, "reviews": [review(0)]})
check(shown == 1 and "aggregateRating" not in ld(page) and "1 review</p>" in page, "no average: no aggregateRating")

# End to end, from a file and from an unreachable URL.
with tempfile.TemporaryDirectory() as d:
    releases = Path(d, "releases.json")
    releases.write_text(json.dumps([[{"tag_name": "v0.7.1", "published_at": "2026-09-01T00:00:00Z"},
                                     {"tag_name": "v0.8.0-beta.1", "prerelease": True, "published_at": "2026-09-10T00:00:00Z"}]]))
    feed = Path(d, "reviews.json")
    feed.write_text(json.dumps({"summary": {"count": 1, "average": 5}, "reviews": [review(0, text="Solid")]}))
    for source, expect in ((str(feed), True), ("http://127.0.0.1:9/api/reviews", False)):
        index = Path(d, "index.html")
        index.write_text(PAGE)
        sys.argv = ["stamp_site.py", str(releases), str(index), "--reviews", source]
        ss.main()
        out = index.read_text()
        check(("Solid" in out) == expect and ("aggregateRating" in ld(out)) == expect, f"main with {source}")
        check(re.search(r'"softwareVersion": "0\.7\.1"', out) is not None, "main stamps the release")

if failures:
    sys.exit(f"{failures} check(s) failed")
print("stamp_site: all checks passed")
