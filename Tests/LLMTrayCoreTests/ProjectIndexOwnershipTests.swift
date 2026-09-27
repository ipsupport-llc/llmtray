import XCTest
@testable import LLMTrayCore

/// Who may touch a project's files and connections: one owner per project
/// (the lock), a compaction that never installs a copy older than the file,
/// linked paths that can't leave their folder, copies trusted only by
/// their hash, and connections that answer on their own queue only.
final class ProjectIndexOwnershipTests: XCTestCase {
    /// A second index of the same project -- a second handle, or another
    /// process -- is refused while the first is open, and gets it after.
    func testASecondOwnerOfTheSameProjectIsRefused() throws {
        let dir = indexTempDir()
        let first = try ProjectIndex.testIndex(dir)
        try first.addText("договор поставки", name: "a.txt")
        XCTAssertThrowsError(try ProjectIndex(directory: dir)) { XCTAssertEqual($0 as? ProjectIndexError, .inUse) }
        let reg = ProjectIndexRegistry(directory: { _ in dir }, idleDelay: 0.05)
        XCTAssertThrowsError(try reg.handle(for: UUID())) { XCTAssertEqual($0 as? ProjectIndexError, .inUse) }
        XCTAssertEqual(try first.count("SELECT count(*) FROM documents"), 1, "the refused open changed nothing")
        first.close()
        let second = try ProjectIndex.testIndex(dir)
        XCTAssertEqual(try second.count("SELECT count(*) FROM documents"), 1)
        second.close()
        let h = try reg.handle(for: UUID())
        XCTAssertThrowsError(try ProjectIndex(directory: dir), "the registry's handle owns it now") {
            XCTAssertEqual($0 as? ProjectIndexError, .inUse)
        }
        reg.closeAll()
        XCTAssertNoThrow(try ProjectIndex(directory: dir).close(), "closing the handle gives the project up")
        _ = h
    }

    /// A commit from another connection after VACUUM INTO read the file:
    /// the (older) copy is dropped, the live file and its new row stay.
    func testACompactionNeverInstallsACopyOlderThanTheFile() throws {
        let idx = try ProjectIndex.testIndex()
        var gen = CorpusGenerator(seed: 5)
        for i in 0..<6 { try idx.addText(gen.text(words: 200), name: "d\(i).txt") }
        try idx.remove(doc: 1)
        idx.crashHook = { point in
            guard point == "compact.vacuumed" else { return }
            let other = try SQLiteConnection(path: idx.databaseURL.path)
            try other.run("INSERT INTO documents(name, ext, sha256, added_at, status) VALUES ('late', 'txt', 'late', 0, 'failed')")
            other.close()
        }
        XCTAssertThrowsError(try idx.compact()) { XCTAssertEqual($0 as? ProjectIndexError, .changedDuringCompaction) }
        idx.crashHook = nil
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: idx.directory.appendingPathComponent(CompactionSwap.compactName).path))
        XCTAssertFalse(fm.fileExists(atPath: idx.directory.appendingPathComponent(CompactionSwap.markerName).path))
        XCTAssertEqual(try idx.count("SELECT count(*) FROM documents WHERE name = 'late'"), 1, "the late write kept")
        XCTAssertGreaterThan(try idx.storage().churn, 0, "not compacted")
        // A connection still open at the swap (it could commit after any check):
        // nothing is moved.
        var other: SQLiteConnection?
        idx.crashHook = { point in
            guard point == "compact.checked" else { return }
            other = try SQLiteConnection(path: idx.databaseURL.path)
            try other?.run("INSERT INTO documents(name, ext, sha256, added_at, status) VALUES ('later', 'txt', 'later', 0, 'failed')")
        }
        XCTAssertThrowsError(try idx.compact()) { XCTAssertEqual($0 as? ProjectIndexError, .changedDuringCompaction, "\($0)") }
        idx.crashHook = nil
        other?.close()
        XCTAssertFalse(fm.fileExists(atPath: idx.directory.appendingPathComponent(CompactionSwap.compactName).path))
        XCTAssertFalse(fm.fileExists(atPath: idx.directory.appendingPathComponent(CompactionSwap.markerName).path))
        XCTAssertEqual(try idx.count("SELECT count(*) FROM documents WHERE name = 'later'"), 1, "the later write kept")

        try idx.compact()
        XCTAssertEqual(try idx.count("SELECT count(*) FROM documents WHERE name IN ('late', 'later')"), 2, "and in the compacted file")
        XCTAssertEqual(try idx.storage().churn, 0)
    }

    /// Closing a leaked index doesn't give the project up behind its owner.
    func testALeakedIndexCantReleaseTheLock() async throws {
        let dir = indexTempDir()
        let reg = ProjectIndexRegistry(directory: { _ in dir }, idleDelay: 0.05)
        let h = try reg.handle(for: UUID())
        let leak = Leak()
        try await h.write { leak.index = $0 }
        leak.index?.close()
        XCTAssertThrowsError(try ProjectIndex(directory: dir)) { XCTAssertEqual($0 as? ProjectIndexError, .inUse) }
        let n = try await h.write { try $0.documents().count }
        XCTAssertEqual(n, 0, "the owner still works")
        leak.index = nil
        reg.closeAll()
    }

    /// Symlinks in a linked folder: one to a file or directory outside it is
    /// never followed out; one to a file inside resolves to that file.
    func testLinkedSymlinksCantLeaveTheFolder() throws {
        let idx = try ProjectIndex.testIndex()
        let fm = FileManager.default
        let folder = indexTempDir("linkedfolder")
        let outside = indexTempDir("outside")
        try "секрет".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try "внутри".write(to: folder.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("escape.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("up.txt").path, withDestinationPath: "../\(outside.lastPathComponent)/secret.txt")
        try fm.createSymbolicLink(at: folder.appendingPathComponent("sub"), withDestinationURL: outside)
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("alias.txt").path, withDestinationPath: "inside.txt")
        let source = try idx.addFolderSource(path: folder.path)
        for rel in ["escape.txt", "up.txt", "sub/secret.txt", "missing.txt"] {
            let doc = try idx.addLinkedDocument(source: source, relativePath: rel, mtime: 1, sha256: "x", bytes: 1)
            XCTAssertNil(try idx.file(of: try XCTUnwrap(idx.document(doc))), rel)
            XCTAssertThrowsError(try idx.beginExtraction(doc: doc), rel) { XCTAssertEqual($0 as? ProjectIndexError, .stale(doc)) }
        }
        let alias = try idx.addLinkedDocument(source: source, relativePath: "alias.txt", mtime: 1, sha256: "x", bytes: 1)
        let resolved = try XCTUnwrap(idx.file(of: try XCTUnwrap(idx.document(alias))))
        XCTAssertEqual(resolved.lastPathComponent, "inside.txt")
        XCTAssertEqual(try String(contentsOf: try idx.beginExtraction(doc: alias).file, encoding: .utf8), "внутри")
    }

    /// Reconcile hashes a promoted copy before trusting it: a torn one is
    /// replaced by a matching staged copy, else kept (the only one) and
    /// `failed` -- never dropped as an unfinished add.
    func testReconcileVerifiesAPromotedCopy() throws {
        let dir = indexTempDir()
        let src = dir.deletingLastPathComponent().appendingPathComponent("\(dir.lastPathComponent)-src.txt")
        try String(repeating: "договор поставки товара. ", count: 200).write(to: src, atomically: true, encoding: .utf8)
        do {
            let idx = try ProjectIndex.testIndex(dir)
            idx.crash(at: "add.promoted")
            XCTAssertThrowsError(try idx.addCopy(of: src))
            idx.close()
        }
        let final = dir.appendingPathComponent("files/1.txt")
        try Data("договор".utf8).write(to: final)   // torn: shorter than the recorded hash
        do {
            let idx = try ProjectIndex.testIndex(dir)
            let r = try idx.reconcile()
            XCTAssertEqual(r.damagedCopies, 1)
            XCTAssertEqual(r.droppedStaged, 0)
            XCTAssertEqual(try idx.status(1), .failed)
            XCTAssertTrue(FileManager.default.fileExists(atPath: final.path), "the only copy is kept")
            XCTAssertEqual(r.needExtraction, [])
            idx.close()
        }

        // The same with the staged copy still there and whole: it wins.
        let dir2 = indexTempDir()
        do {
            let idx = try ProjectIndex.testIndex(dir2)
            idx.crash(at: "add.recorded")
            XCTAssertThrowsError(try idx.addCopy(of: src))
            idx.close()
        }
        let final2 = dir2.appendingPathComponent("files/1.txt")
        try Data("до".utf8).write(to: final2)
        let idx = try ProjectIndex.testIndex(dir2)
        let r = try idx.reconcile()
        XCTAssertEqual(r.promoted, 1)
        XCTAssertEqual(r.needExtraction, [1])
        XCTAssertEqual(try ProjectIndex.sha256(of: final2), try ProjectIndex.sha256(of: src))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: idx.stagingDirectory.path), [])
    }

    /// A 10k-chunk document embedded in batches of 64: a late batch costs
    /// what an early one does (SQLite VM operations, not the clock) -- the
    /// cursor, not a scan of what's embedded already.
    func testEmbeddingBatchCostDoesntGrowWithTheDocument() throws {
        let idx = try ProjectIndex.testIndex()
        let set = idx.toySet
        try idx.db.transaction {
            try idx.db.run("INSERT INTO documents(name, ext, sha256, added_at, status) VALUES ('big', 'txt', 'big', 0, 'searchable')")
            try idx.db.run("INSERT INTO pages(doc, rev, page, text) VALUES (1, 1, 1, 'абвгд')")
            for i in 0..<10_000 {
                try idx.db.run("INSERT INTO chunks(doc, rev, page, ord, start, len, body) VALUES (1, 1, 1, ?, 0, 5, 'абвгд')", [.int(Int64(i))])
            }
        }
        var costs: [Int64] = []
        let zero = [Float16](repeating: 0, count: 64 * 64)
        while true {
            let before = idx.db.vmSteps
            let pending = try idx.pendingChunks(doc: 1, set: set, limit: 64)
            guard !pending.isEmpty else { break }
            try idx.commitVectors(doc: 1, rev: 1, set: set, chunks: pending.map(\.id), vectors: Array(zero.prefix(pending.count * 64)))
            costs.append(idx.db.vmSteps - before)
        }
        XCTAssertEqual(costs.count, (10_000 + 63) / 64)
        XCTAssertEqual(try idx.status(1), .embedded)
        XCTAssertEqual(try idx.count("SELECT sum(n) FROM vec_blocks"), 10_000)
        let early = costs.prefix(10).reduce(0, +) / 10
        let late = costs.dropLast().suffix(10).reduce(0, +) / 10
        XCTAssertLessThan(late, early * 2, "per-batch cost: early \(early), late \(late) VM steps")
        // A repeated batch adds nothing, and is as cheap.
        let ids = try idx.db.rows("SELECT id FROM chunks ORDER BY ord LIMIT 64") { $0.int(0) }
        let again = idx.db.vmSteps
        XCTAssertTrue(try idx.commitVectors(doc: 1, rev: 1, set: set, chunks: ids, vectors: zero))
        XCTAssertLessThan(idx.db.vmSteps - again, early * 2)
        XCTAssertEqual(try idx.count("SELECT sum(n) FROM vec_blocks"), 10_000)
    }

    /// Chunks embedded out of order still end complete, each exactly once.
    func testOutOfOrderBatchesCompleteTheDocument() throws {
        let idx = try ProjectIndex.testIndex()
        var gen = CorpusGenerator(seed: 12)
        let doc = try idx.addText(gen.text(words: 600), embed: false)
        let set = idx.toySet
        let all = try idx.pendingChunks(doc: doc, set: set, limit: 1000)
        XCTAssertGreaterThan(all.count, 8)
        func commit(_ chunks: ArraySlice<PendingChunk>) throws -> Bool {
            try idx.commitVectors(doc: doc, rev: 1, set: set, chunks: chunks.map(\.id),
                                  vectors: chunks.flatMap { ToyEmbedder().embed($0.text).map(Float16.init) })
        }
        XCTAssertFalse(try commit(all[4...]), "the head is still missing")
        XCTAssertEqual(try idx.pendingChunks(doc: doc, set: set, limit: 1000).map(\.id), all.prefix(4).map(\.id))
        XCTAssertTrue(try commit(all[0..<4]))
        XCTAssertEqual(try idx.status(doc), .embedded)
        XCTAssertEqual(try idx.count("SELECT sum(n) FROM vec_blocks"), Int64(all.count))
    }

    final class Leak: @unchecked Sendable {
        var index: ProjectIndex?
        var searcher: IndexSearcher?
    }

    /// A ProjectIndex or IndexSearcher taken out of its closure answers
    /// nothing (SQLITE_MISUSE) instead of racing its queue; the handle keeps
    /// working. residentVectorBytes inside a read doesn't deadlock.
    func testConnectionsDontWorkOutsideTheirQueue() async throws {
        let reg = ProjectIndexRegistry(directory: { [root = indexTempDir()] in root.appendingPathComponent($0.uuidString) }, idleDelay: 0.05)
        let h = try reg.handle(for: UUID())
        try await h.write { idx in
            idx.chunker = testChunker
            try idx.addText("договор поставки товара", name: "a.txt")
        }
        let leak = Leak()
        try await h.write { leak.index = $0 }
        try await h.read { leak.searcher = $0 }
        XCTAssertThrowsError(try leak.index?.documents()) { XCTAssertEqual(($0 as? SQLiteError)?.primaryCode, 21) }
        XCTAssertThrowsError(try leak.searcher?.search("договор")) { XCTAssertEqual(($0 as? SQLiteError)?.primaryCode, 21) }
        _ = try await h.search("договор", queryVector: ToyEmbedder().embed("договор"))
        let resident = try await h.read { _ in h.residentVectorBytes }
        XCTAssertGreaterThan(resident, 0, "answered from inside the read")
        XCTAssertEqual(h.residentVectorBytes, resident)
        let n = try await h.write { try $0.documents().count }
        XCTAssertEqual(n, 1, "the owner still works")
        leak.index = nil
        leak.searcher = nil
        reg.closeAll()
    }
}
