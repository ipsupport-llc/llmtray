import Foundation

public struct SplitMix64: RandomNumberGenerator {
    var s: UInt64
    public init(seed: UInt64) { s = seed }
    public mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Synthetic Russian/English business-and-tech text with a Zipf-like word
/// distribution: real inflected Russian forms, English words, a long tail of
/// generated words, identifiers, INN-like numbers, dates, amounts, «quotes».
public struct CorpusGenerator {
    var rng: SplitMix64
    let ru: [String]
    let en: [String]
    let ruTail: [String]
    let enTail: [String]
    let cumRu: [Double], cumEn: [Double]

    static let ruStems: [(String, [String])] = {
        let noun1 = ["", "а", "у", "ом", "е", "ы", "ов", "ам", "ами", "ах"]          // договор
        let noun2 = ["а", "ы", "е", "у", "ой", "", "ам", "ами", "ах"]               // поставка → поставк
        let noun3 = ["ие", "ия", "ию", "ием", "ии", "ий", "иям", "иями", "иях"]      // соглашение → соглашен
        let adj = ["ый", "ого", "ому", "ым", "ом", "ая", "ой", "ую", "ое", "ые", "ых", "ыми"]
        let verb = ["ть", "ет", "ют", "л", "ла", "ли", "ет", "ем"]
        return [
            ("договор", noun1), ("счет", noun1), ("акт", noun1), ("платеж", noun1), ("заказ", noun1),
            ("товар", noun1), ("срок", noun1), ("отчет", noun1), ("расчет", noun1), ("контракт", noun1),
            ("сервер", noun1), ("файл", noun1), ("проект", noun1), ("документ", noun1), ("клиент", noun1),
            ("поставк", noun2), ("оплат", noun2), ("сторон", noun2), ("работ", noun2), ("систем", noun2),
            ("задач", noun2), ("компани", noun2), ("претензи", noun2), ("неустойк", noun2), ("цен", noun2),
            ("соглашен", noun3), ("исполнен", noun3), ("обязательств", ["о", "а", "у", "ом", "е", "", "ам", "ами", "ах"]),
            ("требован", noun3), ("приложен", noun3), ("уведомлен", noun3), ("решен", noun3), ("изменен", noun3),
            ("настоящ", ["ий", "его", "ему", "им", "ем", "ая", "ей", "ую", "ее", "ие", "их"]),
            ("должн", adj), ("финансов", adj), ("технически", ["й", "х", "м", "ми"]), ("нов", adj),
            ("письменн", adj), ("основн", adj), ("полн", adj), ("данн", adj), ("срочн", adj),
            ("выполня", verb), ("обязу", ["ется", "ются", "ющийся"]), ("предоставля", verb), ("получа", verb),
            ("подписыва", verb), ("направля", verb), ("рассматрива", verb), ("использова", verb),
        ]
    }()

    static let ruFunction = ["в", "и", "на", "с", "по", "не", "что", "к", "для", "о", "от", "из", "за",
                             "при", "а", "как", "до", "или", "также", "если", "его", "их", "это", "то",
                             "течение", "дней", "рублей", "г.", "т.е.", "согласно", "между", "после"]
    static let enWords = ["the", "of", "and", "to", "a", "in", "is", "for", "that", "with", "on", "as",
                          "be", "by", "this", "are", "or", "from", "server", "config", "request", "response",
                          "error", "timeout", "database", "index", "query", "client", "cache", "token",
                          "model", "file", "user", "value", "returns", "function", "parameter", "default",
                          "update", "delete", "insert", "transaction", "commit", "memory", "thread", "queue",
                          "latency", "throughput", "release", "build", "version", "deploy", "invoice",
                          "payment", "contract", "delivery", "supplier", "agreement", "shall", "party", "terms"]

    public init(seed: UInt64) {
        rng = SplitMix64(seed: seed)
        var ru: [String] = CorpusGenerator.ruFunction
        for (stem, ends) in CorpusGenerator.ruStems { for e in ends { ru.append(stem + e) } }
        self.ru = ru
        en = CorpusGenerator.enWords
        // long tail: 30k generated Russian-looking and 10k English-looking words
        var g = SplitMix64(seed: seed ^ 0xABCDEF)
        let ruSyl = ["ка", "ро", "ти", "на", "ва", "ле", "ми", "до", "за", "пре", "ст", "ор", "ен", "ис", "ть", "ло", "ри", "ско", "ва", "ция", "ник", "ость", "тель"]
        let enSyl = ["con", "ter", "pro", "ment", "ing", "tion", "al", "re", "de", "ex", "port", "form", "ly", "er", "ize", "able", "vis", "cal"]
        func word(_ syl: [String], _ n: Int) -> String { (0..<n).map { _ in syl[Int(g.next() % UInt64(syl.count))] }.joined() }
        ruTail = (0..<30000).map { _ in word(ruSyl, 2 + Int(g.next() % 3)) }
        enTail = (0..<10000).map { _ in word(enSyl, 2 + Int(g.next() % 3)) }
        func zipf(_ n: Int) -> [Double] {
            var c = [Double](); c.reserveCapacity(n); var acc = 0.0
            for r in 1...n { acc += 1.0 / Double(r); c.append(acc) }
            return c.map { $0 / acc }
        }
        cumRu = zipf(ru.count); cumEn = zipf(en.count)
    }

    mutating func pick(_ words: [String], _ cum: [Double]) -> String {
        let u = Double(rng.next() >> 11) / Double(1 << 53)
        var lo = 0, hi = cum.count - 1
        while lo < hi { let m = (lo + hi) / 2; if cum[m] < u { lo = m + 1 } else { hi = m } }
        return words[lo]
    }

    mutating func rand(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }

    mutating func token(russian: Bool) -> String {
        let r = rand(1000)
        if r < 8 { return String(format: "%010llu", rng.next() % 10_000_000_000) }          // INN-like
        if r < 14 { return "\(1 + rand(28)).\(String(format: "%02d", 1 + rand(12))).20\(10 + rand(17))" }
        if r < 20 { return "\(rand(900) + 100) \(String(format: "%03d", rand(1000))),\(String(format: "%02d", rand(100)))" }
        if r < 26 {
            let a = ["parse", "load", "build", "get", "set", "make", "read", "write", "index", "fetch"][rand(10)]
            let b = ["Config", "Index", "Chunk", "Query", "Model", "Token", "Server", "Page", "Vector", "Cache"][rand(10)]
            return a + b
        }
        if r < 160 { return russian ? ruTail[rand(ruTail.count)] : enTail[rand(enTail.count)] }
        return russian ? pick(ru, cumRu) : pick(en, cumEn)
    }

    public mutating func sentence(russian: Bool) -> String {
        let n = 6 + rand(15)
        var words: [String] = []
        for _ in 0..<n { words.append(token(russian: russian)) }
        if rand(10) == 0 { words[rand(n)] = russian ? "«" + words[rand(n)] + "»" : "\"" + words[rand(n)] + "\"" }
        if rand(6) == 0 { words[rand(n)] += "," }
        var s = words.joined(separator: " ")
        s = s.prefix(1).uppercased() + s.dropFirst()
        return s + [".", ".", ".", ";", "?", "!"][rand(6)]
    }

    /// ~`words` words of text; about 70% Russian.
    public mutating func text(words target: Int, russian: Bool? = nil) -> String {
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
