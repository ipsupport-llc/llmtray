import XCTest
@testable import LLMTrayCore

final class ProjectIndexPresentationTests: XCTestCase {
    func progress(_ state: ProjectIndexProgress.State, stage: IngestStage? = .reading, total: Int = 450, done: Int = 119,
                  failed: Int = 0, eta: Double? = nil, wordsOnly: Bool = false) -> ProjectIndexProgress {
        ProjectIndexProgress(state: state, stage: stage, total: total, done: done, failed: failed, remainingSeconds: eta, wordsOnly: wordsOnly)
    }

    // MARK: - the ring

    func testTheFolderWhenNothingHappens() {
        XCTAssertEqual(ProjectRing(progress: nil, failedDocuments: 0), .folder)
        XCTAssertEqual(ProjectRing(progress: .idle, failedDocuments: 0), .folder)
        XCTAssertFalse(ProjectRing.folder.isShown)
    }

    func testTheRingFillsWithFinishedFiles() {
        let ring = ProjectRing(progress: progress(.running, done: 100, failed: 20), failedDocuments: 0)
        XCTAssertEqual(ring.kind, .indexing)
        XCTAssertEqual(ring.fraction!, 120.0 / 450.0, accuracy: 1e-9)
        XCTAssertEqual(ring.failed, 20)
        XCTAssertTrue(ring.isActive)
        XCTAssertNil(ProjectRing(progress: progress(.running, stage: .copying, total: 0, done: 0), failedDocuments: 0).fraction,
                     "copying in: no count yet")
        XCTAssertEqual(ProjectRing(progress: progress(.running, total: 3, done: 5), failedDocuments: 0).fraction, 1, "clamped")
    }

    func testPausedWaitingAndFailed() {
        XCTAssertEqual(ProjectRing(progress: progress(.paused), failedDocuments: 0).kind, .paused)
        XCTAssertEqual(ProjectRing(progress: progress(.waiting), failedDocuments: 2).kind, .waiting)
        let failed = ProjectRing(progress: .idle, failedDocuments: 3)
        XCTAssertEqual(failed.kind, .failed)
        XCTAssertEqual(failed.failed, 3)
        XCTAssertTrue(failed.isShown)
        XCTAssertFalse(failed.isActive, "nothing to pause or stop")
        XCTAssertEqual(ProjectRing(progress: progress(.running, failed: 1), failedDocuments: 4).failed, 4, "the project's count when larger")
    }

    // MARK: - the text

    let text = ProjectIndexStatusText()

    func testTheUsersExample() {
        XCTAssertEqual(text.text(progress: progress(.running, eta: 20 * 60), failedDocuments: 0),
                       "Indexing 120 of 450 files · reading · ~20 min left")
    }

    func testCountsNeverPassTheTotal() {
        XCTAssertEqual(text.text(progress: progress(.running, stage: .embedding, total: 2, done: 2), failedDocuments: 0),
                       "Indexing 2 of 2 files · embedding")
        XCTAssertEqual(text.text(progress: progress(.running, stage: .copying, total: 0, done: 0), failedDocuments: 0),
                       "Adding files · copying")
    }

    func testPausedWaitingFailedWordsOnly() {
        XCTAssertEqual(text.text(progress: progress(.paused, eta: 600), failedDocuments: 0), "Paused at 119 of 450 files",
                       "no stage or time while paused")
        XCTAssertEqual(text.text(progress: progress(.paused, total: 0, done: 0), failedDocuments: 0), "Paused")
        XCTAssertEqual(text.text(progress: progress(.waiting, eta: 600), failedDocuments: 0),
                       "Waiting for the chat or a generator to finish · Indexing 120 of 450 files · reading",
                       "no time left while waiting: it isn't counting down")
        XCTAssertEqual(text.text(progress: progress(.running, failed: 2, wordsOnly: true), failedDocuments: 0),
                       "Indexing 122 of 450 files · reading · 2 failed · search by words only")
        XCTAssertEqual(text.text(progress: .idle, failedDocuments: 3), "3 files couldn't be indexed")
        XCTAssertNil(text.text(progress: nil, failedDocuments: 0))
    }

    func testTimeLeftIsRough() {
        XCTAssertEqual(text.timeLeft(12), "less than a minute left")
        XCTAssertEqual(text.timeLeft(61), "~1 min left")
        XCTAssertEqual(text.timeLeft(59 * 60 + 10), "~59 min left")
        XCTAssertEqual(text.timeLeft(3600), "~1 h left")
        XCTAssertEqual(text.timeLeft(3600 + 11 * 60), "~1 h 10 min left")
        XCTAssertEqual(text.timeLeft(2 * 3600 + 58 * 60), "~3 h left", "5-minute steps")
        XCTAssertEqual(text.timeLeft(14.4 * 3600), "~14 h left")
        XCTAssertEqual(text.timeLeft(.infinity), "less than a minute left")
        XCTAssertEqual(text.timeLeft(-5), "less than a minute left")
    }

    func testLocalizedStringsAreUsed() {
        var s = ProjectIndexStatusText.Strings()
        s.indexing = "Индексация: %1$lld из %2$lld"
        s.reading = "чтение"
        s.separator = " — "
        XCTAssertEqual(ProjectIndexStatusText(strings: s).text(progress: progress(.running), failedDocuments: 0), "Индексация: 120 из 450 — чтение")
    }

    // MARK: - drops

    func testDropsAreSortedByFormat() {
        let u = { (n: String) in URL(fileURLWithPath: "/tmp/in/" + n) }
        let sorted = ProjectFileDrop.sort([
            (u("a.pdf"), false), (u("b.PPTX"), false), (u("c.md"), false), (u("Folder"), true), (u(".DS_Store"), false),
            (u("Makefile"), false), (u("a.pdf"), false), (u("photo.png"), false), (u("main.swift"), false),
            (URL(string: "https://example.com/x.pdf")!, false),
        ])
        XCTAssertEqual(sorted.accepted.map(\.lastPathComponent), ["a.pdf", "c.md", "Makefile", "main.swift"], "each once, in order")
        XCTAssertEqual(sorted.notSupported.map(\.lastPathComponent), ["b.PPTX", "photo.png"])
        XCTAssertEqual(sorted.folders.map(\.lastPathComponent), ["Folder"])
        XCTAssertTrue(ProjectFileDrop.sort([(u(".hidden"), false)]).isEmpty)
    }

    func testDroppedURLsAreLookedUpInOrder() async throws {
        let dir = indexTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for name in ["b.md", "a.txt", "deck.pptx"] {
            try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try fm.createDirectory(at: dir.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        // A package is one file to the user (refused as a format, not as a folder).
        try fm.createDirectory(at: dir.appendingPathComponent("Tool.app/Contents"), withIntermediateDirectories: true)
        let urls = ["b.md", "Folder", "a.txt", "Tool.app", "deck.pptx", "missing.pdf", ".DS_Store"].map { dir.appendingPathComponent($0) }
        let sorted = await Task { @MainActor in await ProjectFileDrop.sort(urls) }.value
        XCTAssertEqual(sorted.accepted.map(\.lastPathComponent), ["b.md", "a.txt", "missing.pdf"], "in the order dropped")
        XCTAssertEqual(sorted.notSupported.map(\.lastPathComponent), ["Tool.app", "deck.pptx"])
        XCTAssertEqual(sorted.folders.map(\.lastPathComponent), ["Folder"])
    }

    func testNamesForAMessage() {
        let urls = ["a", "b", "c", "d", "e"].map { URL(fileURLWithPath: "/x/\($0).xlsx") }
        let n = ProjectFileDrop.names(urls)
        XCTAssertEqual(n.shown, ["a.xlsx", "b.xlsx", "c.xlsx"])
        XCTAssertEqual(n.more, 2)
        XCTAssertEqual(ProjectFileDrop.names(Array(urls.prefix(1))).more, 0)
    }

    // MARK: - totals

    func testTotals() {
        func doc(_ n: Int64, _ status: DocumentStatus, pages: Int?, bytes: Int64) -> IndexedDocument {
            IndexedDocument(doc: n, source: 1, rev: 1, name: "\(n)", ext: "txt", relativePath: nil, sha256: "", bytes: bytes,
                            status: status, kind: nil, pages: pages, error: nil)
        }
        let t = ProjectFileTotals([
            doc(1, .embedded, pages: 3, bytes: 100), doc(2, .searchable, pages: 1, bytes: 10), doc(3, .failed, pages: nil, bytes: 5),
            doc(4, .unsupported, pages: nil, bytes: 5), doc(5, .notIndexed, pages: nil, bytes: 5), doc(6, .removing, pages: 9, bytes: 99),
            doc(7, .staged, pages: nil, bytes: 1),
        ])
        XCTAssertEqual(t.files, 6)
        XCTAssertEqual(t.searchable, 2)
        XCTAssertEqual(t.pages, 4)
        XCTAssertEqual(t.bytes, 126)
        XCTAssertEqual(t.failed, 2)
        XCTAssertEqual(t.notIndexed, 1)
    }

    func testAFailedReindexCountsAsFailed() throws {
        let dir = indexTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = try ProjectIndex(directory: dir)
        defer { index.close() }
        let doc = try index.addText("Some words to search.", name: "a.txt")
        XCTAssertEqual(ProjectFileTotals(try index.documents()).failed, 0)
        let job = try index.beginReindex(doc: doc)
        try index.failExtraction(job, error: "corrupt")
        let docs = try index.documents()
        XCTAssertTrue(docs[0].status.isSearchable, "the earlier revision still searchable")
        XCTAssertEqual(docs[0].error, "corrupt")
        let t = ProjectFileTotals(docs)
        XCTAssertEqual(t.failed, 1, "the ring's ⚠︎")
        XCTAssertEqual(t.searchable, 1)
    }

    func testAQueuedReindexShowsAsQueued() {
        XCTAssertEqual(DocumentDisplayStatus(.embedded, reindexQueued: true), .queued)
        XCTAssertEqual(DocumentDisplayStatus(.embedded, activity: .reading, reindexQueued: true), .reading)
        XCTAssertEqual(DocumentDisplayStatus(.embedded), .ready)
    }

    // MARK: - a project chat's status line

    private func doc(_ n: Int64, _ status: DocumentStatus, error: String? = nil) -> IndexedDocument {
        IndexedDocument(doc: n, source: 1, rev: 1, name: "f\(n).txt", ext: "txt", relativePath: nil, sha256: "", bytes: 1,
                        status: status, kind: nil, pages: nil, error: error)
    }

    private func chatStatus(_ docs: [IndexedDocument], progress: ProjectIndexProgress? = nil) -> ProjectChatStatus {
        let totals = ProjectFileTotals(docs)
        return ProjectChatStatus(totals: totals, ring: ProjectRing(progress: progress, failedDocuments: totals.failed))
    }

    func testChatStatusStates() {
        XCTAssertEqual(chatStatus([]), .noFiles)
        // Removing ones don't count.
        XCTAssertEqual(chatStatus([doc(1, .removing)]), .noFiles)
        XCTAssertEqual(chatStatus([doc(1, .embedded), doc(2, .searchable)]), .indexed(failed: 0))
        XCTAssertEqual(chatStatus([doc(1, .embedded), doc(2, .failed)]), .indexed(failed: 1))
        XCTAssertEqual(chatStatus([doc(1, .failed), doc(2, .unsupported)]), .failed(2))
        XCTAssertEqual(chatStatus([doc(1, .notIndexed)]), .notIndexed)
        XCTAssertEqual(chatStatus([doc(1, .empty)]), .indexed(failed: 0))
    }

    func testChatStatusIndexingWinsWhileTheRingRuns() {
        XCTAssertEqual(chatStatus([doc(1, .staged)], progress: progress(.running)), .indexing)
        XCTAssertEqual(chatStatus([doc(1, .embedded)], progress: progress(.paused)), .indexing)
        XCTAssertEqual(chatStatus([doc(1, .embedded)], progress: progress(.waiting)), .indexing)
        // Idle progress is nothing under way.
        XCTAssertEqual(chatStatus([doc(1, .embedded)], progress: .idle), .indexed(failed: 0))
        // Just added, before the run's ring shows it: not "Indexed".
        XCTAssertEqual(chatStatus([doc(1, .staged), doc(2, .extracting)], progress: .idle), .indexing)
    }

    func testChatStatusFailureLines() {
        let docs = [doc(1, .embedded), doc(2, .failed, error: "encrypted PDF"), doc(3, .unsupported),
                    doc(4, .embedded, error: "re-index failed"), doc(5, .removing, error: "x")]
        XCTAssertEqual(ProjectChatStatus.failureLines(docs), ["f2.txt: encrypted PDF", "f3.txt", "f4.txt: re-index failed"])
        XCTAssertEqual(ProjectChatStatus.failureLines(docs, limit: 1), ["f2.txt: encrypted PDF"])
    }
}
