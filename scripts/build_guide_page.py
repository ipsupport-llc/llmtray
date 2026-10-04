#!/usr/bin/env python3
"""Builds docs/guide.html from runtime/LLMTray Guide.md -- the guide the app
ships (and adds to the Getting Started project), published on the website
too. The page takes privacy.html's styles, so the site stays one look.

Run after editing the guide:  python3 scripts/build_guide_page.py
CI runs it with --check and fails when docs/guide.html is out of date.
"""
import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUIDE = ROOT / "runtime" / "LLMTray Guide.md"
STYLE_FROM = ROOT / "docs" / "privacy.html"
OUT = ROOT / "docs" / "guide.html"

EXTRA_CSS = """
  .page h3 { font-size: 1.05rem; margin-top: 1.6rem; }
  li code {
    background: var(--card);
    border: 1px solid var(--border);
    padding: 0.1rem 0.4rem;
    border-radius: 5px;
    font-size: 0.88em;
  }
  .toc { columns: 2; padding-left: 1.2rem; color: var(--fg-muted); }
  @media (max-width: 560px) { .toc { columns: 1; } }
  .toc a { color: inherit; }
  .page a { color: var(--accent); }
  footer a { color: inherit; }
"""


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def inline(text):
    """`code`, **bold**, and bare e-mail addresses; everything else escaped."""
    parts = re.split(r"(`[^`]+`)", text)
    out = []
    for part in parts:
        if part.startswith("`") and part.endswith("`") and len(part) > 1:
            out.append("<code>" + html.escape(part[1:-1]) + "</code>")
            continue
        s = html.escape(part, quote=False)
        s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"\b([\w.+-]+@[\w-]+\.[\w.]+)\b", r"<code>\1</code>", s)
        out.append(s)
    return "".join(out)


def convert(md):
    """The guide's Markdown: #/##/### headings, paragraphs, - and 1. lists
    (items continued on indented lines). Returns (title, intro, toc, body)."""
    lines = md.splitlines()
    title, blocks, toc = "", [], []
    para, items, kind = [], [], None

    def flush():
        nonlocal para, items, kind
        if para:
            blocks.append("<p>" + inline(" ".join(para)) + "</p>")
            para = []
        if items:
            tag = "ol" if kind == "ol" else "ul"
            blocks.append(f"<{tag}>\n" + "\n".join(f"      <li>{inline(i)}</li>" for i in items) + f"\n    </{tag}>")
            items, kind = [], None

    for line in lines:
        if line.startswith("# "):
            flush()
            title = line[2:].strip()
        elif line.startswith("## ") or line.startswith("### "):
            flush()
            level = 2 if line.startswith("## ") else 3
            text = line[level + 1:].strip()
            anchor = slug(text)
            if level == 2:
                toc.append((anchor, text))
            blocks.append(f'<h{level} id="{anchor}">{inline(text)}</h{level}>')
        elif m := re.match(r"^(-|\d+\.) (.*)$", line):
            if para:
                flush()
            new_kind = "ul" if m.group(1) == "-" else "ol"
            if kind and kind != new_kind:
                flush()
            kind = new_kind
            items.append(m.group(2).strip())
        elif line.startswith("  ") and items and line.strip():
            items[-1] += " " + line.strip()
        elif not line.strip():
            flush()
        else:
            if items:
                flush()
            para.append(line.strip())
    flush()
    # The paragraph(s) before the first section are the page's intro.
    first = next(i for i, b in enumerate(blocks) if b.startswith("<h2"))
    return title, blocks[:first], toc, blocks[first:]


def build():
    title, intro, toc, body = convert(GUIDE.read_text(encoding="utf-8"))
    style = re.search(r"<style>(.*?)</style>", STYLE_FROM.read_text(encoding="utf-8"), re.S).group(1)
    toc_html = "\n".join(f'      <li><a href="#{a}">{html.escape(t)}</a></li>' for a, t in toc)
    content = "\n\n    ".join(intro + [f'<ul class="toc">\n{toc_html}\n    </ul>'] + body)
    return f"""<!doctype html>
<!-- Generated from runtime/LLMTray Guide.md by scripts/build_guide_page.py: edit the guide, not this page. -->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LLMTray — Guide</title>
<meta name="description" content="How to use LLMTray: models, chat, projects and files, tools, images, music, voice, and connecting coding agents and apps to its OpenAI-compatible API.">
<link rel="canonical" href="https://ipsupport-llc.github.io/llmtray/guide.html">
<meta name="theme-color" content="#0d2818">
<link rel="icon" type="image/png" sizes="32x32" href="assets/favicon-32.png">
<link rel="apple-touch-icon" href="assets/apple-touch-icon.png">
<style>{style}{EXTRA_CSS}</style>
</head>
<body>
  <div class="wrap page">
    <h1>{html.escape(title)}</h1>
    <p class="meta">The same guide is in the app: ask about LLMTray in the Getting Started project.</p>

    {content}

    <footer>
      <a href="./">LLMTray</a> · <a href="guide.html">Guide</a> · <a href="privacy.html">Privacy</a> · <a href="support.html">Support</a> · made by <a href="https://github.com/ipsupport-llc">IP Support</a>
    </footer>
  </div>
</body>
</html>
"""


if __name__ == "__main__":
    page = build()
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != page:
            sys.exit("docs/guide.html is out of date: run python3 scripts/build_guide_page.py")
    else:
        OUT.write_text(page, encoding="utf-8")
