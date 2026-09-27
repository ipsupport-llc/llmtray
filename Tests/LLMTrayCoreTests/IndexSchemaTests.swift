import XCTest
@testable import LLMTrayCore

final class IndexSchemaTests: XCTestCase {
    func testRuntimeHasFTS5AndTrigram() throws {
        XCTAssertNoThrow(try IndexSchema.checkRuntime())
        XCTAssertTrue(SQLiteConnection.compileOptionUsed("ENABLE_FTS5"))
        XCTAssertGreaterThanOrEqual(SQLiteConnection.libraryVersionNumber, 3_034_000)
    }

    func testCreatedWithTheFinalLayout() throws {
        let idx = try ProjectIndex.testIndex()
        XCTAssertEqual(try idx.count("SELECT value FROM meta WHERE key = 'schema'"), Int64(IndexSchema.version))
        XCTAssertEqual(try idx.count("PRAGMA page_size"), 16384)
        XCTAssertEqual(try idx.count("PRAGMA auto_vacuum"), 2, "INCREMENTAL")
        XCTAssertEqual(try idx.db.scalarText("PRAGMA journal_mode"), "wal")
        XCTAssertEqual(try idx.count("PRAGMA journal_size_limit"), Int64(IndexSchema.journalSizeLimit))
        XCTAssertEqual(try idx.db.scalarText("SELECT kind FROM sources WHERE id = 1"), "copy")
        for table in ["documents", "pages", "chunks", "chunks_fts", "chunks_tri", "vec_sets", "vec_blocks", "sources", "meta"] {
            XCTAssertEqual(try idx.count("SELECT count(*) FROM sqlite_master WHERE name = ?", [.text(table)]), 1, table)
        }
        // Reopening keeps it (no second create).
        let dir = idx.directory
        idx.close()
        let again = try ProjectIndex(directory: dir)
        XCTAssertEqual(try again.count("PRAGMA page_size"), 16384)
    }

    func testNewerSchemaIsRefusedAndLeftUntouched() throws {
        let idx = try ProjectIndex.testIndex()
        try idx.db.run("UPDATE meta SET value = 99 WHERE key = 'schema'")
        try idx.checkpoint()
        let dir = idx.directory
        idx.close()
        let before = try Data(contentsOf: dir.appendingPathComponent(ProjectIndex.databaseName))
        XCTAssertThrowsError(try ProjectIndex(directory: dir)) { XCTAssertEqual($0 as? ProjectIndexError, .newerSchema(99)) }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(ProjectIndex.databaseName)), before)
    }

    func testOlderOrForeignDatabasesAreRefused() throws {
        let dir = indexTempDir()
        let foreign = try SQLiteConnection(path: dir.appendingPathComponent(ProjectIndex.databaseName).path)
        try foreign.exec("CREATE TABLE t(x)")
        foreign.close()
        XCTAssertThrowsError(try ProjectIndex(directory: dir)) { XCTAssertEqual($0 as? ProjectIndexError, .notAnIndex) }

        let idx = try ProjectIndex.testIndex()
        try idx.db.run("UPDATE meta SET value = 0 WHERE key = 'schema'")
        let d2 = idx.directory
        idx.close()
        XCTAssertFalse(IndexMigration.canMigrate(from: 0))
        XCTAssertThrowsError(try ProjectIndex(directory: d2)) {
            XCTAssertEqual($0 as? ProjectIndexError, .migrationUnavailable(from: 0))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: d2.appendingPathComponent(ProjectIndex.databaseName).path))
    }

    /// Random inserts, updates and deletes; FTS integrity-check (rank = 1
    /// also compares against the content table) after each phase; results
    /// identical before and after 'rebuild'.
    func testTriggersKeepBothFTSInStepAndRebuildChangesNothing() throws {
        let idx = try ProjectIndex.testIndex()
        var gen = CorpusGenerator(seed: 1)
        var added: [Int64] = []
        for i in 0..<12 { added.append(try idx.addText(gen.text(words: 300, russian: i % 3 != 0), name: "d\(i).txt", embed: false)) }
        try idx.integrityCheck()

        var g = SplitMix64(seed: 3)
        let ids = try allChunkIDs(idx.db)
        for _ in 0..<60 {
            let id = ids[Int(g.next() % UInt64(ids.count))]
            try idx.db.run("UPDATE chunks SET body = ? WHERE id = ?", [.text(IndexText.normalize(gen.text(words: 30))), .int(id)])
        }
        try idx.db.run("UPDATE chunks SET ord = ord + 1000 WHERE doc = ?", [.int(added[0])])
        try idx.integrityCheck()

        for d in added.prefix(3) { try idx.remove(doc: d) }
        try idx.db.run("DELETE FROM chunks WHERE id IN (SELECT id FROM chunks ORDER BY random() LIMIT 20)")
        try idx.integrityCheck()

        // A re-index replaces a document's chunks in the same transaction.
        let job = try idx.beginReindex(doc: added[5])
        try idx.commitExtraction(job, pages: ProjectIndex.pages(gen.text(words: 200)))
        try idx.integrityCheck()

        let s = try idx.searcher()
        let queries = ["договора", "поставки", "server config", "parseConfig", "и", "timeout", "оплаты", "ка"]
        var options = IndexSearchOptions()
        options.listLimit = 10_000
        func snapshot() throws -> [[Int64]] {
            try queries.flatMap { q -> [[Int64]] in
                let lq = IndexQuery.build(q)
                return [try s.words(lq, options: options).ids, try s.trigram(lq, options: options).ids]
            }
        }
        let before = try snapshot()
        XCTAssertTrue(before.contains { !$0.isEmpty })
        try idx.rebuildFTS()
        try idx.integrityCheck()
        XCTAssertEqual(before, try snapshot(), "rebuild must not change results")
    }

    /// Trigram MATCH "term" equals a plain substring scan of the bodies.
    func testTrigramEqualsSubstringOracle() throws {
        let idx = try ProjectIndex.testIndex()
        var gen = CorpusGenerator(seed: 5)
        for i in 0..<10 { try idx.addText(gen.text(words: 300), name: "d\(i).txt", embed: false) }
        let s = try idx.searcher()
        for p in ["договор", "оплат", "ция", "config", "0", "20", "ость", "rver", "«", "ов ", "поставки", "parseconfig", "ено"] {
            let viaFTS = Set(try s.rawMatch(table: "chunks_tri", IndexQuery.quote(p)))
            let oracle = Set(try idx.db.rows("SELECT id FROM chunks WHERE instr(body, ?) > 0", [.text(p)]) { $0.int(0) })
            if p.unicodeScalars.count >= 3 {
                XCTAssertEqual(viaFTS, oracle, "trigram vs instr for '\(p)'")
            } else {
                XCTAssertTrue(viaFTS.isEmpty, "'\(p)' (short) matched \(viaFTS.count)")
            }
        }
    }

    /// Chunks written past the trigger desync the index; integrity-check
    /// finds it; 'rebuild' repairs it.
    func testIntegrityCheckFindsDesyncAndRebuildRepairs() throws {
        let idx = try ProjectIndex.testIndex()
        try idx.addText("Договор поставки номер один. " + String(repeating: "слово ", count: 100), embed: false)
        try idx.db.exec("DROP TRIGGER chunks_au")
        try idx.db.run("UPDATE chunks SET body = 'совершенно другой текст' WHERE id = (SELECT min(id) FROM chunks)")
        XCTAssertThrowsError(try idx.integrityCheck())
        let s = try idx.searcher()
        XCTAssertTrue(try s.words(IndexQuery.build("совершенно")).ids.isEmpty)
        try idx.rebuildFTS()
        try idx.integrityCheck()
        XCTAssertFalse(try s.words(IndexQuery.build("совершенно")).ids.isEmpty)
    }

    func testDocAndChunkIDsAreNeverReused() throws {
        let idx = try ProjectIndex.testIndex()
        let a = try idx.addText("первый документ " + String(repeating: "а ", count: 60), name: "a.txt")
        let b = try idx.addText("второй документ " + String(repeating: "б ", count: 60), name: "b.txt")
        let maxChunk = try idx.count("SELECT max(id) FROM chunks")
        try idx.remove(doc: b)
        let c = try idx.addText("третий документ " + String(repeating: "в ", count: 60), name: "c.txt")
        XCTAssertEqual([a, b, c], [1, 2, 3], "a citation [2:1] must not come to point at a new document")
        XCTAssertGreaterThan(try idx.count("SELECT min(id) FROM chunks WHERE doc = ?", [.int(c)]), maxChunk)
        // Compaction (VACUUM INTO) keeps the sequences.
        try idx.remove(doc: c)
        try idx.compact()
        let d = try idx.addText("четвертый документ " + String(repeating: "г ", count: 60), name: "d.txt")
        XCTAssertEqual(d, 4)
    }

    /// Chunk text is quoted verbatim from pages.text by code-point offsets
    /// SQLite's substr() understands, astral characters included.
    func testVerbatimChunkTextFromPageOffsets() throws {
        let idx = try ProjectIndex.testIndex(chunker: IndexChunker(minTokens: 3, maxTokens: 5))
        let text = "😀 Первый 𝔘𝔫𝔦 ДОГОВОР Поставки №5 от 1.02.2025 «ООО Ромашка» e\u{301}clair ИНН 7707083893 конец текста тут"
        let doc = try idx.addText(text)
        let s = try idx.searcher()
        let ids = try idx.db.rows("SELECT id FROM chunks WHERE doc = ? ORDER BY ord", [.int(doc)]) { $0.int(0) }
        XCTAssertGreaterThan(ids.count, 2)
        let rebuilt = try ids.map { try s.fetch($0)!.text }
        XCTAssertEqual(rebuilt.joined(separator: " "), text)
        XCTAssertTrue(rebuilt.joined().contains("ДОГОВОР"), "original case kept for quoting")
    }

    /// The vector load walks vec_blocks by rowid, already in id order: no
    /// temp B-tree sorting every blob (the set_id index made one).
    func testVectorLoadIsARowidRangeScanWithoutASort() throws {
        let idx = try ProjectIndex.testIndex()
        try idx.addText("договор поставки товара")
        let plan = try idx.db.rows("EXPLAIN QUERY PLAN " + DenseVectors.loadSQL, [.int(idx.toySet), .int(0)]) { $0.text(3) }
        XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
        XCTAssertTrue(plan.contains { $0.contains("INTEGER PRIMARY KEY") }, "\(plan)")
        let dense = DenseVectors(setID: idx.toySet, dim: 64)
        try dense.refresh(from: idx.db)
        XCTAssertEqual(dense.count, Int(try idx.count("SELECT count(*) FROM chunks")))
    }

    /// SQLite's substr() stops at U+0000: a NUL in a page would empty every
    /// chunk after it. It is stored as a space, offsets unchanged.
    func testNULInPageTextDoesntCutChunks() throws {
        let idx = try ProjectIndex.testIndex(chunker: IndexChunker(minTokens: 3, maxTokens: 5))
        let text = "Первый абзац\u{0}договора поставки товара и ещё несколько слов после нуля в тексте страницы"
        let doc = try idx.addText(text, embed: false)
        XCTAssertEqual(try idx.count("SELECT count(*) FROM pages WHERE instr(text, char(0)) > 0"), 0)
        let s = try idx.searcher()
        let ids = try idx.db.rows("SELECT id FROM chunks WHERE doc = ? ORDER BY ord", [.int(doc)]) { $0.int(0) }
        XCTAssertGreaterThan(ids.count, 2)
        let rebuilt = try ids.map { try s.fetch($0)!.text }
        XCTAssertFalse(rebuilt.contains(""), "no chunk comes back empty")
        XCTAssertEqual(rebuilt.joined(separator: " "), text.replacingOccurrences(of: "\u{0}", with: " "))
        let pending = try idx.pendingChunks(doc: doc, set: idx.toySet, limit: 100)
        XCTAssertEqual(pending.count, ids.count)
        XCTAssertFalse(pending.contains { $0.text.isEmpty })
        XCTAssertEqual(try s.search("нуля").hits.count, 1)
    }
}
