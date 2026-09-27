"""Build the parity corpus (~50 texts: ru / en / mixed / code, short to 8k+ tokens)
and a small query->doc retrieval set. Output: <out>/corpus.json, <out>/retrieval.json.

Long texts come from Wikipedia (fetched) and this repo's own sources, cut to a
target token count with the bge-m3 tokenizer.
usage: python make_corpus.py <out_dir> <bge-m3 tokenizer.json>
"""
import glob
import json
import os
import sys
import urllib.parse
import urllib.request

from tokenizers import Tokenizer

OUT, TOKJSON = sys.argv[1], sys.argv[2]
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
tok = Tokenizer.from_file(TOKJSON)


def wiki(lang, title):
    q = urllib.parse.urlencode({"action": "query", "prop": "extracts", "explaintext": 1,
                                "titles": title, "format": "json", "redirects": 1})
    req = urllib.request.Request(f"https://{lang}.wikipedia.org/w/api.php?{q}",
                                 headers={"User-Agent": "llmtray-rag-spike/0.1 (hello@ipsupport.us)"})
    pages = json.load(urllib.request.urlopen(req, timeout=30))["query"]["pages"]
    return next(iter(pages.values()))["extract"]


def cut(text, n_tokens):
    enc = tok.encode(text, add_special_tokens=False)
    if len(enc.ids) <= n_tokens:
        return text
    end = enc.offsets[n_tokens - 1][1]
    return text[:end]


SHORT = [
    ("en", "The quick brown fox jumps over the lazy dog."),
    ("en", "Invoices must be paid within thirty days of the delivery date."),
    ("en", "Apple Silicon shares one pool of unified memory between the CPU and the GPU."),
    ("en", "How do I reset my password?"),
    ("en", "SQLite FTS5 provides full-text search with BM25 ranking."),
    ("en", "The contract may be terminated by either party with 60 days written notice."),
    ("en", "Photosynthesis converts light energy into chemical energy stored in glucose."),
    ("en", "Hi"),
    ("ru", "Договор может быть расторгнут любой из сторон с письменным уведомлением за 60 дней."),
    ("ru", "Счета должны быть оплачены в течение тридцати дней с даты поставки."),
    ("ru", "Как сбросить пароль?"),
    ("ru", "Москва — столица России и крупнейший по численности населения город страны."),
    ("ru", "Съешь же ещё этих мягких французских булок, да выпей чаю."),
    ("ru", "Ёлка стояла в углу, украшенная старыми стеклянными игрушками."),
    ("ru", "Фотосинтез превращает энергию света в химическую энергию глюкозы."),
    ("ru", "Привет"),
    ("mixed", "Запусти `swift build -c release` и проверь, что LLMTray стартует без ошибок."),
    ("mixed", "Модель bge-m3 даёт 1024-мерные dense vectors, CLS pooling, normalized."),
    ("mixed", "В PDF-файле текст на странице 12 распознан как U+0138 вместо «к»."),
    ("mixed", "Deadline по проекту — пятница, release v0.7.2 must ship with the pinned runtime."),
    ("mixed", "Ошибка: Metal out of memory при batch size 32, попробуй уменьшить до 8."),
    ("mixed", "The договор (contract) is signed; оплата due in 30 days."),
    ("code", "def cosine(a, b):\n    return a @ b / (np.linalg.norm(a) * np.linalg.norm(b))"),
    ("code", "SELECT doc, page, bm25(chunks_fts) AS score FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY score LIMIT 20;"),
    ("code", "let task = Process()\ntask.executableURL = URL(fileURLWithPath: python)\ntry task.run()"),
    ("code", "for (int i = 0; i < n; ++i) { sum += a[i] * b[i]; }"),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    items = [{"lang": l, "text": t, "src": "handwritten"} for l, t in SHORT]

    arts = {
        ("ru", "Пушкин, Александр Сергеевич"): None,
        ("ru", "Москва"): None,
        ("ru", "Гражданский кодекс Российской Федерации"): None,
        ("en", "Apple silicon"): None,
        ("en", "SQLite"): None,
        ("en", "Transformer (deep learning architecture)"): None,
    }
    for k in arts:
        arts[k] = wiki(*k)
    # ~400-token chunks (the indexing unit)
    for (lang, title), txt in arts.items():
        for start in (len(txt) // 5, len(txt) // 2):
            items.append({"lang": lang, "text": cut(txt[start:], 400), "src": f"wiki:{title}"})
    # code chunks from this repo (~400 tokens)
    for f in ["Sources/LLMTray/ServerManager.swift", "Sources/LLMTray/ChatClient.swift",
              "scripts/build_full_app.sh", "Package.swift"]:
        p = os.path.join(REPO, f)
        if os.path.exists(p):
            items.append({"lang": "code", "text": cut(open(p).read()[-3000:], 400), "src": f})
    # long ones
    ru_long = arts[("ru", "Пушкин, Александр Сергеевич")] + "\n" + arts[("ru", "Москва")]
    en_long = arts[("en", "Apple silicon")] + "\n" + arts[("en", "SQLite")] + "\n" + arts[("en", "Transformer (deep learning architecture)")]
    code_long = "\n".join(open(p).read() for p in sorted(glob.glob(os.path.join(REPO, "Sources/LLMTray/*.swift")))[:12])
    mixed_long = "\n".join(a + "\n" + b for a, b in zip(ru_long.split("\n")[:400], en_long.split("\n")[:400]))
    for n in (2000, 4000, 8000):
        items.append({"lang": "ru", "text": cut(ru_long, n), "src": f"long-ru-{n}"})
        items.append({"lang": "en", "text": cut(en_long, n), "src": f"long-en-{n}"})
    items.append({"lang": "code", "text": cut(code_long, 4000), "src": "long-code-4000"})
    items.append({"lang": "code", "text": cut(code_long, 8000), "src": "long-code-8000"})
    items.append({"lang": "mixed", "text": cut(mixed_long, 6000), "src": "long-mixed-6000"})
    items.append({"lang": "ru", "text": cut(ru_long, 12000), "src": "long-ru-12000 (truncated to 8192)"})
    for i, it in enumerate(items):
        it["id"] = i
        it["tokens"] = len(tok.encode(it["text"]).ids)
    json.dump(items, open(os.path.join(OUT, "corpus.json"), "w"), ensure_ascii=False, indent=1)
    print(len(items), "texts;", sum(it["tokens"] > 1500 for it in items), "long")
    json.dump(RETRIEVAL, open(os.path.join(OUT, "retrieval.json"), "w"), ensure_ascii=False, indent=1)


RETRIEVAL = {
    "docs": [
        "Договор аренды заключается на срок 11 месяцев и может быть продлён по соглашению сторон.",
        "Арендатор обязан вносить арендную плату не позднее 5 числа каждого месяца.",
        "The lease agreement is concluded for 11 months and may be extended by mutual consent.",
        "Tenant shall pay rent no later than the 5th day of each month.",
        "Для установки приложения перетащите LLMTray.app в папку «Программы».",
        "To install the app, drag LLMTray.app into the Applications folder.",
        "Unified memory on Apple Silicon lets the GPU use most of the system RAM; the default Metal limit is about 75%.",
        "Нейросеть-трансформер использует механизм внимания вместо рекуррентных связей.",
        "The transformer architecture relies on self-attention instead of recurrence.",
        "func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float { vDSP.dot(a, b) / (norm(a) * norm(b)) }",
        "CREATE VIRTUAL TABLE chunks_tri USING fts5(body, content='chunks', tokenize='trigram');",
        "Пушкин родился 6 июня 1799 года в Москве, в Немецкой слободе.",
        "Pushkin died in 1837 after a duel with Georges d'Anthès.",
        "Банковская гарантия выдаётся на сумму не менее 10% от цены контракта.",
        "Сканированные страницы распознаются Vision OCR, если в PDF нет текстового слоя.",
        "Recipe: whisk two eggs with milk, pour into a hot pan and cook for three minutes.",
    ],
    "queries": [
        {"q": "срок договора аренды", "rel": [0, 2]},
        {"q": "when is the rent due", "rel": [3, 1]},
        {"q": "как установить программу", "rel": [4, 5]},
        {"q": "how much RAM can the GPU use on a Mac", "rel": [6]},
        {"q": "что такое self-attention", "rel": [7, 8]},
        {"q": "swift function cosine similarity of two vectors", "rel": [9]},
        {"q": "trigram full-text index in sqlite", "rel": [10]},
        {"q": "когда родился Пушкин", "rel": [11]},
        {"q": "how did Pushkin die", "rel": [12]},
        {"q": "размер банковской гарантии по контракту", "rel": [13]},
        {"q": "OCR for scanned PDF without text layer", "rel": [14]},
        {"q": "как приготовить омлет", "rel": [15]},
    ],
}

if __name__ == "__main__":
    main()
