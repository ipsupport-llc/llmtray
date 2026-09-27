import XCTest
import SQLite3
@testable import RAGIndex

final class SchemaTests: XCTestCase {
    func testRuntimeHasFTS5AndReportsVersion() throws {
        let info = Schema.runtimeInfo()
        print("SQLite \(info.version), FTS5 \(info.fts5), load_extension \(info.loadExtension)")
        XCTAssertTrue(info.fts5)
        XCTAssertFalse(info.loadExtension, "Apple's SQLite is OMIT_LOAD_EXTENSION")
        // trigram needs 3.34, remove_diacritics 2 needs 3.27
        let parts = info.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertTrue(parts[0] > 3 || parts[1] >= 34)
    }

    func testMetaSchemaRecorded() throws {
        let idx = try ProjectIndex(dir: tempDir())
        XCTAssertEqual(try idx.db.scalarInt("SELECT value FROM meta WHERE key='schema'"), Int64(Schema.version))
    }

    /// Random inserts, updates and deletes; FTS integrity-check (rank=1, which also
    /// compares against the content table) after each phase; results identical
    /// before and after 'rebuild'.
    func testTriggersKeepBothFTSInStepAndRebuildIsIdempotent() throws {
        let idx = try ProjectIndex(dir: tempDir())
        idx.wordsPerChunk = 60
        var gen = CorpusGenerator(seed: 1)
        var added: [Int64] = []
        for i in 0..<30 { added.append(try idx.addText(gen.text(words: 600, russian: i % 3 != 0), embed: false)) }
        try Schema.integrityCheck(idx.db)

        // updates through the trigger (body change) and a no-op-for-FTS update (ord)
        var g = SplitMix64(seed: 3)
        let ids = try allChunkIDs(idx.db)
        for _ in 0..<200 {
            let id = ids[Int(g.next() % UInt64(ids.count))]
            try idx.db.run("UPDATE chunks SET body = ? WHERE id = ?", [.text(Normalizer.normalize(gen.text(words: 50))), .int(id)])
        }
        try idx.db.run("UPDATE chunks SET ord = ord + 1000 WHERE doc = ?", [.int(added[0])])
        try Schema.integrityCheck(idx.db)

        // deletes: whole documents, and single chunks
        for d in added.prefix(5) { try idx.remove(doc: d) }
        try idx.db.run("DELETE FROM chunks WHERE id IN (SELECT id FROM chunks ORDER BY random() LIMIT 50)")
        try Schema.integrityCheck(idx.db)

        let s = try Searcher(db: idx.db)
        let queries = ["договора", "поставки", "server config", "parseConfig", "и", "timeout", "неустойку оплаты", "ка"]
        func snapshot() throws -> [[Int64]] {
            try queries.flatMap { q -> [[Int64]] in
                let lq = QueryBuilder.build(q)
                return [try s.words(lq, limit: 10_000), try s.trigram(lq, limit: 10_000)]
            }
        }
        let before = try snapshot()
        XCTAssertTrue(before.contains { !$0.isEmpty })
        try Schema.rebuild(idx.db)
        try Schema.integrityCheck(idx.db)
        XCTAssertEqual(before, try snapshot(), "rebuild must not change results")
    }

    /// Trigram MATCH "term" must equal a plain substring scan on the normalized body.
    func testTrigramEqualsSubstringOracle() throws {
        let idx = try ProjectIndex(dir: tempDir())
        idx.wordsPerChunk = 50
        var gen = CorpusGenerator(seed: 5)
        for _ in 0..<20 { try idx.addText(gen.text(words: 500), embed: false) }
        let s = try Searcher(db: idx.db)
        let probes = ["договор", "оплат", "ция", "config", "0", "20", "тель", "ость", "rver", "«", "ов ", "поставки",
                      "обязательств", "parseconfig", "ено"]
        for p in probes {
            let esc = "\"" + p.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let viaFTS = Set(try s.rawMatch(table: "chunks_tri", esc))
            var oracle = Set<Int64>()
            let st = try idx.db.prepare("SELECT id FROM chunks WHERE instr(body, ?) > 0")
            try st.bind([.text(p)])
            while try st.step() { oracle.insert(st.int(0)) }
            if p.unicodeScalars.count >= 3 {
                XCTAssertEqual(viaFTS, oracle, "trigram vs instr for '\(p)'")
            } else {
                // <3 chars: the trigram table matches nothing, silently
                XCTAssertTrue(viaFTS.isEmpty, "'\(p)' (short) unexpectedly matched \(viaFTS.count)")
            }
        }
    }

    /// Writing chunks without the trigger desyncs the index; integrity-check
    /// catches it; 'rebuild' repairs it.
    func testIntegrityCheckDetectsDesyncAndRebuildRepairs() throws {
        let idx = try ProjectIndex(dir: tempDir())
        idx.wordsPerChunk = 20
        try idx.addText("Договор поставки номер один. " + String(repeating: "слово ", count: 100), embed: false)
        try idx.db.exec("DROP TRIGGER chunks_au")
        try idx.db.run("UPDATE chunks SET body = 'совершенно другой текст' WHERE id = (SELECT min(id) FROM chunks)")
        XCTAssertThrowsError(try Schema.integrityCheck(idx.db)) { print("integrity-check on desynced index: \($0)") }
        let s = try Searcher(db: idx.db)
        XCTAssertTrue(try s.words(QueryBuilder.build("совершенно")).isEmpty, "stale index doesn't see the new text")
        try Schema.rebuild(idx.db)
        try Schema.integrityCheck(idx.db)
        XCTAssertFalse(try s.words(QueryBuilder.build("совершенно")).isEmpty)
    }

    func testDocAndChunkIDsAreNeverReused() throws {
        let idx = try ProjectIndex(dir: tempDir())
        idx.wordsPerChunk = 10
        let a = try idx.addText("первый документ " + String(repeating: "а ", count: 30))
        let b = try idx.addText("второй документ " + String(repeating: "б ", count: 30))
        let maxChunk = try idx.db.scalarInt("SELECT max(id) FROM chunks")!
        try idx.remove(doc: b)
        let c = try idx.addText("третий документ " + String(repeating: "в ", count: 30))
        XCTAssertEqual(a, 1); XCTAssertEqual(b, 2)
        XCTAssertEqual(c, 3, "a citation [2:1] must not start pointing at a new document")
        XCTAssertGreaterThan(try idx.db.scalarInt("SELECT min(id) FROM chunks WHERE doc = ?", [.int(c)])!, maxChunk)
    }

    /// Chunk text is quoted verbatim from pages.text via code-point offsets that
    /// SQLite's substr() understands (astral-plane characters included).
    func testVerbatimChunkTextFromPageOffsets() throws {
        let idx = try ProjectIndex(dir: tempDir())
        idx.wordsPerChunk = 5
        let text = "😀 Первый 𝔘𝔫𝔦 ДОГОВОР Поставки №5 от 1.02.2025 «ООО Ромашка» e\u{301}clair ИНН 7707083893 конец текста тут"
        let doc = try idx.addText(text)
        let s = try Searcher(db: idx.db)
        var rebuilt: [String] = []
        let st = try idx.db.prepare("SELECT id FROM chunks WHERE doc = ? ORDER BY ord")
        try st.bind([.int(doc)])
        var ids: [Int64] = []
        while try st.step() { ids.append(st.int(0)) }
        for id in ids { rebuilt.append(try s.fetch(id)!.text) }
        XCTAssertEqual(rebuilt.joined(separator: " "), text)
        XCTAssertTrue(rebuilt[0].contains("ДОГОВОР"), "original case kept for quoting")
    }
}

func allChunkIDs(_ db: Database) throws -> [Int64] {
    let st = try db.prepare("SELECT id FROM chunks")
    var out: [Int64] = []
    while try st.step() { out.append(st.int(0)) }
    return out
}
