import XCTest
import SQLite3
@testable import RAGIndex

final class ConcurrencyTests: XCTestCase {
    /// A read-only WAL connection keeps searching while the writer holds a large
    /// open transaction; it never sees uncommitted rows and never gets BUSY.
    func testReaderDoesNotBlockDuringWriteTransaction() throws {
        let idx = try ProjectIndex(dir: tempDir())
        idx.wordsPerChunk = 50
        var gen = CorpusGenerator(seed: 31)
        for _ in 0..<20 { try idx.addText(gen.text(words: 1000), embed: false) }
        let reader = try Database(path: idx.dbURL.path, readOnly: true)
        let s = try Searcher(db: reader)
        let doc = try idx.db.transaction { () -> Int64 in
            try idx.db.run("INSERT INTO documents(name, ext, sha256, bytes, added_at, status) VALUES ('big','txt','x',0,0,'searchable')")
            return idx.db.lastInsertRowID
        }
        try idx.db.exec("BEGIN IMMEDIATE")
        try idx.db.run("INSERT INTO pages(doc, rev, page, text) VALUES (?, 1, 1, 'x')", [.int(doc)])
        let ins = try idx.db.prepare("INSERT INTO chunks(doc, rev, page, ord, body, start, len) VALUES (?, 1, 1, ?, ?, 0, 1)")
        for i in 0..<3000 {   // well past the 2 MB page cache: pages spill into the WAL uncommitted
            try ins.bind([.int(doc), .int(Int64(i)), .text(Normalizer.normalize(gen.text(words: 250)) + " zzuncommitted")])
            try ins.step()
        }
        var maxMs = 0.0
        for q in ["договора", "zzuncommitted", "server config", "поставки"] {
            let a = ContinuousClock.now
            let ids = try s.words(QueryBuilder.build(q))
            maxMs = max(maxMs, ms(ContinuousClock.now - a))
            if q == "zzuncommitted" { XCTAssertTrue(ids.isEmpty, "reader must not see uncommitted chunks") }
        }
        print("reader max latency during open 3k-chunk write txn: \(maxMs) ms")
        XCTAssertLessThan(maxMs, 500)
        try idx.db.exec("COMMIT")
        XCTAssertEqual(try s.words(QueryBuilder.build("zzuncommitted"), limit: 10_000).count, 3000)
    }
}

/// Kills a child process (ragbench crash) at each ingestion point, then
/// reconciles and checks that only complete documents answer queries.
final class CrashTests: XCTestCase {
    var ragbench: URL {
        Bundle(for: CrashTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ragbench")
    }

    static let words = 40

    func text(marker: String, seed: UInt64) -> String {
        var gen = CorpusGenerator(seed: seed)
        return (0..<3).map { _ in (0..<6).map { _ in gen.sentence(russian: true) + " \(marker)." }.joined(separator: " ") + " " + gen.text(words: 150) }
            .joined(separator: "\u{0C}")
    }

    func expectedChunks(_ t: String) -> Int {
        t.components(separatedBy: "\u{0C}").enumerated().reduce(0) { $0 + Chunker.chunk(pageText: $1.element, page: $1.offset + 1, firstOrd: 0, wordsPerChunk: Self.words).count }
    }

    func markerChunks(_ t: String, _ marker: String) -> Int {
        t.components(separatedBy: "\u{0C}").enumerated().reduce(0) {
            $0 + Chunker.chunk(pageText: $1.element, page: $1.offset + 1, firstOrd: 0, wordsPerChunk: Self.words).filter { $0.body.contains(marker) }.count
        }
    }
    var aHits: Int { markerChunks(text(marker: "альфамаркер", seed: 1), "альфамаркер") }

    func runChild(_ args: [String]) throws -> (killed: Bool, out: String) {
        let p = Process()
        p.executableURL = ragbench
        p.arguments = ["crash", "--words", "\(Self.words)"] + args
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGKILL, out)
    }

    struct World {
        let dir: URL; let a: Int64; let b: Int64?; let bFile: URL; let bText: String
    }

    /// Doc A complete; for remove/reindex also doc B complete.
    func setUpWorld(withB: Bool) throws -> World {
        let dir = tempDir()
        let idx = try ProjectIndex(dir: dir)
        idx.wordsPerChunk = Self.words
        let a = try idx.addText(text(marker: "альфамаркер", seed: 1))
        let bText = text(marker: "бетамаркер", seed: 2)
        let bFile = dir.appendingPathComponent("../\(dir.lastPathComponent)-b.txt").standardizedFileURL
        try bText.write(to: bFile, atomically: true, encoding: .utf8)
        var b: Int64?
        if withB { b = try idx.add(file: bFile) }
        return World(dir: dir, a: a, b: b, bFile: bFile, bText: bText)
    }

    func hits(_ idx: ProjectIndex, _ word: String) throws -> Int {
        try Searcher(db: idx.db).words(QueryBuilder.build(word), limit: 100_000).count
    }

    /// Invariants that must hold after reconcile, whatever the crash point.
    func assertConsistent(_ idx: ProjectIndex, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNoThrow(try Schema.integrityCheck(idx.db), label, file: file, line: line)
        let fm = FileManager.default
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: idx.stagingDir.path), [], "staging empty: \(label)", file: file, line: line)
        let rows = try idx.db.prepare("SELECT doc, ext, status FROM documents")
        var names = Set<String>()
        while try rows.step() {
            names.insert("\(rows.int(0)).\(rows.text(1))")
            XCTAssertNotEqual(rows.text(2), "removing", label, file: file, line: line)
            XCTAssertNotEqual(rows.text(2), "extracting", label, file: file, line: line)
        }
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: idx.filesDir.path)), names, "files ↔ rows: \(label)", file: file, line: line)
        // no chunks for documents that are not searchable
        XCTAssertEqual(try idx.db.scalarInt("""
            SELECT count(*) FROM chunks c LEFT JOIN documents d ON d.doc = c.doc
            WHERE d.doc IS NULL OR d.status NOT IN ('searchable','embedded')
            """), 0, "orphan chunks: \(label)", file: file, line: line)
        // every searchable document has its complete chunk set for its rev
        XCTAssertEqual(try idx.db.scalarInt("""
            SELECT count(*) FROM chunks c JOIN documents d ON d.doc = c.doc WHERE c.rev != d.rev
            """), 0, "stale-rev chunks: \(label)", file: file, line: line)
        // vectors: no duplicates, none for vanished chunks
        let vb = try idx.db.prepare("SELECT chunk_ids FROM vec_blocks")
        var seen = Set<Int64>()
        while try vb.step() { for id in ProjectIndex.decodeIDs(vb.blob(0)) { XCTAssertTrue(seen.insert(id).inserted, "dup vector \(label)", file: file, line: line) } }
        let chunkIDs = Set(try allChunkIDs(idx.db))
        XCTAssertTrue(seen.isSubset(of: chunkIDs), "vectors without chunks: \(label)", file: file, line: line)
    }

    func testCrashDuringAdd() throws {
        let points = ["staging.copied", "staging.hashed", "staged.row", "staged.promoted", "extracting.set",
                      "extracting.midtxn", "extracting.beforecommit", "searchable.committed",
                      "embedding.batchcommitted", "embedding.midtxn", "embedded.committed"]
        for point in points {
            let w = try setUpWorld(withB: false)
            let child = try runChild(["--dir", w.dir.path, "--op", "add", "--at", point, "--file", w.bFile.path])
            XCTAssertTrue(child.killed, "\(point): \(child.out)")
            let full = expectedChunks(w.bText)
            let bHits = markerChunks(w.bText, "бетамаркер")
            let idx = try ProjectIndex(dir: w.dir)
            idx.wordsPerChunk = Self.words
            // before reconcile: B is either invisible or complete
            let pre = try hits(idx, "бетамаркер")
            XCTAssertTrue(pre == 0 || pre == bHits, "\(point): partial doc visible before reconcile (\(pre))")
            let report = try idx.reconcile()
            try assertConsistent(idx, "\(point) after reconcile")
            XCTAssertEqual(try hits(idx, "альфамаркер"), aHits, point)
            let post = try hits(idx, "бетамаркер")
            XCTAssertTrue(post == 0 || post == bHits, point)
            // resume queued work
            for d in report.needExtraction { try idx.extract(doc: d); try idx.embed(doc: d) }
            for d in report.needEmbedding { try idx.embed(doc: d) }
            try assertConsistent(idx, "\(point) after resume")
            let lost = point.hasPrefix("staging.")
            XCTAssertEqual(try hits(idx, "бетамаркер"), lost ? 0 : bHits, "\(point) after resume")
            let bStatus = try idx.db.scalarText("SELECT status FROM documents WHERE name = ?", [.text(w.bFile.lastPathComponent)])
            XCTAssertEqual(bStatus, lost ? nil : "embedded", point)
            if !lost {
                let bDoc = try idx.db.scalarInt("SELECT doc FROM documents WHERE name = ?", [.text(w.bFile.lastPathComponent)])!
                XCTAssertEqual(try idx.db.scalarInt("SELECT count(*) FROM chunks WHERE doc = ?", [.int(bDoc)]), Int64(full), point)
                XCTAssertEqual(try idx.db.scalarInt("SELECT sum(n) FROM vec_blocks WHERE doc = ?", [.int(bDoc)]), Int64(full), "\(point): every chunk embedded exactly once")
            }
            print("crash at \(point): pre-reconcile hits \(pre); reconcile \(report)")
        }
    }

    func testCrashDuringRemove() throws {
        for point in ["removing.set", "removing.filedeleted", "removing.midtxn"] {
            let w = try setUpWorld(withB: true)
            let child = try runChild(["--dir", w.dir.path, "--op", "remove", "--at", point, "--doc", "\(w.b!)"])
            XCTAssertTrue(child.killed, "\(point): \(child.out)")
            let idx = try ProjectIndex(dir: w.dir)
            XCTAssertEqual(try hits(idx, "бетамаркер"), 0, "\(point): a document being removed must not answer, even before reconcile")
            let report = try idx.reconcile()
            try assertConsistent(idx, point)
            XCTAssertNil(try idx.status(w.b!), point)
            XCTAssertEqual(try hits(idx, "альфамаркер"), aHits, point)
            print("crash at \(point): reconcile \(report)")
        }
    }

    func testCrashDuringReindexKeepsOldRevision() throws {
        for point in ["reindex.deletedold", "reindex.midtxn"] {
            let w = try setUpWorld(withB: true)
            let newFile = w.dir.appendingPathComponent("new.txt")
            try text(marker: "гаммамаркер", seed: 3).write(to: newFile, atomically: true, encoding: .utf8)
            let child = try runChild(["--dir", w.dir.path, "--op", "reindex", "--at", point, "--doc", "\(w.b!)", "--file", newFile.path])
            XCTAssertTrue(child.killed, "\(point): \(child.out)")
            try FileManager.default.removeItem(at: newFile)
            let idx = try ProjectIndex(dir: w.dir)
            _ = try idx.reconcile()
            try assertConsistent(idx, point)
            XCTAssertEqual(try hits(idx, "бетамаркер"), markerChunks(w.bText, "бетамаркер"), "\(point): old revision still complete")
            XCTAssertEqual(try hits(idx, "гаммамаркер"), 0, point)
            XCTAssertEqual(try idx.db.scalarInt("SELECT rev FROM documents WHERE doc = ?", [.int(w.b!)]), 1)
        }
    }
}
