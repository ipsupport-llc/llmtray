import Foundation
import XCTest
@testable import LLMTrayCore

func indexTempDir(_ name: String = #function) -> URL {
    let safe = name.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("llmtray-index-\(safe)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Deterministic toy embedder: a feature-hashed bag of normalized words
/// (their trigram pseudo-stems), L2-normalized -- enough for dense results
/// to mean something in fusion tests.
struct ToyEmbedder {
    var dim = 64
    func embed(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        for t in IndexQuery.terms(text) {
            var h: UInt64 = 1469598103934665603
            for b in IndexQuery.stemForTrigram(t).utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            v[Int(h % UInt64(dim))] += (h >> 63) == 0 ? 1 : -1
        }
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }
}

/// Synthetic Russian/English business-and-tech text (the spike's corpus,
/// smaller tail): inflected Russian forms, English words, generated words,
/// identifiers, INN-like numbers, dates, amounts, «quotes».
struct CorpusGenerator {
    var rng: SplitMix64
    let ru: [String]
    let en: [String]
    let ruTail: [String]
    let enTail: [String]

    static let ruStems: [(String, [String])] = {
        let noun1 = ["", "а", "у", "ом", "е", "ы", "ов", "ам", "ами", "ах"]
        let noun2 = ["а", "ы", "е", "у", "ой", "", "ам", "ами", "ах"]
        let noun3 = ["ие", "ия", "ию", "ием", "ии", "ий", "иям", "иями", "иях"]
        let adj = ["ый", "ого", "ому", "ым", "ом", "ая", "ой", "ую", "ое", "ые", "ых", "ыми"]
        let verb = ["ть", "ет", "ют", "л", "ла", "ли", "ем"]
        return [
            ("договор", noun1), ("счет", noun1), ("акт", noun1), ("платеж", noun1), ("заказ", noun1),
            ("товар", noun1), ("срок", noun1), ("отчет", noun1), ("сервер", noun1), ("проект", noun1),
            ("поставк", noun2), ("оплат", noun2), ("сторон", noun2), ("работ", noun2), ("систем", noun2),
            ("соглашен", noun3), ("исполнен", noun3), ("требован", noun3), ("приложен", noun3),
            ("должн", adj), ("финансов", adj), ("нов", adj), ("письменн", adj),
            ("выполня", verb), ("предоставля", verb), ("получа", verb),
        ]
    }()
    static let ruFunction = ["в", "и", "на", "с", "по", "не", "что", "к", "для", "о", "от", "из", "за",
                             "при", "а", "как", "до", "или", "также", "если", "это", "течение", "дней", "рублей"]
    static let enWords = ["the", "of", "and", "to", "a", "in", "is", "for", "that", "with", "on", "as",
                          "server", "config", "request", "response", "error", "timeout", "database", "index",
                          "query", "client", "cache", "token", "model", "file", "user", "value", "function",
                          "update", "delete", "commit", "memory", "thread", "queue", "invoice", "payment", "contract"]

    init(seed: UInt64) {
        rng = SplitMix64(seed: seed)
        var ru = Self.ruFunction
        for (stem, ends) in Self.ruStems { for e in ends { ru.append(stem + e) } }
        self.ru = ru
        en = Self.enWords
        var g = SplitMix64(seed: seed ^ 0xABCDEF)
        let ruSyl = ["ка", "ро", "ти", "на", "ва", "ле", "ми", "до", "за", "пре", "ст", "ор", "ен", "ис", "ло", "ри", "ско", "ция", "ник"]
        let enSyl = ["con", "ter", "pro", "ment", "ing", "tion", "al", "re", "de", "ex", "port", "form", "er", "ize"]
        func word(_ syl: [String], _ n: Int) -> String { (0..<n).map { _ in syl[Int(g.next() % UInt64(syl.count))] }.joined() }
        ruTail = (0..<3000).map { _ in word(ruSyl, 2 + Int(g.next() % 3)) }
        enTail = (0..<1000).map { _ in word(enSyl, 2 + Int(g.next() % 3)) }
    }

    mutating func rand(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }

    /// Zipf-ish: the square of a uniform index favours the front of the list.
    mutating func pick(_ words: [String]) -> String {
        let u = Double(rng.next() >> 11) / Double(1 << 53)
        return words[min(words.count - 1, Int(u * u * Double(words.count)))]
    }

    mutating func token(russian: Bool) -> String {
        let r = rand(1000)
        if r < 8 { return String(format: "%010llu", rng.next() % 10_000_000_000) }
        if r < 14 { return "\(1 + rand(28)).\(String(format: "%02d", 1 + rand(12))).20\(10 + rand(17))" }
        if r < 26 {
            let a = ["parse", "load", "build", "get", "set", "read", "write", "fetch"][rand(8)]
            let b = ["Config", "Index", "Chunk", "Query", "Model", "Token", "Server", "Page"][rand(8)]
            return a + b
        }
        if r < 160 { return russian ? ruTail[rand(ruTail.count)] : enTail[rand(enTail.count)] }
        return russian ? pick(ru) : pick(en)
    }

    mutating func sentence(russian: Bool) -> String {
        let n = 6 + rand(15)
        var words = (0..<n).map { _ in token(russian: russian) }
        if rand(10) == 0 { words[rand(n)] = russian ? "«" + words[rand(n)] + "»" : "\"" + words[rand(n)] + "\"" }
        let s = words.joined(separator: " ")
        return s.prefix(1).uppercased() + s.dropFirst() + [".", ".", ".", ";", "?", "!"][rand(6)]
    }

    /// About `words` words; ~70% of documents Russian.
    mutating func text(words target: Int, russian: Bool? = nil) -> String {
        let ruDoc = russian ?? (rand(10) < 7)
        var out = "", count = 0
        while count < target {
            let s = sentence(russian: ruDoc || rand(20) == 0)
            count += s.split(separator: " ").count
            out += (out.isEmpty ? "" : " ") + s
        }
        return out
    }
}

/// Small chunks, so small texts make many of them.
let testChunker = IndexChunker(minTokens: 20, maxTokens: 40)

extension ProjectIndex {
    static func testIndex(_ dir: URL = indexTempDir(), chunker: IndexChunker = testChunker) throws -> ProjectIndex {
        let idx = try ProjectIndex(directory: dir)
        idx.chunker = chunker
        return idx
    }

    var toySet: Int64 { (try? vectorSet(model: "toy-hash", dim: 64, prepVersion: 1).id) ?? 1 }

    /// Pages from a text (pages split by form feed).
    static func pages(_ text: String) -> [ExtractedPage] {
        text.components(separatedBy: "\u{0C}").enumerated().map { ExtractedPage(page: $0.offset + 1, text: $0.element) }
    }

    /// The whole add pipeline from an in-memory text.
    @discardableResult
    func addText(_ text: String, name: String = "doc.txt", embed: Bool = true, batch: Int = 16) throws -> Int64 {
        let src = directory.deletingLastPathComponent().appendingPathComponent("src-\(UUID().uuidString)-\(name)")
        try text.write(to: src, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: src) }
        let doc = try addCopy(of: src, name: name)
        try extract(doc)
        if embed { try embedAll(doc, batch: batch) }
        return doc
    }

    /// Extraction the way the app does it, from the copy (UTF-8 text here).
    func extract(_ doc: Int64) throws {
        let job = try beginExtraction(doc: doc)
        let text = try String(contentsOf: job.file, encoding: .utf8)
        try commitExtraction(job, pages: Self.pages(text), kind: "text")
    }

    func embedAll(_ doc: Int64, batch: Int = 16) throws {
        let set = toySet
        let embedder = ToyEmbedder()
        while true {
            let pending = try pendingChunks(doc: doc, set: set, limit: batch)
            guard let rev = pending.first?.rev else { return }
            var v: [Float16] = []
            for p in pending { v += embedder.embed(p.text).map(Float16.init) }
            try commitVectors(doc: doc, rev: rev, set: set, chunks: pending.map(\.id), vectors: v)
        }
    }

    /// Crash (throw) at the `occurrence`-th time `point` is reached.
    func crash(at point: String, occurrence: Int = 1) {
        var seen = 0
        crashHook = { name in
            guard name == point else { return }
            seen += 1
            if seen == occurrence { throw SimulatedCrash(point: name) }
        }
    }

    func searcher() throws -> IndexSearcher { try IndexSearcher(db: db) }

    func count(_ sql: String, _ args: [SQLValue] = []) throws -> Int64 { try db.scalarInt(sql, args) ?? 0 }
}

func allChunkIDs(_ db: SQLiteConnection) throws -> [Int64] {
    try db.rows("SELECT id FROM chunks ORDER BY id") { $0.int(0) }
}

/// Doc ids a list of chunk ids belongs to.
func docsOf(_ s: IndexSearcher, _ ids: [Int64]) throws -> Set<Int64> {
    Set(try ids.compactMap { try s.fetch($0)?.doc })
}
