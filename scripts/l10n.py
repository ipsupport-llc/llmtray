#!/usr/bin/env python3
"""LLMTray localization: one folder per language, English fallback.

    Resources/Localization/<lang>.lproj/Localizable.strings

Keys are the English UI text itself (what SwiftUI's Text("...") /
NSLocalizedString("...") look up), so a string a language doesn't
translate yet simply shows in English. Adding a language = adding a folder
(copy en.lproj, translate the values); build_app.sh picks up every folder
and lists it in CFBundleLocalizations.

    scripts/l10n.py extract   # regenerate en.lproj from the Swift sources
    scripts/l10n.py check     # CI: en.lproj up to date, every file valid,
                              # format specifiers match; missing keys per
                              # language are reported, not an error
    scripts/l10n.py missing <lang>   # list untranslated keys (for translators)
    scripts/l10n.py fix-order        # reordered translations -> positional %1$@
    scripts/l10n.py translate [lang ...] [--model M]
                              # machine-translate missing keys via OpenAI
                              # (OPENAI_API_KEY); a new code creates that
                              # language. Existing entries are kept.

SwiftUI turns an interpolated literal into a format key: "After \\(m) min"
is looked up as "After %lld min" (an Int), "\\(name)" becomes %@ (a String).
The extractor maps each interpolation with a small heuristic (string-ish
expressions -> %@, everything else -> %lld); keep interpolations in UI text
to Ints or plain Strings.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = sorted((ROOT / "Sources" / "LLMTray").glob("*.swift"))
LOC = ROOT / "Resources" / "Localization"
BASE = LOC / "en.lproj" / "Localizable.strings"

# Call sites whose string-literal arguments are localized.
CALL = re.compile(
    r"\b(Text|Toggle|Button|Section|Menu|LabeledContent|Picker|TextField|Label|"
    r"SettingLabel|SettingHelp|NSLocalizedString|row|help|accessibilityLabel)\s*\("
)
STRING_ISH = re.compile(r"(name|Name|Ref\(|lastPathComponent|displayName|title|message|Text|path)")
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def _args(src: str, start: int) -> str:
    """The text of a call's argument list, from `start` (just past "(")."""
    depth, i, in_str = 1, start, False
    while i < len(src) and depth:
        c = src[i]
        if in_str:
            if c == "\\" and i + 1 < len(src) and src[i + 1] == "(":
                # interpolation: skip to its matching paren
                j, d = i + 2, 1
                while j < len(src) and d:
                    d += {"(": 1, ")": -1}.get(src[j], 0)
                    j += 1
                i = j
                continue
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
        i += 1
    return src[start:i - 1]


def _literals(args: str) -> list[str]:
    """Top-level string literals in an argument list, skipping the ones
    that are String(format:) patterns (verbatim, not localized) and
    handling interpolations that contain their own string literals."""
    out, i = [], 0
    while i < len(args):
        if args[i] == '"':
            if args.startswith('"""', i):
                j = args.index('"""', i + 3)
                body = args[i + 3:j].strip("\n")
                body = re.sub(r"\\\n\s*", "", body)  # line continuations
                out.append(("", body))
                i = j + 3
                continue
            j, buf = i + 1, []
            while j < len(args) and args[j] != '"':
                if args.startswith("\\(", j):
                    k, d = j + 2, 1
                    while k < len(args) and d:
                        if args[k] == '"':  # string inside interpolation
                            k = args.index('"', k + 1) + 1
                            continue
                        d += {"(": 1, ")": -1}.get(args[k], 0)
                        k += 1
                    buf.append(args[j:k])
                    j = k
                    continue
                if args[j] == "\\":
                    buf.append(args[j:j + 2])
                    j += 2
                    continue
                buf.append(args[j])
                j += 1
            before = args[max(0, i - 20):i]
            out.append((before, "".join(buf)))
            i = j + 1
            continue
        i += 1
    # String(format:) patterns are verbatim; NSLocalizedString's comment: is
    # for translators, not a key; systemImage:/systemName: are SF Symbols.
    return [lit for before, lit in out
            if not re.search(r"(format|comment|systemImage|systemName):\s*$", before)]


def _unescape(s: str) -> str:
    s = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), s)
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def _to_key(literal: str, explicit: bool = False) -> str | None:
    """`explicit`: from NSLocalizedString, i.e. marked localizable on
    purpose -- then even a lowercase word ("copy") is UI text."""
    out, i = [], 0
    while i < len(literal):
        if literal.startswith("\\(", i):
            j, d = i + 2, 1
            while j < len(literal) and d:
                if literal[j] == '"':
                    j = literal.index('"', j + 1) + 1
                    continue
                d += {"(": 1, ")": -1}.get(literal[j], 0)
                j += 1
            expr = literal[i + 2:j - 1]
            if '"' in expr:  # a conditional inside the key: not a stable key
                return None
            out.append("%@" if STRING_ISH.search(expr) else "%lld")
            i = j
            continue
        out.append(literal[i])
        i += 1
    key = _unescape("".join(out))
    # Not UI text: empty, pure placeholders/format strings, identifiers.
    if not key.strip() or re.fullmatch(r"[\s%@lldf.\d/→·()x,:-]*", key):
        return None
    if key.startswith(("llmtray.", "http", "/")) or (not explicit and re.fullmatch(r"[a-z_]+", key)):
        return None
    if re.fullmatch(r"[a-z0-9]+(\.[a-z0-9]+)+", key) or len(key.strip()) < 2:  # SF Symbol names, "★", "…"
        return None
    return key


CONTEXT = {
    "Text": "label", "Toggle": "checkbox label", "Button": "button", "Section": "section header",
    "Menu": "menu", "LabeledContent": "setting label", "Picker": "setting label / option",
    "TextField": "text field placeholder", "Label": "label", "SettingLabel": "setting title or its tooltip",
    "SettingHelp": "tooltip explaining a setting", "NSLocalizedString": "dialog / menu text",
    "row": "profile setting title or its tooltip", "help": "tooltip",
    "accessibilityLabel": "VoiceOver label",
}


def extract_with_context() -> dict[str, str]:
    """key -> where it appears (a hint for translators and the MT prompt)."""
    keys: dict[str, str] = {}
    for f in SOURCES:
        src = f.read_text()
        for m in CALL.finditer(src):
            for lit in _literals(_args(src, m.end())):
                key = _to_key(lit, explicit=m.group(1) == "NSLocalizedString")
                if key:
                    keys.setdefault(key, CONTEXT.get(m.group(1), "UI text"))
    return keys


def extract() -> list[str]:
    return sorted(extract_with_context())


def _escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def write_base(keys: list[str]) -> None:
    BASE.parent.mkdir(parents=True, exist_ok=True)
    body = ["/* Generated by scripts/l10n.py extract -- the English base (keys are the English text). */", ""]
    body += [f'"{_escape(k)}" = "{_escape(k)}";' for k in keys]
    BASE.write_text("\n".join(body) + "\n", encoding="utf-8")


def load(path: Path) -> dict[str, str]:
    """Parse a .strings file via plutil (the same parser Foundation uses)."""
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise ValueError(f"{path}: {out.stderr.strip()}")
    import json
    return json.loads(out.stdout)


SPEC = re.compile(r"%(?:(\d+)\$)?(lld|ld|d|@|lf|f|\.\d+f)")


def specifiers(s: str) -> list[str]:
    return [m.group(0) for m in SPEC.finditer(s)]


def _kind(conv: str) -> str:
    # %d is 32-bit, %ld / %lld 64-bit: a translation mustn't narrow one.
    if conv == "@":
        return "object"
    if conv.endswith("d"):
        return "int32" if conv == "d" else "int64"
    return "float"


def arguments(s: str) -> dict[int, str] | None:
    """Argument position -> kind (object / int / float), as String(format:)
    reads them: plain specifiers take positions 1, 2, ... in order,
    positional ones (%2$@) say theirs. None for a mix of the two, which
    Foundation doesn't support. A translation must read the same arguments
    as its key -- only comparing the specifiers, sorted, let a reordered
    "%d ... %@" -> "%@ ... %d" through, and String(format:) then reads an
    Int as an object: a crash."""
    found = list(SPEC.finditer(s))
    if not found:
        return {}
    positional = [m.group(1) is not None for m in found]
    if any(positional) and not all(positional):
        return None
    if all(positional):
        out: dict[int, str] = {}
        for m in found:
            pos, kind = int(m.group(1)), _kind(m.group(2))
            if out.setdefault(pos, kind) != kind:
                return None
        return out
    return {i + 1: _kind(m.group(2)) for i, m in enumerate(found)}


def reorder_fix(key: str, value: str) -> str | None:
    """A translation that reorders plain specifiers of different kinds,
    rewritten with positions ("%@ ... %d" for key "%d ... %@" becomes
    "%2$@ ... %1$d"); None if that can't be decided."""
    want, have = arguments(key), arguments(value)
    if want is None or have is None or want == have or sorted(want.values()) != sorted(have.values()):
        return None
    if any(m.group(1) for m in SPEC.finditer(value)):
        return None
    free = sorted(want)
    out, last = [], 0
    for m in SPEC.finditer(value):
        kind = _kind(m.group(2))
        pos = next((p for p in free if want[p] == kind), None)
        if pos is None:
            return None
        free.remove(pos)
        out.append(value[last:m.start()] + f"%{pos}${m.group(2)}")
        last = m.end()
    fixed = "".join(out) + value[last:]
    return fixed if arguments(fixed) == want else None


def languages() -> list[Path]:
    return sorted(p for p in LOC.glob("*.lproj") if p.name != "en.lproj")


def check() -> int:
    errors = 0
    code_keys = extract()
    try:
        base = load(BASE)
    except (ValueError, FileNotFoundError) as e:
        print(f"error: {e}")
        return 1
    stale = sorted(set(code_keys) - set(base))
    if stale:
        errors += 1
        print(f"error: en.lproj is missing {len(stale)} key(s) used in the code -- run scripts/l10n.py extract:")
        for k in stale[:20]:
            print(f"   {k!r}")
    for lang in languages():
        f = lang / "Localizable.strings"
        try:
            table = load(f)
        except ValueError as e:
            errors += 1
            print(f"error: {e}")
            continue
        unknown = sorted(set(table) - set(base))
        bad = [k for k, v in table.items() if k in base and arguments(k) != arguments(v)]
        missing = sorted(set(base) - set(table))
        for k in bad:
            errors += 1
            print(f"error: {lang.name}: format specifiers differ for {k!r} -> {table[k]!r}")
        print(f"{lang.name}: {len(table) - len(unknown)}/{len(base)} translated"
              + (f", {len(missing)} missing (shown in English)" if missing else "")
              + (f", {len(unknown)} obsolete key(s)" if unknown else ""))
    return 1 if errors else 0


# ---------------------------------------------------------------- translate

GLOSSARY = ["LLMTray", "MLX", "mlx-lm", "mlx_lm.server", "KV", "MTP", "Top-k", "Top-p", "GPU",
            "API", "Hugging Face", "LM Studio", "Z-Image-Turbo", "Gemma", "Default", "Stable",
            "Beta", "JSON", "Finder", "Play", "DEBUG", "generate_image", "OpenAI"]


def _lang_name(code: str) -> str:
    names = {"ru": "Russian", "uk": "Ukrainian", "es": "Spanish", "de": "German", "fr": "French",
             "it": "Italian", "pt": "Portuguese", "pt-BR": "Brazilian Portuguese", "pl": "Polish",
             "ja": "Japanese", "ko": "Korean", "zh-Hans": "Simplified Chinese", "zh-Hant": "Traditional Chinese",
             "tr": "Turkish", "nl": "Dutch", "cs": "Czech", "sv": "Swedish", "he": "Hebrew", "ar": "Arabic",
             "hi": "Hindi", "vi": "Vietnamese", "id": "Indonesian", "th": "Thai"}
    return names.get(code, code)


def _openai(messages: list[dict], model: str, key: str) -> str:
    import json, os, time, urllib.request, urllib.error
    req_body = {"model": model, "messages": messages, "response_format": {"type": "json_object"}}
    # Reasoning models (gpt-5.x, o-series) reject a custom temperature --
    # and bill their hidden reasoning as output tokens. Translating UI
    # strings needs next to none: minimal effort (the first full run on
    # gpt-5.5 at default effort cost dollars for ~9k characters of text).
    if model.startswith("gpt-5"):
        req_body["reasoning_effort"] = "minimal"
    elif model.startswith(("o1", "o3", "o4")):
        req_body["reasoning_effort"] = "low"
    else:
        req_body["temperature"] = 0.2
    body = json.dumps(req_body).encode()
    for attempt in range(5):
        base = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1").rstrip("/")
        req = urllib.request.Request(f"{base}/chat/completions", body,
                                     {"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                return json.load(r)["choices"][0]["message"]["content"]
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503) and attempt < 4:
                time.sleep(2 ** attempt * 3)
                continue
            raise RuntimeError(f"OpenAI HTTP {e.code}: {e.read().decode()[:300]}")
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            # A dropped connection or a timeout: transient, retry too.
            if attempt < 4:
                time.sleep(2 ** attempt * 3)
                continue
            raise RuntimeError(f"OpenAI request failed: {e}")
    raise RuntimeError("OpenAI: out of retries")


def _valid(key: str, value: str) -> str | None:
    """Why a translation is unusable, or None."""
    if not value.strip():
        return "empty"
    if arguments(key) != arguments(value):
        fixed = reorder_fix(key, value)
        if fixed is None:
            return f"format specifiers {specifiers(key)} vs {specifiers(value)}"
    if len(value) > max(40, 3 * len(key)):
        return "far longer than the English"
    return None


def write_lang(code: str, table: dict[str, str], base_keys: list[str]) -> Path:
    path = LOC / f"{code}.lproj" / "Localizable.strings"
    path.parent.mkdir(parents=True, exist_ok=True)
    header = [f"/* {_lang_name(code)}. Keys are the English text (en.lproj); a key missing here shows in English.",
              "   Missing keys are machine-translated by scripts/l10n.py translate (OpenAI); fixes by native",
              "   speakers are welcome -- existing entries are never overwritten. */", ""]
    lines = [f'"{_escape(k)}" = "{_escape(table[k])}";' for k in base_keys if k in table]
    path.write_text("\n".join(header + lines) + "\n", encoding="utf-8")
    return path


def translate(codes: list[str], model: str, batch: int = 100) -> int:
    """Fills in each language's missing keys; drops keys no longer in the
    English base (a changed English string is a new key). Never touches an
    existing translation. Batches run in parallel (L10N_JOBS, default 8):
    one at a time, a run adding many languages took over an hour."""
    import json, os, threading
    from concurrent.futures import ThreadPoolExecutor
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        print("error: OPENAI_API_KEY is not set")
        return 1
    ctx = extract_with_context()
    base_keys = sorted(load(BASE))
    tables: dict[str, dict[str, str]] = {}
    jobs: list[tuple[str, list[str]]] = []
    for code in codes:
        path = LOC / f"{code}.lproj" / "Localizable.strings"
        table = load(path) if path.exists() else {}
        tables[code] = {k: v for k, v in table.items() if k in base_keys}  # prune obsolete
        todo = [k for k in base_keys if k not in tables[code]]
        print(f"{code}: {len(todo)} to translate", flush=True)
        jobs += [(code, todo[i:i + batch]) for i in range(0, len(todo), batch)]
        write_lang(code, tables[code], base_keys)  # creates new languages, prunes
    lock = threading.Lock()
    failed = 0

    def system_prompt(lang: str) -> str:
        return (
            f"You translate the UI of LLMTray, a macOS menu-bar app for running local LLMs, from English "
            f"into {lang}. Write natural, concise {lang} as used in macOS system UI (System Settings wording). "
            f"Rules: keep every format specifier (%@, %lld, %d, %1$@...) exactly, in a grammatical position; "
            f"keep these terms untranslated: {', '.join(GLOSSARY)}; keep technical flags, file paths, URLs and "
            f"<placeholders> as they are; use the same typographic quotes style natural for {lang}; tooltips "
            f"are full sentences, labels and buttons short. Reply with a JSON object mapping each English "
            f"string (exactly as given) to its translation."
        )

    def run(job: tuple[str, list[str]]) -> None:
        nonlocal failed
        code, chunk = job
        system = system_prompt(_lang_name(code))
        items = [{"text": k, "where": ctx.get(k, "UI text")} for k in chunk]
        pending, done = chunk, {}
        for attempt in range(2):
            try:
                reply = json.loads(_openai([
                    {"role": "system", "content": system},
                    {"role": "user", "content": json.dumps([it for it in items if it["text"] in pending], ensure_ascii=False)},
                ], model, key))
            except Exception as e:  # one bad batch must not lose the rest
                print(f"  {code}: request failed ({e}), attempt {attempt + 1}", flush=True)
                reply = {}
            retry = []
            for k in pending:
                v = reply.get(k)
                why = _valid(k, v) if isinstance(v, str) else "missing in reply"
                if why:
                    retry.append(k)
                    if attempt == 1:
                        with lock:
                            failed += 1
                        print(f"  {code}: left in English ({why}): {k[:70]!r}", flush=True)
                else:
                    # A reordered translation gets positional specifiers.
                    done[k] = reorder_fix(k, v) or v
            pending = retry
            if not pending:
                break
        with lock:
            tables[code].update(done)
            write_lang(code, tables[code], base_keys)  # save as we go

    with ThreadPoolExecutor(max_workers=int(os.environ.get("L10N_JOBS", "8"))) as pool:
        list(pool.map(run, jobs))
    for code in codes:
        print(f"{code}: {sum(k in tables[code] for k in base_keys)}/{len(base_keys)}")
    return 0


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    if cmd == "extract":
        keys = extract()
        write_base(keys)
        print(f"wrote {BASE.relative_to(ROOT)}: {len(keys)} keys")
        return 0
    if cmd == "check":
        return check()
    if cmd == "translate":
        import argparse, os
        ap = argparse.ArgumentParser(prog="l10n.py translate")
        ap.add_argument("languages", nargs="*", help="language codes (default: every existing one)")
        ap.add_argument("--model", default=os.environ.get("OPENAI_MODEL") or "gpt-5-mini")
        a = ap.parse_args(sys.argv[2:])
        codes = a.languages or [p.name.removesuffix(".lproj") for p in languages()]
        return translate(codes, a.model)
    if cmd == "import-missing":
        # Keys an open proposal (<dir>/<lang>.lproj) translated that this
        # tree still lacks -- never overwriting what's here.
        src = Path(sys.argv[2])
        base_keys = sorted(load(BASE))
        for lang in sorted(src.glob("*.lproj")):
            theirs = lang / "Localizable.strings"
            if not theirs.exists():
                continue
            code = lang.name.removesuffix(".lproj")
            mine_path = LOC / lang.name / "Localizable.strings"
            mine = load(mine_path) if mine_path.exists() else {}
            added = {k: v for k, v in load(theirs).items() if k not in mine and k in base_keys and _valid(k, v) is None}
            if added:
                mine.update(added)
                write_lang(code, mine, base_keys)
                print(f"{lang.name}: {len(added)} from the open proposal")
        return 0
    if cmd == "fix-order":
        # Rewrites reordered translations with positional specifiers.
        base_keys = sorted(load(BASE))
        for lang in languages():
            table = load(lang / "Localizable.strings")
            changed = {k: f for k, v in table.items() if (f := reorder_fix(k, v))}
            if changed:
                table.update(changed)
                write_lang(lang.name.removesuffix(".lproj"), table, base_keys)
                for k, v in changed.items():
                    print(f"{lang.name}: {k!r} -> {v!r}")
        return 0
    if cmd == "missing":
        lang = LOC / f"{sys.argv[2]}.lproj" / "Localizable.strings"
        table = load(lang) if lang.exists() else {}
        for k in sorted(set(load(BASE)) - set(table)):
            print(f'"{_escape(k)}" = "{_escape(k)}";')
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
