#!/usr/bin/env python3
"""Stamps the site with the latest stable release and the published reviews.

    stamp_site.py releases.json _site/index.html [--reviews URL-or-file]

releases.json: the GitHub releases API, as pages.yml fetches it for the
feed. The highest vX.Y.Z (no pre-release, no draft) goes into
__LATEST_VERSION__, its publish date into __LATEST_DATE__.

--reviews: GET https://ipsupport.us/api/reviews?product=llmtray (or a saved
answer). The newest reviews are rendered at <!-- REVIEWS -->, and the
structured data gets aggregateRating and a few reviews -- only when there
are some: nothing is made up. Fail-soft: when the reviews can't be read,
the site deploys without them.
"""
import html
import json
import re
import sys
import urllib.request

REVIEWS_PLACEHOLDER = "<!-- REVIEWS -->"
SHOWN_REVIEWS = 10
STRUCTURED_REVIEWS = 5
LD_JSON = re.compile(r'(<script type="application/ld\+json">)(.*?)(</script>)', re.S)
DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
VERSION = re.compile(r"[0-9A-Za-z.+-]{1,32}")


def latest_release(pages):
    releases = [r for page in pages for r in (page if isinstance(page, list) else [page])]
    stable = []
    for r in releases:
        m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", r.get("tag_name", ""))
        if m and not r.get("draft") and not r.get("prerelease"):
            stable.append((tuple(map(int, m.groups())), r))
    if not stable:
        sys.exit("no stable release")
    version, release = max(stable, key=lambda x: x[0])
    return ".".join(map(str, version)), release["published_at"][:10]


def read_reviews(source):
    """The API's answer, from a URL or a file."""
    if re.match(r"https?://", source):
        request = urllib.request.Request(source, headers={"User-Agent": "llmtray-pages", "Accept": "application/json"})
        with urllib.request.urlopen(request, timeout=20) as response:
            if response.status != 200:
                raise ValueError(f"HTTP {response.status}")
            return json.loads(response.read(4 * 1024 * 1024))
    with open(source) as f:
        return json.load(f)


def clean_reviews(feed):
    """(count, average or None, reviews): only well-formed reviews, newest
    first as the API sends them."""
    summary = feed.get("summary") or {}
    count = summary.get("count")
    average = summary.get("average")
    if not isinstance(count, int) or isinstance(count, bool) or count < 0:
        raise ValueError("bad summary.count")
    if not isinstance(average, (int, float)) or isinstance(average, bool) or not 1 <= average <= 5:
        average = None
    reviews = []
    for r in feed.get("reviews") or []:
        if not isinstance(r, dict):
            continue
        rating, text = r.get("rating"), r.get("text")
        if not isinstance(rating, int) or isinstance(rating, bool) or not 1 <= rating <= 5:
            continue
        if not isinstance(text, str) or not text.strip():
            continue
        author = r.get("author") if isinstance(r.get("author"), str) else ""
        version = r.get("version") if isinstance(r.get("version"), str) else ""
        created = r.get("created_at") if isinstance(r.get("created_at"), str) else ""
        reviews.append({
            "rating": rating,
            "text": text.strip(),
            "author": author.strip(),
            "version": version if VERSION.fullmatch(version) else "",
            "date": created[:10] if DATE.match(created) else "",
        })
    return count, average, reviews


def stars(rating):
    return "★" * rating + "☆" * (5 - rating)


def render_section(count, average, reviews):
    if count == 0 or not reviews:
        return ""
    e = html.escape
    lines = ['<section id="reviews">', "      <h2>Reviews</h2>"]
    noun = "review" if count == 1 else "reviews"
    if average is not None:
        lines.append(f'      <p class="reviews-summary"><span class="stars" aria-hidden="true">{stars(int(average + 0.5))}</span> '
                     f"{average:.1f} out of 5 · {count} {noun}</p>")
    else:
        lines.append(f'      <p class="reviews-summary">{count} {noun}</p>')
    lines.append('      <div class="reviews">')
    for r in reviews[:SHOWN_REVIEWS]:
        meta = " · ".join(x for x in (f"LLMTray {e(r['version'])}" if r["version"] else "", e(r["date"])) if x)
        body = e(r["text"]).replace("\n", "<br>")
        lines += [
            '        <div class="card review">',
            f'          <p class="review-head"><span class="stars" aria-label="{r["rating"]} out of 5">{stars(r["rating"])}</span> '
            f"<strong>{e(r['author']) or 'Anonymous'}</strong></p>",
            f"          <p>{body}</p>",
        ]
        if meta:
            lines.append(f'          <p class="review-meta">{meta}</p>')
        lines.append("        </div>")
    lines += ["      </div>", "    </section>"]
    return "\n".join(lines)


def structured(data, count, average, reviews):
    """aggregateRating and a few reviews, only for real ones."""
    if count == 0 or average is None or not reviews:
        return data
    data = dict(data)
    data["aggregateRating"] = {
        "@type": "AggregateRating",
        "ratingValue": round(average, 2),
        "reviewCount": count,
        "bestRating": 5,
        "worstRating": 1,
    }
    items = []
    for r in reviews[:STRUCTURED_REVIEWS]:
        item = {
            "@type": "Review",
            "author": {"@type": "Person", "name": r["author"] or "Anonymous"},
            "reviewRating": {"@type": "Rating", "ratingValue": r["rating"], "bestRating": 5, "worstRating": 1},
            "reviewBody": r["text"],
        }
        if r["date"]:
            item["datePublished"] = r["date"]
        items.append(item)
    data["review"] = items
    return data


def script_json(data):
    """JSON safe inside <script>: no "</script>" or "<!--" can come out of a review."""
    text = json.dumps(data, indent=2, ensure_ascii=False)
    return text.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")


def stamp(page, version, date, feed):
    """The page with the release and, when `feed` (the API's answer) is
    usable, the reviews. Returns (page, how many reviews were rendered)."""
    page = page.replace("__LATEST_VERSION__", version).replace("__LATEST_DATE__", date)
    if "__LATEST_" in page:
        sys.exit("unreplaced placeholder")
    count, average, reviews = 0, None, []
    if feed is not None:
        try:
            count, average, reviews = clean_reviews(feed)
        except (ValueError, AttributeError, TypeError) as error:
            print(f"::warning::reviews not used: {error}")
    blocks = LD_JSON.findall(page)
    if len(blocks) != 1:
        sys.exit(f"expected one ld+json block, found {len(blocks)}")
    data = json.loads(blocks[0][1])
    new = structured(data, count, average, reviews)
    if new is not data:
        rendered = script_json(new)
        if json.loads(rendered) != new:
            sys.exit("structured data doesn't round-trip")
        page = LD_JSON.sub(lambda m: m.group(1) + "\n" + rendered + "\n" + m.group(3), page, count=1)
        json.loads(LD_JSON.search(page).group(2))
    if REVIEWS_PLACEHOLDER not in page:
        sys.exit("no reviews placeholder")
    page = page.replace(REVIEWS_PLACEHOLDER, render_section(count, average, reviews))
    return page, min(len(reviews), SHOWN_REVIEWS) if count else 0


def main() -> None:
    args = sys.argv[1:]
    def option(name):
        if name in args:
            i = args.index(name)
            value = args[i + 1]
            del args[i:i + 2]
            return value
        return None
    source = option("--reviews")
    fallback = option("--reviews-fallback")   # the live site's reviews.json
    feed_out = option("--reviews-out")        # published next to the page
    releases_path, page_path = args
    version, date = latest_release(json.load(open(releases_path)))
    feed = None
    if source:
        try:
            feed = read_reviews(source)
        except Exception as error:
            # Fail-soft, but not blank: the last good feed, as the live site
            # published it, so one failed fetch doesn't drop every review.
            print(f"::warning::reviews not fetched: {error}")
            if fallback:
                try:
                    feed = read_reviews(fallback)
                    print("using the last published reviews")
                except Exception as error2:
                    print(f"::warning::no last published reviews either: {error2}")
    if feed is not None and feed_out:
        json.dump(feed, open(feed_out, "w"))
    page, shown = stamp(open(page_path).read(), version, date, feed)
    open(page_path, "w").write(page)
    print("stamped", version, date, f"reviews shown: {shown}")


if __name__ == "__main__":
    main()
