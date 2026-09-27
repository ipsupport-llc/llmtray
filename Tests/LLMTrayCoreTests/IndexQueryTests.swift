import XCTest
@testable import LLMTrayCore

final class IndexNormalizationTests: XCTestCase {
    func testNormalizer() {
        XCTAssertEqual(IndexText.normalize("Ёлка и ЕЁ Счёт"), "елка и ее счет")
        XCTAssertEqual(IndexText.normalize("е\u{0308}ж"), "еж", "decomposed ё: NFC first, then ё → е")
        XCTAssertEqual(IndexText.normalize("и\u{0306}од"), "йод", "decomposed й composes and is not turned into и")
        XCTAssertEqual(IndexText.normalize("ParseConfig"), "parseconfig")
        XCTAssertEqual(IndexText.normalize("  пере\u{00AD}нос  и\u{200B}\n\tпробел "), "перенос и пробел")
        XCTAssertEqual(IndexText.normalize("a\u{0}b\u{7}c\u{202E}d"), "a b cd", "controls are spaces, bidi overrides go")
        XCTAssertEqual(IndexText.normalize("İstanbul"), "i\u{307}stanbul", "locale-free lowercasing")
        // Look-alikes stay distinct.
        XCTAssertNotEqual(IndexText.normalize("А"), IndexText.normalize("A"))   // U+0410 vs U+0041
        XCTAssertNotEqual(IndexText.normalize("СССР"), IndexText.normalize("CCCP"))
        XCTAssertEqual(IndexText.normalize("А").unicodeScalars.first?.value, 0x0430)
        XCTAssertEqual(IndexText.normalize("A").unicodeScalars.first?.value, 0x0061)
    }

    func testQueryTerms() {
        XCTAssertEqual(IndexQuery.terms("ООО «Ромашка», ИНН: 7707083893!"), ["ооо", "ромашка", "инн", "7707083893"])
        XCTAssertEqual(IndexQuery.terms("parse_config(x) / parseConfig"), ["parse", "config", "x", "parseconfig"])
        XCTAssertEqual(IndexQuery.terms("e-mail т.е. 3.14"), ["e", "mail", "т", "е", "3", "14"])
        XCTAssertEqual(IndexQuery.terms("Ёлка ёлка ЕЛКА"), ["елка"], "deduplicated after normalization")
        XCTAssertEqual(IndexQuery.terms(String(repeating: "слово ", count: 5000)).count, 1)
        let many = (0..<100).map { "w\($0)" }.joined(separator: " ")
        XCTAssertEqual(IndexQuery.terms(many).count, IndexQuery.maxTerms)
        XCTAssertEqual(IndexQuery.terms(String(repeating: "я", count: 1000)).first?.count, IndexQuery.maxTermLength)
        XCTAssertEqual(IndexQuery.stemForTrigram("договоров"), "договор")
        XCTAssertEqual(IndexQuery.stemForTrigram("договора"), "договор")
        XCTAssertEqual(IndexQuery.stemForTrigram("договор"), "договор")
        XCTAssertEqual(IndexQuery.stemForTrigram("поставки"), "поставк")
        XCTAssertEqual(IndexQuery.stemForTrigram("config"), "config", "non-Cyrillic untouched")
        XCTAssertEqual(IndexQuery.stemForTrigram("дома"), "дома", "short words untouched")
    }

    func testShortTermsGoToUnicode61Only() {
        let q = IndexQuery.build("ИП")
        XCTAssertNil(q.trigram)
        XCTAssertEqual(q.words, "\"ип\"")
        XCTAssertNil(IndexQuery.build("г.").trigram)
        XCTAssertEqual(IndexQuery.build("ИП Иванов").trigram, "\"иванов\"", "only 3+ character terms reach trigram")
        XCTAssertEqual(IndexQuery.build("ИП Иванов").words, "\"ип\" OR \"иванов\"")
    }

    func testTokenEstimate() {
        XCTAssertEqual(IndexText.estimatedTokens(""), 0)
        XCTAssertEqual(IndexText.estimatedTokens("a b c d"), 4, "at least one per word")
        XCTAssertEqual(IndexText.estimatedTokens(String(repeating: "x", count: 400)), 100)
        XCTAssertEqual(IndexText.estimatedTokens(String(repeating: "ж", count: 300)), 100)
    }
}

/// The spike's retrieval checks against a real index: Russian morphology
/// through trigram, identifiers, numbers, short queries, ё and look-alikes.
final class IndexRetrievalTests: XCTestCase {
    var idx: ProjectIndex!
    var s: IndexSearcher!
    var d: [String: Int64] = [:]

    override func setUpWithError() throws {
        idx = try ProjectIndex.testIndex(chunker: IndexChunker(minTokens: 300, maxTokens: 500))
        let texts: [String: String] = [
            "nom": "Договор подряда заключен между сторонами.",
            "gen": "Условия договора поставки согласованы.",
            "genpl": "Реестр договоров за 2025 год.",
            "dat": "Оплата по договору производится в течение пяти дней.",
            "ip": "ИП Иванов И.И. предоставляет услуги.",
            "code": "Call parseConfig(path) before loadIndex; see parseConfigFile and parse_config.",
            "inn": "Реквизиты: ИНН 7707083893, КПП 770701001, ООО \"Ромашка\".",
            "cyr": "Выпуск СССР, серия А.",
            "lat": "Label CCCP, series A.",
            "yo": "Ёлка стоит в углу, счёт выставлен.",
            "moi": "Это мой отчет.",
            "punct": "Пишите на e-mail, т.е. на почту; (скобки) [квадратные] {фигурные} — тире… «ёлочки».",
            "mixed": "Aвтомобиль с латинской первой буквой.",   // Latin A + Cyrillic
        ]
        for (k, t) in texts.sorted(by: { $0.key < $1.key }) { d[k] = try idx.addText(t, name: k + ".txt", embed: false) }
        s = try idx.searcher()
    }

    func words(_ q: String) throws -> Set<String> { try names(s.words(IndexQuery.build(q)).ids) }
    func tri(_ q: String) throws -> Set<String> { try names(s.trigram(IndexQuery.build(q)).ids) }
    func names(_ ids: [Int64]) throws -> Set<String> {
        let byDoc = Dictionary(uniqueKeysWithValues: d.map { ($0.value, $0.key) })
        return Set(try docsOf(s, ids).map { byDoc[$0]! })
    }

    func testRussianMorphologyViaTrigram() throws {
        XCTAssertEqual(try words("договор"), ["nom"], "unicode61 alone: the exact form only")
        XCTAssertEqual(try tri("договор"), ["nom", "gen", "genpl", "dat"])
        XCTAssertEqual(try tri("договоров"), ["nom", "gen", "genpl", "dat"], "the pseudo-stem reaches the other forms")
        XCTAssertEqual(try tri("Договору"), ["nom", "gen", "genpl", "dat"])
        let hybrid = try s.search("договоров", options: IndexSearchOptions(limit: 10))
        XCTAssertEqual(Set(hybrid.hits.map(\.doc)), Set(["nom", "gen", "genpl", "dat"].map { d[$0]! }))
        XCTAssertFalse(hybrid.usedDense)
        XCTAssertTrue(hybrid.hits.allSatisfy(\.isLexicalOnly))
    }

    func testShortQueries() throws {
        XCTAssertEqual(try words("ИП"), ["ip"])
        XCTAssertEqual(try tri("ИП"), [])
        XCTAssertTrue(try words("и").contains("ip"), "a one-letter token via unicode61")
        XCTAssertEqual(Set(try s.search("ИП").hits.map(\.doc)), [d["ip"]!])
    }

    func testIdentifiersNumbersPunctuation() throws {
        XCTAssertEqual(try words("parseConfig"), ["code"])
        XCTAssertEqual(try tri("parseConfig"), ["code"])
        XCTAssertEqual(try tri("config"), ["code"], "a substring inside an identifier: trigram")
        XCTAssertEqual(try words("config"), ["code"], "and unicode61 from parse_config (the underscore splits)")
        XCTAssertEqual(try words("loadindex"), ["code"])
        XCTAssertEqual(try words("7707083893"), ["inn"])
        XCTAssertEqual(try words("ИНН: 7707083893"), ["inn"])
        XCTAssertEqual(try tri("770708"), ["inn"], "a partial number: trigram only")
        XCTAssertEqual(try words("770708"), [])
        XCTAssertEqual(try words("ООО «Ромашка»"), ["inn"])
        XCTAssertEqual(try words("e-mail"), ["punct"])
        XCTAssertEqual(try words("(скобки)"), ["punct"])
        XCTAssertEqual(try tri("«ёлочки»"), ["punct"])
    }

    func testYoAndLookAlikes() throws {
        XCTAssertEqual(try words("елка"), ["yo"])
        XCTAssertEqual(try words("ЁЛКА"), ["yo"])
        XCTAssertEqual(try tri("счет"), ["yo"])
        XCTAssertEqual(try words("СССР"), ["cyr"])
        XCTAssertEqual(try words("CCCP"), ["lat"], "a Latin look-alike must not match Cyrillic")
        XCTAssertEqual(try tri("CCCP"), ["lat"])
        XCTAssertEqual(try tri("автомобиль"), [], "a mixed-script word isn't found by the Cyrillic query: junk-check territory")
        XCTAssertEqual(try tri("втомобиль"), ["mixed"])
    }

    /// unicode61 remove_diacritics 2 folds Latin only, not й → и or ё → е.
    func testUnicode61DiacriticsAreLatinOnly() throws {
        XCTAssertEqual(try words("мои"), [], "й stays distinct from и")
        let raw = try ProjectIndex.testIndex()
        let doc = try raw.addText("x", embed: false)
        try raw.db.run("UPDATE chunks SET body = 'ёлка café' WHERE doc = ?", [.int(doc)])
        let rs = try raw.searcher()
        XCTAssertTrue(try rs.rawMatch(table: "chunks_fts", "елка").isEmpty, "unicode61 alone: ё ≠ е")
        XCTAssertFalse(try rs.rawMatch(table: "chunks_fts", "cafe").isEmpty, "Latin é → e is folded")
    }
}

final class IndexQueryInjectionTests: XCTestCase {
    static let hostile: [String] = [
        "\"", "\"\"\"", "'", "`", "\\", "a\"b", "\"договор", "договор\"",
        "NEAR(a b)", "a NEAR b", "NEAR(\"договор\" \"поставки\", 5)", "NEAR",
        "*", "a*", "*a", "договор*", "^договор", "-a", "a - b", "--", "+", "a + b",
        "(", ")", "((a)", "a)", "()", String(repeating: "(", count: 2000),
        "a AND", "AND", "OR", "NOT", "NOT a", "a OR", "AND OR NOT", "a AND NOT",
        "body:a", "{body}: a", "body:", "rank:", "chunks_fts", "-body:x", "{body chunk}:a",
        ":", "a:b:c", "a.b.c", "@@@", "$", "%", "_", "%_%", ";DROP TABLE chunks;--",
        "'); DELETE FROM chunks; --", "\u{0}", "a\u{0}b", "\u{202E}договор", "🙂", "\u{301}\u{301}",
        "", "   ", "!!!", "договор\" OR \"*", "договор\" NOT \"поставки",
        String(repeating: "договор ", count: 5000), String(repeating: "я", count: 100_000),
    ]

    func testHostileQueriesNeverFailAndAreInert() throws {
        let idx = try ProjectIndex.testIndex()
        var gen = CorpusGenerator(seed: 11)
        for i in 0..<5 { try idx.addText(gen.text(words: 200) + " договор поставки NEAR body", name: "d\(i).txt") }
        let s = try idx.searcher()
        let dense = DenseVectors(setID: idx.toySet, dim: 64)
        try dense.refresh(from: idx.db)
        let before = try idx.count("SELECT count(*) FROM chunks")
        var rawFailures = 0
        for q in Self.hostile {
            let lq = IndexQuery.build(q)
            XCTAssertLessThanOrEqual(lq.terms.count, IndexQuery.maxTerms)
            XCTAssertNoThrow(try s.words(lq), "words: \(q.prefix(40))")
            XCTAssertNoThrow(try s.trigram(lq), "trigram: \(q.prefix(40))")
            XCTAssertNoThrow(try s.search(q, queryVector: ToyEmbedder().embed(q), dense: dense))
            if (try? s.rawMatch(table: "chunks_fts", q)) == nil { rawFailures += 1 }
        }
        XCTAssertGreaterThan(rawFailures, 20, "the same strings passed raw would have been syntax errors")
        XCTAssertEqual(try idx.count("SELECT count(*) FROM chunks"), before)
        XCTAssertEqual(try s.words(IndexQuery.build("договор\" OR \"*")).ids, try s.words(IndexQuery.build("договор")).ids)
        XCTAssertEqual(try s.words(IndexQuery.build("NEAR(договор поставки)")).ids,
                       try s.words(IndexQuery.build("near договор поставки")).ids)
        XCTAssertFalse(try s.words(IndexQuery.build("NEAR")).ids.isEmpty, "the word NEAR is searchable as a word")
        XCTAssertFalse(try s.words(IndexQuery.build("body:")).ids.isEmpty, "column-filter syntax is just the word 'body'")
    }

    func testBuiltExpressionsAreOnlyQuotedStringsJoinedByOR() {
        for q in Self.hostile {
            let lq = IndexQuery.build(q)
            for expr in [lq.words, lq.trigram].compactMap({ $0 }) {
                var rest = "", inQuote = false
                for u in expr.unicodeScalars {   // scalars: SQLite sees code points
                    if u == "\"" { inQuote.toggle(); continue }
                    if !inQuote { rest.unicodeScalars.append(u) }
                }
                XCTAssertFalse(inQuote, "unbalanced quotes for \(q.prefix(30))")
                XCTAssertTrue(rest.replacingOccurrences(of: " OR ", with: "").isEmpty, "stray syntax '\(rest)' for \(q.prefix(30))")
            }
        }
    }
}
