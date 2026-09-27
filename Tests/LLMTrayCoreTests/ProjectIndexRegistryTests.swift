import XCTest
@testable import LLMTrayCore

final class ProjectIndexRegistryTests: XCTestCase {
    func registry(_ root: URL = indexTempDir()) -> ProjectIndexRegistry {
        ProjectIndexRegistry(directory: { root.appendingPathComponent($0.uuidString) }, idleDelay: 0.05)
    }

    func seed(_ h: ProjectIndexHandle, docs: Int, seed: UInt64 = 31) async throws {
        try await h.write { idx in
            idx.chunker = testChunker
            var gen = CorpusGenerator(seed: seed)
            for i in 0..<docs { try idx.addText(gen.text(words: 300), name: "d\(i).txt") }
        }
    }

    /// The read-only WAL connection keeps searching while the writer holds a
    /// large open transaction; it never sees uncommitted rows and never gets
    /// BUSY. No wall-clock bound: the transaction stays open until every
    /// search has answered, so a search queued behind it would never return
    /// before the release (the writer then reports its wait timed out).
    func testSearchDuringALargeWriteTransaction() async throws {
        let reg = registry()
        let h = try reg.handle(for: UUID())
        try await seed(h, docs: 10)
        let started = expectation(description: "write transaction open")
        let release = DispatchSemaphore(value: 0)
        let writing = Task {
            try await h.write { idx -> Bool in
                try idx.db.transaction {
                    try idx.db.run("INSERT INTO documents(name, ext, sha256, added_at, status) VALUES ('big', 'txt', 'x', 0, 'searchable')")
                    let doc = idx.db.lastInsertRowID
                    try idx.db.run("INSERT INTO pages(doc, rev, page, text) VALUES (?, 1, 1, 'x')", [.int(doc)])
                    var gen = CorpusGenerator(seed: 4)
                    for i in 0..<3000 {   // well past the page cache: pages spill into the WAL uncommitted
                        try idx.db.run("INSERT INTO chunks(doc, rev, page, ord, start, len, body) VALUES (?, 1, 1, ?, 0, 1, ?)",
                                       [.int(doc), .int(Int64(i)), .text(IndexText.normalize(gen.text(words: 120)) + " zzuncommitted")])
                    }
                    started.fulfill()
                    return release.wait(timeout: .now() + 120) == .timedOut
                }
            }
        }
        await fulfillment(of: [started], timeout: 60)
        for q in ["договора", "zzuncommitted", "server config", "поставки", "zzuncommitted"] {
            let r = try await h.search(q)
            if q == "zzuncommitted" { XCTAssertTrue(r.hits.isEmpty, "a reader never sees uncommitted chunks") }
        }
        release.signal()
        let timedOut = try await writing.value
        XCTAssertFalse(timedOut, "every search answered while the write transaction was open")
        let committed = try await h.search("zzuncommitted", options: IndexSearchOptions(limit: 10))
        XCTAssertEqual(committed.hits.count, 2, "one document: the per-document limit")
        var options = IndexSearchOptions(limit: 100, document: 11)
        options.listLimit = 100
        let narrowed = try await h.search("zzuncommitted", options: options)
        XCTAssertEqual(narrowed.hits.count, 100)
        reg.closeAll()
    }

    /// Two tabs searching while the ingest runs: every search answers.
    func testConcurrentSearchesFromTwoTabsDuringIngest() async throws {
        let reg = registry()
        let project = UUID()
        let h = try reg.handle(for: project)
        try await seed(h, docs: 4)
        XCTAssertTrue(try reg.handle(for: project) === h, "one handle per project")
        let ingest = Task { try await self.seed(h, docs: 12, seed: 77) }
        try await withThrowingTaskGroup(of: Int.self) { group in
            for tab in 0..<2 {
                group.addTask {
                    var n = 0
                    for q in ["договор", "server", "оплата", "config", "поставки"] {
                        let v = ToyEmbedder().embed(q)
                        n += try await h.search(q, queryVector: tab == 0 ? v : nil).hits.count
                    }
                    return n
                }
            }
            for try await n in group { XCTAssertGreaterThan(n, 0) }
        }
        try await ingest.value
        let docs = try await h.write { try $0.documents().count }
        XCTAssertEqual(docs, 16)
        reg.close(project)
        do {
            _ = try await h.search("договор")
            XCTFail("closed")
        } catch is ProjectIndexHandle.Closed {}
    }

    /// Compaction swaps the file under the handle's reader: searches issued
    /// while the swap is in progress (held there by a hook) wait, then answer
    /// from the compacted file -- after the swap, with the same hits.
    func testCompactionSwapWithAnOpenReader() async throws {
        let reg = registry()
        let h = try reg.handle(for: UUID())
        try await seed(h, docs: 12)
        try await h.write { idx in for d in try idx.documents().prefix(8) { try idx.remove(doc: d.doc) } }
        let before = try await h.search("договор", queryVector: ToyEmbedder().embed("договор"))
        XCTAssertTrue(before.usedDense)
        let inSwap = DispatchSemaphore(value: 0), searchesIssued = DispatchSemaphore(value: 0)
        let swapped = Flag()
        try await h.write { idx in
            idx.crashHook = { point in
                if point == "swap.movedOld" {
                    inSwap.signal()
                    _ = searchesIssued.wait(timeout: .now() + 60)
                    Thread.sleep(forTimeInterval: 0.1)   // lets the issued searches reach the reader queue
                }
                if point == "swap.movedNew" { swapped.set() }
            }
        }
        let compaction = Task { try await h.compact() }
        await withCheckedContinuation { c in DispatchQueue.global().async { inSwap.wait(); c.resume() } }
        let searches = (0..<8).map { _ in
            Task { () throws -> (hits: [Int64], afterSwap: Bool) in
                let r = try await h.search("договор", queryVector: ToyEmbedder().embed("договор"))
                return (r.hits.map(\.chunk), swapped.isSet)
            }
        }
        searchesIssued.signal()
        try await compaction.value
        for task in searches {
            let r = try await task.value
            XCTAssertEqual(r.hits, before.hits.map(\.chunk))
            XCTAssertTrue(r.afterSwap, "a search issued during the swap answers after it")
        }
        try await h.write { $0.crashHook = nil }
        let after = try await h.search("договор", queryVector: ToyEmbedder().embed("договор"))
        XCTAssertEqual(after.hits.map(\.chunk), before.hits.map(\.chunk))
        let churn = try await h.write { try $0.storage().churn }
        XCTAssertEqual(churn, 0)
        reg.closeAll()
    }

    /// The swap happened but the writer couldn't reopen: the handle fails
    /// clearly (every call throws `Failed`), and the registry replaces it.
    func testAFailedReopenAfterTheSwapFailsTheHandleAndIsReplaced() async throws {
        let reg = registry()
        let project = UUID()
        let h = try reg.handle(for: project)
        try await seed(h, docs: 4)
        try await h.write { idx in idx.crash(at: "swap.movedNew") }
        do {
            try await h.compact()
            XCTFail("compaction should fail")
        } catch {}
        XCTAssertTrue(h.isFailed)
        do {
            _ = try await h.search("договор")
            XCTFail("a failed handle doesn't search")
        } catch is ProjectIndexHandle.Failed {}
        do {
            _ = try await h.write { try $0.documents().count }
            XCTFail("nor write")
        } catch is ProjectIndexHandle.Failed {}
        let fresh = try await reg.open(project)
        XCTAssertFalse(fresh === h)
        let count = try await fresh.write { try $0.documents().count }
        XCTAssertEqual(count, 4)
        let hits = try await fresh.search("договор").hits.count
        XCTAssertGreaterThan(hits, 0)
        reg.closeAll()
    }

    /// Opening one project (its reconcile) doesn't hold up another's.
    func testOpeningOneProjectDoesntWaitForAnother() throws {
        let reg = registry()
        let slow = UUID(), other = UUID()
        let slowLock = reg.lifecycleLock(slow)
        slowLock.lock()   // as if `slow` were opening
        _ = try reg.handle(for: other)
        slowLock.unlock()
        XCTAssertEqual(reg.openProjects, [other])
        _ = try reg.handle(for: slow)
        XCTAssertEqual(reg.openProjects, [slow, other])
        reg.closeAll()
    }

    func testIdleMaintenanceTruncatesTheWAL() async throws {
        let reg = registry()
        let h = try reg.handle(for: UUID())
        try await seed(h, docs: 6)
        _ = try await h.search("договор")
        try await Task.sleep(nanoseconds: 400_000_000)
        let wal = try await h.write { try $0.storage().walBytes }
        // The write above may itself have added a frame or two; the idle pass
        // ran before it.
        XCTAssertLessThan(wal, 64 << 10)
        try await h.maintainNow()
        let walAfter = try await h.write { try $0.storage().walBytes }
        XCTAssertEqual(walAfter, 0)
        reg.closeAll()
    }

    func testVectorsOfAtMostTwoProjectsStayResident() async throws {
        let reg = registry()
        let ids = [UUID(), UUID(), UUID()]
        var handles: [ProjectIndexHandle] = []
        for (i, id) in ids.enumerated() {
            let h = try reg.handle(for: id)
            try await seed(h, docs: 2, seed: UInt64(i + 1))
            handles.append(h)
        }
        for h in handles { _ = try await h.search("договор", queryVector: ToyEmbedder().embed("договор")) }
        XCTAssertEqual(reg.residentVectorProjects, [ids[1], ids[2]])
        XCTAssertEqual(handles[0].residentVectorBytes, 0, "the least recently used was evicted")
        XCTAssertGreaterThan(handles[2].residentVectorBytes, 0)
        _ = try await handles[0].search("договор", queryVector: ToyEmbedder().embed("договор"))
        XCTAssertEqual(reg.residentVectorProjects, [ids[2], ids[0]])
        reg.closeAll()
    }

    func testSummaryWithoutOpeningTheProject() async throws {
        let root = indexTempDir()
        let project = UUID()
        let reg = registry(root)
        let none = try await reg.summary(for: project)
        XCTAssertEqual(none, .empty, "no index yet")
        do {
            let idx = try ProjectIndex.testIndex(root.appendingPathComponent(project.uuidString))
            try idx.addText("индексированный", name: "a.txt")
            try idx.addText("только слова", name: "b.txt", embed: false)
            let src = idx.directory.appendingPathComponent("../c.txt").standardizedFileURL
            try "ждёт".write(to: src, atomically: true, encoding: .utf8)
            _ = try idx.addCopy(of: src)
            idx.close()
        }
        let closed = try await reg.summary(for: project)
        XCTAssertEqual(closed, ProjectIndexSummary(documents: 3, searchable: 2, embedded: 1, pending: 1, failed: 0))
        XCTAssertTrue(reg.openProjects.isEmpty, "read without opening")
        let h = try reg.handle(for: project)
        let open = try await reg.summary(for: project)
        XCTAssertEqual(open, closed)
        try await h.write { idx in try idx.remove(doc: 1) }
        let after = try await h.summary()
        XCTAssertEqual(after.searchable, 1)
        reg.closeAll()
    }

    func testOpeningReconcilesAndReportsWork() async throws {
        let root = indexTempDir()
        let project = UUID()
        let dir = root.appendingPathComponent(project.uuidString)
        do {
            let idx = try ProjectIndex.testIndex(dir)
            try idx.addText("документ без векторов", embed: false)
            idx.close()
        }
        let reg = registry(root)
        let h = try reg.handle(for: project)
        XCTAssertEqual(h.openReport.needEmbedding, [], "no vector set yet: nothing to embed into")
        let r = try await h.search("документ")
        XCTAssertEqual(r.hits.count, 1)
        reg.closeAll()
    }
}

/// Set once, read from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
