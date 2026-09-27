import XCTest
@testable import RAGIndex

final class NormalizationTests: XCTestCase {
    func testNormalizer() {
        XCTAssertEqual(Normalizer.normalize("Ёлка и ЕЁ Счёт"), "елка и ее счет")
        XCTAssertEqual(Normalizer.normalize("е\u{0308}ж"), "еж", "decomposed ё: NFC first, then ё→е")
        XCTAssertEqual(Normalizer.normalize("и\u{0306}од"), "йод", "decomposed й composes (and is NOT turned into и)")
        XCTAssertEqual(Normalizer.normalize("ParseConfig"), "parseconfig")
        XCTAssertEqual(Normalizer.normalize("пере\u{00AD}нос  и\u{200B}\n\tпробел"), "перенос и пробел")
        XCTAssertEqual(Normalizer.normalize("İstanbul"), "i\u{307}stanbul", "locale-free lowercasing")
        // look-alikes stay distinct
        XCTAssertNotEqual(Normalizer.normalize("А"), Normalizer.normalize("A"))   // U+0410 vs U+0041
        XCTAssertNotEqual(Normalizer.normalize("СССР"), Normalizer.normalize("CCCP"))
        XCTAssertEqual(Normalizer.normalize("А").unicodeScalars.first!.value, 0x0430)
        XCTAssertEqual(Normalizer.normalize("A").unicodeScalars.first!.value, 0x0061)
    }

    func testQueryTerms() {
        XCTAssertEqual(QueryBuilder.terms("ООО «Ромашка», ИНН: 7707083893!"), ["ооо", "ромашка", "инн", "7707083893"])
        XCTAssertEqual(QueryBuilder.terms("parse_config(x) / parseConfig"), ["parse", "config", "x", "parseconfig"])
        XCTAssertEqual(QueryBuilder.terms("e-mail т.е. 3.14"), ["e", "mail", "т", "е", "3", "14"])
        XCTAssertEqual(QueryBuilder.stemForTrigram("договоров"), "договор")
        XCTAssertEqual(QueryBuilder.stemForTrigram("договора"), "договор")
        XCTAssertEqual(QueryBuilder.stemForTrigram("договор"), "договор")
        XCTAssertEqual(QueryBuilder.stemForTrigram("поставки"), "поставк")
        XCTAssertEqual(QueryBuilder.stemForTrigram("config"), "config", "non-Cyrillic untouched")
        XCTAssertEqual(QueryBuilder.stemForTrigram("дома"), "дома", "short words untouched")
    }

    func testShortQueriesGoToUnicode61Only() {
        let q = QueryBuilder.build("ИП")
        XCTAssertNil(q.trigram)
        XCTAssertEqual(q.words, "\"ип\"")
        XCTAssertNil(QueryBuilder.build("г.").trigram)
        let mixed = QueryBuilder.build("ИП Иванов")
        XCTAssertEqual(mixed.trigram, "\"иванов\"", "only ≥3-char terms reach trigram")
    }

    var idx: ProjectIndex!
    var s: Searcher!
    var d: [String: Int64] = [:]

    override func setUpWithError() throws {
        idx = try ProjectIndex(dir: tempDir())
        idx.wordsPerChunk = 400
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
        for (k, t) in texts.sorted(by: { $0.key < $1.key }) { d[k] = try idx.addText(t, name: k + ".txt") }
        s = try Searcher(db: idx.db)
    }

    func words(_ q: String) throws -> Set<String> { try names(s.words(QueryBuilder.build(q))) }
    func tri(_ q: String) throws -> Set<String> { try names(s.trigram(QueryBuilder.build(q))) }
    func names(_ ids: [Int64]) throws -> Set<String> {
        let rev = Dictionary(uniqueKeysWithValues: d.map { ($0.value, $0.key) })
        return Set(try docs(s, ids).map { rev[$0]! })
    }

    func testRussianMorphologyViaTrigram() throws {
        XCTAssertEqual(try words("договор"), ["nom"], "unicode61 alone: exact form only")
        XCTAssertEqual(try tri("договор"), ["nom", "gen", "genpl", "dat"])
        XCTAssertEqual(try tri("договоров"), ["nom", "gen", "genpl", "dat"], "pseudo-stem makes the genitive plural find the rest")
        XCTAssertEqual(try tri("Договору"), ["nom", "gen", "genpl", "dat"])
    }

    func testShortQueries() throws {
        XCTAssertEqual(try words("ИП"), ["ip"])
        XCTAssertEqual(try tri("ИП"), [])
        XCTAssertTrue(try words("и").contains("ip"), "one-letter token via unicode61")
    }

    func testIdentifiersNumbersPunctuation() throws {
        XCTAssertEqual(try words("parseConfig"), ["code"])
        XCTAssertEqual(try tri("parseConfig"), ["code"])
        XCTAssertEqual(try tri("config"), ["code"], "substring inside an identifier: trigram only")
        XCTAssertEqual(try words("config"), ["code"], "…and unicode61 gets it from parse_config (underscore splits)")
        XCTAssertEqual(try words("loadindex"), ["code"])
        XCTAssertEqual(try words("7707083893"), ["inn"])
        XCTAssertEqual(try words("ИНН: 7707083893"), ["inn"])
        XCTAssertEqual(try tri("770708"), ["inn"], "partial number: trigram only")
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
        XCTAssertEqual(try words("CCCP"), ["lat"], "Latin look-alike must not match Cyrillic")
        XCTAssertEqual(try tri("CCCP"), ["lat"])
        XCTAssertEqual(try tri("автомобиль"), [], "mixed-script word is not found by the all-Cyrillic query — junk check territory")
        XCTAssertEqual(try tri("втомобиль"), ["mixed"])
    }

    /// Observed: unicode61 remove_diacritics 2 does NOT fold Cyrillic й→и or ё→е
    /// (its diacritic table is Latin-only), so ё→е has to be our normalization.
    func testUnicode61DiacriticsAreLatinOnly() throws {
        XCTAssertEqual(try words("мои"), [], "й stays distinct from и")
        let raw = try ProjectIndex(dir: tempDir())
        raw.wordsPerChunk = 50
        // bypass our normalizer: write a body with ё and é directly
        let doc = try raw.addText("x", embed: false)
        try raw.db.run("UPDATE chunks SET body = 'ёлка café' WHERE doc = ?", [.int(doc)])
        let rs = try Searcher(db: raw.db)
        XCTAssertTrue(try rs.rawMatch(table: "chunks_fts", "елка").isEmpty, "unicode61 alone: ё ≠ е")
        XCTAssertFalse(try rs.rawMatch(table: "chunks_fts", "cafe").isEmpty, "Latin é → e is folded")
    }
}
