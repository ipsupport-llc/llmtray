# Russian stress marks for Chatterbox's spoken answers (adr/0016), from
# ruaccent (MIT) in its tiny mode only: the full mode imports Koziev's
# rupostagger (GPL-3.0), so ruaccent is installed with --no-deps and only
# its own modules are imported. The AGPL russian_text_stresser that
# mlx-audio's chatterbox would use is never installed (the TTS runner
# blocks its import).
#
#   python llmtray_ru_stress.py build <dir>     # fetch the pinned files, build the dictionary
#   python llmtray_ru_stress.py mark <dir> "Чем могу помочь?"
#   python llmtray_ru_stress.py --selftest      # no files: the rules and the hash dictionary
#
# The accents dictionary (3.19M words) is kept as a sorted array of 64-bit
# word hashes plus the stress position (~28 MB instead of ~1.8 GB as a
# Python dict). The ONNX models run only where the dictionary can't answer:
# tiny2.1 for homographs, the е/ё resolver only when a ё-homograph is in
# the sentence, nn_accent for unknown words. A few context rules fix
# homographs every ruaccent model got wrong in assistant phrases, and a word
# nobody stresses gets the basic rules (rule_stress).
import gzip
import hashlib
import json
import os
import re
import shutil
import sys
import urllib.request

REPO = "ruaccent/accentuator"
REV = "b78ae5ea1e62beaf138bed1865cd8c3b0b5ca855"   # MIT, checked 2026-11-06
DICTIONARIES = ["dictionary/accents.json.gz", "dictionary/omographs.json.gz",
                "dictionary/yo_words.json.gz", "dictionary/yo_homographs.json.gz"]
MODELS = {
    "nn/nn_accent": ["model.onnx", "config.json", "special_tokens_map.json", "tokenizer_config.json", "vocab.txt"],
    "nn/nn_omograph/tiny2.1": ["model.onnx", "config.json", "added_tokens.json", "special_tokens_map.json",
                               "tokenizer.json", "tokenizer_config.json", "vocab.txt"],
    "nn/nn_yo_homograph_resolver": ["model.onnx", "config.json", "special_tokens_map.json", "tokenizer.json",
                                    "tokenizer_config.json", "vocab.txt"],
}
# Written last by `build`: its presence means the folder is complete.
STAMP = "llmtray-ru-stress.json"

VOWELS = "аеёиоуыэюяАЕЁИОУЫЭЮЯ"
_PLUS_VOWEL = re.compile(r"\+([" + VOWELS + r"])")


def files():
    out = list(DICTIONARIES)
    for folder, names in MODELS.items():
        out += [folder + "/" + n for n in names]
    return out


def word_hash(word):
    return int.from_bytes(hashlib.blake2b(word.encode("utf-8"), digest_size=8).digest(), "little")


def is_complete(folder):
    return os.path.exists(os.path.join(folder, STAMP))


# MARK: build

def fetch(folder, progress=None):
    names = [f for f in files() if not (f == "dictionary/accents.json.gz" and os.path.exists(os.path.join(folder, "accents.npz")))]
    for i, name in enumerate(names):
        dst = os.path.join(folder, name)
        if os.path.exists(dst):
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        url = "https://huggingface.co/%s/resolve/%s/%s" % (REPO, REV, name)
        with urllib.request.urlopen(url, timeout=120) as r, open(dst + ".part", "wb") as fh:
            shutil.copyfileobj(r, fh, 1 << 22)
        os.replace(dst + ".part", dst)
        if progress:
            progress(i + 1, len(names))


def build(folder):
    """accents.json.gz -> accents.npz (sorted hashes + stress position) and
    accents_overlay.json (words the array can't hold: several stresses, a
    changed spelling, a hash shared with another word)."""
    import numpy as np
    source = os.path.join(folder, "dictionary", "accents.json.gz")
    if os.path.exists(source):
        with gzip.open(source) as f:
            accents = json.load(f)
        keys, pos, overlay = [], [], {}
        for word, form in accents.items():
            if form.count("+") == 1 and form.replace("+", "") == word and form.index("+") < 255:
                keys.append(word_hash(word))
                pos.append(form.index("+"))
            else:
                overlay[word] = form
        keys = np.array(keys, np.uint64)
        pos = np.array(pos, np.uint8)
        order = np.argsort(keys, kind="stable")
        keys, pos = keys[order], pos[order]
        # Two words with one hash: both go to the overlay, so a lookup never
        # answers for the wrong word.
        dup = np.zeros(len(keys), bool)
        dup[1:] |= keys[1:] == keys[:-1]
        dup[:-1] |= keys[1:] == keys[:-1]
        if dup.any():
            colliding = set(keys[dup].tolist())
            for word, form in accents.items():
                if word_hash(word) in colliding:
                    overlay[word] = form
            keys, pos = keys[~dup], pos[~dup]
        tmp = os.path.join(folder, "accents.tmp.npz")
        np.savez(tmp, keys=keys, pos=pos)
        os.replace(tmp, os.path.join(folder, "accents.npz"))
        with open(os.path.join(folder, "accents_overlay.json"), "w", encoding="utf-8") as f:
            json.dump(overlay, f, ensure_ascii=False)
        os.remove(source)   # the npz replaces it
    # Complete only with every file in place and the dictionary readable.
    missing = [f for f in files() if f != "dictionary/accents.json.gz" and not os.path.exists(os.path.join(folder, f))]
    if missing:
        raise SystemExit("missing: " + ", ".join(missing))
    HashDict.load(folder)
    with open(os.path.join(folder, STAMP), "w") as f:
        json.dump({"repo": REPO, "revision": REV}, f)


# MARK: lookup

class HashDict:
    """word -> word with '+' before the stressed vowel: the get() ruaccent
    calls on its accents dictionary."""

    def __init__(self, keys, pos, overlay):
        self.keys, self.pos, self.overlay = keys, pos, overlay

    @classmethod
    def load(cls, folder):
        import numpy as np
        z = np.load(os.path.join(folder, "accents.npz"))
        with open(os.path.join(folder, "accents_overlay.json"), encoding="utf-8") as f:
            overlay = json.load(f)
        return cls(z["keys"], z["pos"], overlay)

    def get(self, word, default=None):
        import numpy as np
        v = self.overlay.get(word)
        if v is not None:
            return v
        h = np.uint64(word_hash(word))
        i = int(np.searchsorted(self.keys, h))
        if i < len(self.keys) and self.keys[i] == h:
            p = int(self.pos[i])
            return word[:p] + "+" + word[p:]
        return default

    def __contains__(self, word):
        return self.get(word) is not None

    def update(self, d):
        self.overlay.update(d)


# Homographs every ruaccent model got wrong in assistant phrases:
# (word, stressed form, regex on the lowercased plain text before the word,
# regex on the text after it; either may be None).
RULES = [
    ("замок", "зам+ок",
     r"(двер|ключ|слома|открыт|закрыт|навесн|кодов|электронн|сейф|калитк|ворот)\w*\W+(\w+\W+)?$",
     r"^\W+((на|в|от)\s+двер|двер|сломал|не\s+работ|заел|не\s+открыва|не\s+закрыва|открыва|закрыва|ключ)"),
    ("плачу", "плач+у", None,
     r"^\s+(за|по|вам|налог|кредит|ипотек|наличн|картой|сч[её]т|штраф|аренд|деньги|в\s+месяц|каждый)"),
    ("положите", "полож+ите", r"(^|[.!?,:;]\s*|пожалуйста\W+)$", None),
    ("оплатите", "оплат+ите", r"(^|[.!?,:;]\s*|пожалуйста\W+|\w+\s+)$", None),
]


def apply_rules(marked):
    """Rewrites each rule word whose context matches, in ruaccent's '+' form."""
    for word, stressed, before, after in RULES:
        pattern = re.compile(r"(?<![\w+])" + r"\+?".join(map(re.escape, word)) + r"(?![\w+])", re.IGNORECASE)
        pieces, last = [], 0
        for m in pattern.finditer(marked):
            ctx_before = marked[:m.start()].replace("+", "").lower()[-60:]
            ctx_after = marked[m.end():].replace("+", "").lower()[:60]
            hit = (before is not None and re.search(before, ctx_before)) or \
                  (after is not None and re.search(after, ctx_after))
            # "вы положите" / "вы оплатите" is the future, not the imperative.
            if hit and not (word in ("положите", "оплатите") and re.search(r"\bвы\s+$", ctx_before)):
                original = m.group(0).replace("+", "")
                rep = stressed[0].upper() + stressed[1:] if original[:1].isupper() else stressed
                pieces += [marked[last:m.start()], rep]
                last = m.end()
        marked = "".join(pieces) + marked[last:]
    return marked


# Suffixes with fixed stress: (ending, which of its vowels is stressed).
RULE_SUFFIXES = (("ация", 0), ("яция", 0), ("иция", 0), ("уция", 0), ("ирование", 0), ("ировать", 0),
                 ("ированный", 0), ("ирует", 0), ("ируют", 0), ("ирую", 0), ("изм", 0), ("истка", 0), ("ист", 0))


def rule_stress(word):
    """'+' before the vowel the basic rules stress, for a word the dictionary
    and the model left alone: ё is always stressed; a few suffixes carry
    fixed stress; otherwise the next-to-last syllable. One-vowel words stay
    as they are."""
    vowels = [i for i, ch in enumerate(word) if ch in VOWELS]
    if len(vowels) < 2:
        return word
    low = word.lower()
    if "ё" in low:
        at = low.index("ё")
    else:
        at = None
        for ending, k in RULE_SUFFIXES:
            if low.endswith(ending) and len(low) > len(ending):
                start = len(low) - len(ending)
                inner = [i for i in vowels if i >= start]
                if len(inner) > k:
                    at = inner[k]
                    break
        if at is None:
            at = vowels[-2]
    return word[:at] + "+" + word[at:]


def to_acute(plus_text):
    """ruaccent's '+' form -> Chatterbox's: U+0301 after the stressed vowel;
    none on one-vowel words, and in a hyphenated word only on its last part.
    A Cyrillic word without a mark gets rule_stress first."""
    marked = re.sub(r"[А-Яа-яЁё+]+",
                    lambda m: m.group(0) if "+" in m.group(0) else rule_stress(m.group(0)), plus_text)

    def per_word(m):
        parts = m.group(0).split("-")
        return "-".join(p.replace("+", "") if sum(ch in VOWELS for ch in p) <= 1 or i < len(parts) - 1 else p
                        for i, p in enumerate(parts))
    marked = re.sub(r"[\w+]+(?:-[\w+]+)*", per_word, marked)
    # ё is always stressed: no mark after it.
    return _PLUS_VOWEL.sub(lambda m: m.group(1) + ("" if m.group(1) in "ёЁ" else "\u0301"), marked).replace("+", "")


class RuStress:
    def __init__(self, folder):
        import numpy as np
        import onnxruntime as ort
        from ruaccent import RUAccent          # import only: load() would fetch the whole repository
        _zero_fill_missing_inputs(ort, np)
        ra = RUAccent()
        ra.tiny_mode, ra.workdir, ra.custom_dict = True, folder, {}
        ra.accents = HashDict.load(folder)
        ra.accents.update(ra.letters_accent)

        def gz(name):
            with gzip.open(os.path.join(folder, "dictionary", name)) as f:
                return json.load(f)
        ra.omographs = gz("omographs.json.gz")
        ra.omographs.update({"коса": ["к+оса", "кос+а"]})
        ra.omograph_model.load(os.path.join(folder, "nn", "nn_omograph", "tiny2.1"))
        ra.yo_words = gz("yo_words.json.gz")
        ra.yo_homographs = gz("yo_homographs.json.gz")
        ra.yo_homograph_model.load(os.path.join(folder, "nn", "nn_yo_homograph_resolver"))
        ra.accent_model.load(os.path.join(folder, "nn", "nn_accent"))
        yo_keys = set(ra.yo_homographs)
        full_yo = ra._process_yo

        def process_yo(words, sentence):
            # ruaccent runs the е/ё model on every sentence with an "е";
            # only ё-homographs need it.
            if any(w.lower() in yo_keys for w in words):
                return full_yo(words, sentence)
            from ruaccent.text_postprocessor import fix_capital
            return [fix_capital(w, ra.yo_words.get(w.lower(), w)) for w in words]
        ra._process_yo = process_yo
        self.ra = ra

    def mark(self, text):
        return to_acute(apply_rules(self.ra.process_all(text)))


def _zero_fill_missing_inputs(ort, np):
    """ruaccent's ONNX models take token_type_ids, which newer tokenizers no
    longer return: zeros for any such input."""
    if getattr(ort.InferenceSession, "_llmtray_zero_fill", False):
        return
    run = ort.InferenceSession.run

    def run_filled(self, output_names, feed, *a, **k):
        if "input_ids" in feed:
            names = [i.name for i in self.get_inputs()]
            if any(n not in feed for n in names):
                feed = dict(feed)
                for n in names:
                    feed.setdefault(n, np.zeros_like(feed["input_ids"]))
        return run(self, output_names, feed, *a, **k)
    ort.InferenceSession.run = run_filled
    ort.InferenceSession._llmtray_zero_fill = True


# MARK: self-test (no model files)

def selftest():
    import numpy as np
    assert rule_stress("инференс") == "инф+еренс", rule_stress("инференс")
    assert rule_stress("ёлка") == "+ёлка"
    assert rule_stress("интеграция") == "интегр+ация"
    assert rule_stress("кот") == "кот"
    assert to_acute("Чем мог+у пом+очь?") == "Чем могу́ помо́чь?"
    assert to_acute("к+ое-как+ой") == "кое-како́й"
    assert to_acute("ид+ёт календар+ём") == "идёт календарём"
    assert apply_rules("Сл+оман з+амок на дв+ери.") == "Сл+оман зам+ок на дв+ери."
    assert apply_rules("Я пл+ачу за св+ет.") == "Я плач+у за св+ет."
    assert apply_rules("Вы пол+ожите тр+убку?") == "Вы пол+ожите тр+убку?"
    words = {"помочь": "пом+очь", "замок": "з+амок", "все": "вс+е+"}
    keys = np.array(sorted(word_hash(w) for w in ("помочь", "замок")), np.uint64)
    pos = np.array([dict((word_hash(w), words[w].index("+")) for w in ("помочь", "замок"))[int(k)] for k in keys], np.uint8)
    d = HashDict(keys, pos, {"все": "вс+е+"})
    assert d.get("помочь") == "пом+очь" and d.get("замок") == "з+амок" and d.get("все") == "вс+е+"
    assert d.get("кошка") is None and "помочь" in d
    print("ok")


def main(argv):
    if argv[1:2] == ["--selftest"]:
        selftest()
    elif argv[1:2] == ["build"] and len(argv) == 3:
        folder = argv[2]
        os.makedirs(folder, exist_ok=True)
        fetch(folder, progress=lambda i, n: print("@@LLMTRAY STEP %d %d" % (i, n), flush=True))
        build(folder)
        print("@@LLMTRAY DONE", flush=True)
    elif argv[1:2] == ["mark"] and len(argv) == 4:
        print(RuStress(argv[2]).mark(argv[3]))
    else:
        print(__doc__ or "usage: build <dir> | mark <dir> <text> | --selftest", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
