import XCTest
@testable import LLMTrayCore

/// The ingest protocol and reconcile (adr/0012, Consistency): a crash at
/// each point -- a thrown SimulatedCrash: nothing after it runs, the open
/// transaction rolls back, the connection is dropped -- then a fresh open
/// and reconcile. Before reconcile a document is invisible or complete;
/// after it there are no orphans or duplicates.
final class ProjectIndexCrashTests: XCTestCase {
    func text(marker: String, seed: UInt64) -> String {
        var gen = CorpusGenerator(seed: seed)
        return (0..<3).map { _ in
            (0..<4).map { _ in gen.sentence(russian: true) + " \(marker)." }.joined(separator: " ") + " " + gen.text(words: 80)
        }.joined(separator: "\u{0C}")
    }

    func markerChunks(_ t: String, _ marker: String) -> Int {
        testChunker.chunk(pages: ProjectIndex.pages(t).map { ($0.page, $0.text) }).filter { $0.body.contains(marker) }.count
    }
    func chunkCount(_ t: String) -> Int { testChunker.chunk(pages: ProjectIndex.pages(t).map { ($0.page, $0.text) }).count }

    func hits(_ idx: ProjectIndex, _ word: String) throws -> Int {
        var o = IndexSearchOptions()
        o.listLimit = 100_000
        return try idx.searcher().words(IndexQuery.build(word), options: o).ids.count
    }

    struct World { let dir: URL; let a: Int64; let b: Int64?; let bFile: URL; let bText: String; let aText: String }

    func world(withB: Bool) throws -> World {
        let dir = indexTempDir()
        let idx = try ProjectIndex.testIndex(dir)
        let aText = text(marker: "альфамаркер", seed: 1)
        let a = try idx.addText(aText, name: "a.txt")
        let bText = text(marker: "бетамаркер", seed: 2)
        let bFile = dir.deletingLastPathComponent().appendingPathComponent("\(dir.lastPathComponent)-b.txt")
        try bText.write(to: bFile, atomically: true, encoding: .utf8)
        var b: Int64?
        if withB {
            b = try idx.addCopy(of: bFile)
            try idx.extract(b!)
            try idx.embedAll(b!, batch: 4)
        }
        idx.close()
        return World(dir: dir, a: a, b: b, bFile: bFile, bText: bText, aText: aText)
    }

    func assertConsistent(_ idx: ProjectIndex, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNoThrow(try idx.integrityCheck(), label, file: file, line: line)
        let fm = FileManager.default
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: idx.stagingDirectory.path), [], "staging empty: \(label)", file: file, line: line)
        var names = Set<String>()
        for d in try idx.documents() {
            names.insert("\(d.doc).\(d.ext)")
            XCTAssertNotEqual(d.status, .removing, label, file: file, line: line)
            XCTAssertNotEqual(d.status, .extracting, label, file: file, line: line)
            XCTAssertFalse(d.sha256.isEmpty, "hash recorded: \(label)", file: file, line: line)
        }
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: idx.filesDirectory.path)), names, "files ↔ rows: \(label)", file: file, line: line)
        XCTAssertEqual(try idx.count("""
            SELECT count(*) FROM chunks c LEFT JOIN documents d ON d.doc = c.doc
            WHERE d.doc IS NULL OR d.status NOT IN ('searchable','embedded') OR c.rev != d.rev
            """), 0, "orphan or stale chunks: \(label)", file: file, line: line)
        var seen = Set<Int64>()
        for blob in try idx.db.rows("SELECT chunk_ids FROM vec_blocks", [], { $0.data(0) }) {
            for id in blob.withUnsafeBytes({ DenseVectors.decodeIDs($0) }) {
                XCTAssertTrue(seen.insert(id).inserted, "duplicate vector: \(label)", file: file, line: line)
            }
        }
        XCTAssertTrue(seen.isSubset(of: Set(try allChunkIDs(idx.db))), "vectors without chunks: \(label)", file: file, line: line)
    }

    /// What the app does after reconcile.
    func resume(_ idx: ProjectIndex, _ r: ReconcileReport) throws {
        for d in r.needExtraction { try idx.extract(d); try idx.embedAll(d, batch: 4) }
        for d in r.needEmbedding { try idx.embedAll(d, batch: 4) }
    }

    func testCrashDuringAdd() throws {
        let points: [(String, Int)] = [("add.row", 1), ("add.copied", 1), ("add.hashed", 1), ("add.recorded", 1), ("add.promoted", 1),
                                       ("extract.begun", 1), ("extract.midTransaction", 1), ("extract.beforeCommit", 1),
                                       ("embed.block", 1), ("embed.block", 3)]
        for (point, occurrence) in points {
            let label = "\(point)#\(occurrence)"
            let w = try world(withB: false)
            do {
                let idx = try ProjectIndex.testIndex(w.dir)
                idx.crash(at: point, occurrence: occurrence)
                XCTAssertThrowsError(try {
                    let b = try idx.addCopy(of: w.bFile)
                    try idx.extract(b)
                    try idx.embedAll(b, batch: 4)
                }(), label) { XCTAssertEqual($0 as? SimulatedCrash, SimulatedCrash(point: point)) }
                idx.close()
            }
            let bHits = markerChunks(w.bText, "бетамаркер")
            let idx = try ProjectIndex.testIndex(w.dir)
            let pre = try hits(idx, "бетамаркер")
            XCTAssertTrue(pre == 0 || pre == bHits, "\(label): a partial document visible before reconcile (\(pre))")
            let report = try idx.reconcile()
            let post = try hits(idx, "бетамаркер")
            XCTAssertTrue(post == 0 || post == bHits, label)
            XCTAssertEqual(try hits(idx, "альфамаркер"), markerChunks(w.aText, "альфамаркер"), label)
            try resume(idx, report)
            try assertConsistent(idx, "\(label) after resume")
            let lost = ["add.row", "add.copied", "add.hashed"].contains(point)
            XCTAssertEqual(try hits(idx, "бетамаркер"), lost ? 0 : bHits, "\(label) after resume")
            let b = try idx.documents().first { $0.name == w.bFile.lastPathComponent }
            XCTAssertEqual(b?.status, lost ? nil : .embedded, label)
            if let b {
                XCTAssertEqual(try idx.count("SELECT count(*) FROM chunks WHERE doc = ?", [.int(b.doc)]), Int64(chunkCount(w.bText)), label)
                XCTAssertEqual(try idx.count("SELECT sum(n) FROM vec_blocks WHERE doc = ?", [.int(b.doc)]), Int64(chunkCount(w.bText)),
                               "\(label): every chunk embedded exactly once")
            }
            // A second reconcile finds nothing to do.
            let again = try idx.reconcile()
            XCTAssertEqual(again.droppedStaged + again.promoted + again.resetExtracting + again.finishedRemoving + again.deletedPartials, 0, label)
        }
    }

    func testCrashDuringRemove() throws {
        for point in ["remove.marked", "remove.fileDeleted", "remove.midTransaction"] {
            let w = try world(withB: true)
            do {
                let idx = try ProjectIndex.testIndex(w.dir)
                idx.crash(at: point)
                XCTAssertThrowsError(try idx.remove(doc: w.b!), point)
                idx.close()
            }
            let idx = try ProjectIndex.testIndex(w.dir)
            XCTAssertEqual(try hits(idx, "бетамаркер"), 0, "\(point): a document being removed never answers, even before reconcile")
            let report = try idx.reconcile()
            XCTAssertEqual(report.finishedRemoving, 1, point)
            try assertConsistent(idx, point)
            XCTAssertNil(try idx.status(w.b!), point)
            XCTAssertEqual(try hits(idx, "альфамаркер"), markerChunks(w.aText, "альфамаркер"), point)
            XCTAssertGreaterThan(try idx.count("SELECT count(*) FROM pages WHERE doc = ?", [.int(w.b!)]), 0, "\(point): pages kept as tombstones")
        }
    }

    func testCrashDuringReindexKeepsTheOldRevision() throws {
        for point in ["reindex.deleted", "extract.midTransaction", "extract.beforeCommit"] {
            let w = try world(withB: true)
            do {
                let idx = try ProjectIndex.testIndex(w.dir)
                idx.crash(at: point)
                let job = try idx.beginReindex(doc: w.b!)
                XCTAssertThrowsError(try idx.commitExtraction(job, pages: ProjectIndex.pages(text(marker: "гаммамаркер", seed: 3))), point)
                idx.close()
            }
            let idx = try ProjectIndex.testIndex(w.dir)
            XCTAssertEqual(try hits(idx, "бетамаркер"), markerChunks(w.bText, "бетамаркер"), "\(point): old revision complete before reconcile")
            _ = try idx.reconcile()
            try assertConsistent(idx, point)
            XCTAssertEqual(try hits(idx, "бетамаркер"), markerChunks(w.bText, "бетамаркер"), "\(point): old revision complete")
            XCTAssertEqual(try hits(idx, "гаммамаркер"), 0, point)
            XCTAssertEqual(try idx.document(w.b!)?.rev, 1)
            XCTAssertEqual(try idx.document(w.b!)?.status, .embedded)
        }
    }

    func testCrashDuringCompactionIsFinishedOrRolledBack() throws {
        for point in ["compact.optimized", "compact.vacuumed", "swap.movedOld", "swap.movedNew"] {
            let w = try world(withB: true)
            do {
                let idx = try ProjectIndex.testIndex(w.dir)
                try idx.remove(doc: w.a)
                idx.crash(at: point)
                XCTAssertThrowsError(try idx.compact(), point)
                idx.close()
            }
            let idx = try ProjectIndex.testIndex(w.dir)
            _ = try idx.reconcile()
            try assertConsistent(idx, point)
            XCTAssertEqual(try hits(idx, "бетамаркер"), markerChunks(w.bText, "бетамаркер"), point)
            XCTAssertEqual(try hits(idx, "альфамаркер"), 0, point)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: w.dir.path).filter {
                $0.hasPrefix("index.") && !$0.hasPrefix("index.sqlite")
            }
            XCTAssertEqual(leftovers, [], point)
            XCTAssertEqual(try idx.count("PRAGMA page_size"), 16384, point)
        }
    }
}

final class ProjectIndexLifecycleTests: XCTestCase {
    func testAddRefusesDuplicatesAndKeepsNoTrace() throws {
        let idx = try ProjectIndex.testIndex()
        let a = try idx.addText("одинаковый текст", name: "a.txt")
        XCTAssertThrowsError(try idx.addText("одинаковый текст", name: "b.txt")) {
            XCTAssertEqual($0 as? ProjectIndexError, .duplicate(existing: a))
        }
        XCTAssertEqual(try idx.documents().map(\.doc), [a])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: idx.stagingDirectory.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: idx.filesDirectory.path), ["\(a).txt"])
        XCTAssertThrowsError(try idx.addCopy(of: idx.directory.appendingPathComponent("missing.txt")))
        XCTAssertEqual(try idx.documents().count, 1, "a failed copy leaves no row")
        idx.freeSpace = { 10 }
        XCTAssertThrowsError(try idx.addText("новый", name: "c.txt")) {
            guard case .insufficientDisk? = $0 as? ProjectIndexError else { return XCTFail("\($0)") }
        }
    }

    func testStatusesThroughTheLifecycle() throws {
        let idx = try ProjectIndex.testIndex()
        let src = idx.directory.appendingPathComponent("../x.txt").standardizedFileURL
        try "текст документа".write(to: src, atomically: true, encoding: .utf8)
        let doc = try idx.addCopy(of: src)
        XCTAssertEqual(try idx.status(doc), .staged)
        let job = try idx.beginExtraction(doc: doc)
        XCTAssertEqual(try idx.status(doc), .extracting)
        XCTAssertEqual(try idx.commitExtraction(job, pages: [ExtractedPage(page: 1, text: "текст документа")]), .searchable)
        XCTAssertThrowsError(try idx.commitExtraction(job, pages: []), "a job commits once") {
            XCTAssertEqual($0 as? ProjectIndexError, .stale(doc))
        }
        try idx.embedAll(doc)
        XCTAssertEqual(try idx.status(doc), .embedded)

        // Empty, failed and unsupported documents.
        try "x".write(to: src, atomically: true, encoding: .utf8)
        let empty = try idx.addCopy(of: src, name: "empty.pdf")
        XCTAssertEqual(try idx.commitExtraction(try idx.beginExtraction(doc: empty), pages: [ExtractedPage(page: 1, text: "  \n")]), .empty)
        try "y".write(to: src, atomically: true, encoding: .utf8)
        let broken = try idx.addCopy(of: src)
        try idx.failExtraction(try idx.beginExtraction(doc: broken), error: "timeout")
        XCTAssertEqual(try idx.document(broken)?.status, .failed)
        XCTAssertEqual(try idx.document(broken)?.error, "timeout")
        try "z".write(to: src, atomically: true, encoding: .utf8)
        let odd = try idx.addCopy(of: src)
        try idx.failExtraction(try idx.beginExtraction(doc: odd), error: "xls", unsupported: true)
        XCTAssertEqual(try idx.status(odd), .unsupported)

        // A junk or failed page is stored, not indexed.
        let jobPages = try idx.beginReindex(doc: doc)
        XCTAssertEqual(try idx.commitExtraction(jobPages, pages: [
            ExtractedPage(page: 1, text: "хороший текст"), ExtractedPage(page: 2, text: "Äîãîâîð", junk: 0.9),
            ExtractedPage(page: 3, text: "", error: "render failed"),
        ]), .searchable)
        XCTAssertEqual(try idx.db.rows("SELECT page, status FROM pages WHERE doc = ? AND rev = 2 ORDER BY page", [.int(doc)]) { "\($0.int(0)):\($0.text(1))" },
                       ["1:ok", "2:failed", "3:failed"])
        XCTAssertEqual(try idx.count("SELECT count(DISTINCT page) FROM chunks WHERE doc = ?", [.int(doc)]), 1)
        XCTAssertEqual(try idx.status(doc), .searchable, "a new revision needs its vectors")
        let failedReindex = try idx.beginReindex(doc: doc)
        try idx.failExtraction(failedReindex, error: "gone")
        XCTAssertEqual(try idx.document(doc)?.rev, 2, "a failed re-index keeps the current revision")
        XCTAssertEqual(try idx.status(doc), .searchable)
    }

    func testStopAndResume() throws {
        let idx = try ProjectIndex.testIndex()
        let src = idx.directory.appendingPathComponent("../s.txt").standardizedFileURL
        try "первый".write(to: src, atomically: true, encoding: .utf8)
        let done = try idx.addText("уже проиндексирован", name: "done.txt")
        let waiting = try idx.addCopy(of: src)
        let job = try idx.beginExtraction(doc: waiting)
        XCTAssertEqual(try idx.stopIndexing(), 1)
        XCTAssertEqual(try idx.status(waiting), .notIndexed)
        XCTAssertEqual(try idx.status(done), .embedded, "what's indexed stays")
        XCTAssertThrowsError(try idx.commitExtraction(job, pages: ProjectIndex.pages("первый")), "the in-flight job is stale")
        XCTAssertTrue(try idx.reconcile().needExtraction.isEmpty, "a stopped document isn't resumed by reconcile")
        XCTAssertEqual(try idx.resumeIndexing(), [waiting])
        XCTAssertEqual(try idx.reconcile().needExtraction, [waiting])
        try idx.extract(waiting)
        XCTAssertEqual(try idx.status(waiting), .searchable)
    }

    func testReindexTombstonesAndTheCitationSweep() throws {
        let idx = try ProjectIndex.testIndex()
        let doc = try idx.addText("страница один\u{0C}страница два про договор\u{0C}страница три")
        let other = try idx.addText("другой документ", name: "other.txt")
        let job = try idx.beginReindex(doc: doc)
        try idx.commitExtraction(job, pages: ProjectIndex.pages("новая один\u{0C}новая два"))
        let s = try idx.searcher()
        XCTAssertEqual(try s.page(doc: doc, rev: 1, page: 2)?.text, "страница два про договор")
        XCTAssertEqual(try s.page(doc: doc, rev: 1, page: 2)?.isCurrent, false, "a tombstone: the file has changed since")
        XCTAssertEqual(try s.page(doc: doc, rev: 2, page: 2)?.isCurrent, true)
        XCTAssertTrue(try s.search("договор").hits.isEmpty, "a tombstone isn't searchable")
        XCTAssertEqual(try idx.storage().tombstonePages, 3)
        try idx.remove(doc: other)
        XCTAssertEqual(try idx.storage().tombstonePages, 4, "a removed document's pages stay until swept")

        let cited: Set<PageRef> = [PageRef(doc: doc, rev: 1, page: 2), PageRef(doc: other, rev: 1, page: 1), PageRef(doc: 99, rev: 1, page: 1)]
        XCTAssertEqual(try idx.sweepTombstones(keeping: cited), 2)
        XCTAssertNotNil(try s.page(doc: doc, rev: 1, page: 2))
        XCTAssertNil(try s.page(doc: doc, rev: 1, page: 1))
        XCTAssertNotNil(try s.page(doc: other, rev: 1, page: 1))
        XCTAssertEqual(try idx.sweepTombstones(keeping: cited), 0, "idempotent")
        XCTAssertEqual(try idx.sweepTombstones(keeping: []), 2, "the citation went (edited answer, deleted chat)")
        XCTAssertEqual(try idx.count("SELECT count(*) FROM pages WHERE doc = ?", [.int(doc)]), 2, "current pages are never swept")
    }

    func testLinkedFolderFilesAreNeverTouched() throws {
        let idx = try ProjectIndex.testIndex()
        let folder = indexTempDir("linked")
        let file = folder.appendingPathComponent("notes/plan.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# План\n\nСвязанный файл про договор.".write(to: file, atomically: true, encoding: .utf8)
        let source = try idx.addFolderSource(path: folder.path)
        let doc = try idx.addLinkedDocument(source: source, relativePath: "notes/plan.md", mtime: 1, sha256: "abc", bytes: 10)
        XCTAssertEqual(try idx.reconcile().needExtraction, [doc])
        let job = try idx.beginExtraction(doc: doc)
        XCTAssertEqual(job.file.standardizedFileURL, file.standardizedFileURL)
        try idx.commitExtraction(job, pages: ProjectIndex.pages(try String(contentsOf: job.file, encoding: .utf8)))
        XCTAssertEqual(try idx.searcher().search("договор").hits.first?.doc, doc)
        XCTAssertEqual(try idx.searcher().search("договор").hits.first?.heading, "План")
        _ = try idx.reconcile()
        try idx.removeSource(source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a linked folder's file is the user's")
        XCTAssertNil(try idx.status(doc))
        XCTAssertEqual(try idx.count("SELECT count(*) FROM sources"), 1)
    }

    func testReconcileLeavesForeignFilesAndDropsOrphans() throws {
        let idx = try ProjectIndex.testIndex()
        let a = try idx.addText("документ", name: "a.txt")
        let fm = FileManager.default
        fm.createFile(atPath: idx.filesDirectory.appendingPathComponent("77.pdf").path, contents: Data("orphan".utf8))
        fm.createFile(atPath: idx.filesDirectory.appendingPathComponent("readme").path, contents: Data("not ours".utf8))
        fm.createFile(atPath: idx.stagingDirectory.appendingPathComponent("12.part").path, contents: Data())
        fm.createFile(atPath: idx.stagingDirectory.appendingPathComponent("13.docx").path, contents: Data())
        let r = try idx.reconcile()
        XCTAssertEqual(r.deletedOrphanFiles, 1)
        XCTAssertEqual(r.deletedPartials, 1)
        XCTAssertEqual(r.deletedOrphanStaging, 1)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: idx.filesDirectory.path)), ["\(a).txt", "readme"])
    }

    func testEmbedderSwitchBuildsASeparateSetAndFlipsInOneTransaction() throws {
        let idx = try ProjectIndex.testIndex()
        let doc = try idx.addText("документ про поставку товара", name: "a.txt")
        let old = idx.toySet
        XCTAssertEqual(try idx.activeVectorSet()?.id, old)
        let new = try idx.vectorSet(model: "other", dim: 64, prepVersion: 1)
        XCTAssertFalse(new.isActive)
        XCTAssertEqual(try idx.documentsToEmbed(set: new.id), [doc])
        XCTAssertEqual(try idx.documentsToEmbed(set: old), [])
        let pending = try idx.pendingChunks(doc: doc, set: new.id, limit: 100)
        try idx.commitVectors(doc: doc, rev: pending[0].rev, set: new.id, chunks: pending.map(\.id),
                              vectors: pending.flatMap { ToyEmbedder().embed($0.text + "!").map(Float16.init) })
        XCTAssertTrue(try idx.documentsToEmbed(set: new.id).isEmpty)
        // A repeated commit adds nothing.
        try idx.commitVectors(doc: doc, rev: pending[0].rev, set: new.id, chunks: pending.map(\.id),
                              vectors: pending.flatMap { ToyEmbedder().embed($0.text).map(Float16.init) })
        XCTAssertEqual(try idx.count("SELECT sum(n) FROM vec_blocks WHERE set_id = ?", [.int(new.id)]), Int64(pending.count))
        try idx.activate(set: new.id)
        XCTAssertEqual(try idx.activeVectorSet()?.id, new.id)
        XCTAssertEqual(try idx.vectorSets().count, 1)
        XCTAssertEqual(try idx.status(doc), .embedded)
        XCTAssertThrowsError(try idx.commitVectors(doc: doc, rev: 99, set: new.id, chunks: [], vectors: []))
    }

    func testMaintenanceVacuumAndCompaction() throws {
        let idx = try ProjectIndex.testIndex()
        var gen = CorpusGenerator(seed: 8)
        var docs: [Int64] = []
        for i in 0..<30 { docs.append(try idx.addText(gen.text(words: 400), name: "d\(i).txt")) }
        try idx.checkpoint()
        let full = try idx.storage()
        XCTAssertEqual(full.walBytes, 0, "TRUNCATE checkpoint")
        for d in docs.prefix(20) { try idx.remove(doc: d) }
        _ = try idx.sweepTombstones(keeping: [])
        let churned = try idx.storage()
        XCTAssertTrue(churned.needsCompaction, "\(churned)")
        XCTAssertGreaterThan(churned.freePages, 0)
        XCTAssertGreaterThan(try idx.incrementalVacuum(pages: 10_000), 0)
        try idx.checkpoint()
        XCTAssertEqual(try idx.storage().freePages, 0)
        XCTAssertLessThan(try idx.storage().fileBytes, full.fileBytes, "the routine step returns pages to the OS")

        let before = try idx.searcher().search("договор поставки", options: IndexSearchOptions(limit: 10)).hits.map(\.chunk)
        try idx.compact()
        let after = try idx.storage()
        XCTAssertEqual(after.churn, 0)
        XCTAssertFalse(after.needsCompaction)
        XCTAssertEqual(try idx.count("PRAGMA page_size"), 16384, "VACUUM INTO keeps the page size")
        XCTAssertEqual(try idx.count("PRAGMA auto_vacuum"), 2, "and incremental auto-vacuum")
        XCTAssertEqual(try idx.db.scalarText("PRAGMA journal_mode"), "wal")
        try idx.integrityCheck()
        XCTAssertEqual(try idx.searcher().search("договор поставки", options: IndexSearchOptions(limit: 10)).hits.map(\.chunk), before)
        idx.freeSpace = { 1 }
        XCTAssertThrowsError(try idx.compact()) {
            guard case .insufficientDisk? = $0 as? ProjectIndexError else { return XCTFail("\($0)") }
        }
    }
}
