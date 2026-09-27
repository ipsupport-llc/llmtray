import XCTest
@testable import LLMTrayCore

/// Stands in for the embed runner: ToyEmbedder's vectors, small batches (so
/// a document takes several slices), optional failures and a delay.
final class FakeEmbedder: ProjectEmbedder, @unchecked Sendable {
    let model = "toy@1"
    let dim = 64
    let prepVersion = 1
    let maxTexts = 256
    var tokensPerBatch = 60
    var delay: TimeInterval = 0
    /// Thrown by every request while set.
    var failure: Error?
    /// A request with a text containing this is refused (`.runner`).
    var refuse: String?
    /// The next this many requests fail with the runner's own timeout.
    var timeouts = 0
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    func documentBatches(_ texts: [String]) -> [Range<Int>] {
        EmbedRunner.batches(texts.map { IndexText.estimatedTokens($0) }, maxTokens: tokensPerBatch, maxTexts: maxTexts)
    }

    func embedDocuments(_ texts: [String]) async throws -> EmbedResult {
        lock.withLock { _calls += 1 }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if let failure { throw failure }
        if lock.withLock({ () -> Bool in
            guard timeouts > 0 else { return false }
            timeouts -= 1
            return true
        }) {
            throw EmbedRunner.Failure.runner(code: "timeout", message: "slow")
        }
        if let refuse, texts.contains(where: { $0.contains(refuse) }) {
            throw EmbedRunner.Failure.runner(code: "bad_request", message: "refused")
        }
        let toy = ToyEmbedder(dim: dim)
        let v = texts.flatMap { toy.embed($0).map(Float16.init) }
        return EmbedResult(dim: dim, count: texts.count, vectors: v, tokens: texts.map { _ in 1 }, truncated: [], milliseconds: 1)
    }
}

/// A test's stand-in extractor: the file's text, pages split at form feeds;
/// "UNSUPPORTED", "EMPTY" or "BROKEN" as the text make it fail that way;
/// "SLOW" waits for `gate` (or cancellation) first.
final class FakeExtractor: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var open = false
    var calls: Int { lock.withLock { _calls } }
    func release() { lock.withLock { open = true } }

    func extract(_ url: URL) async throws -> DocumentExtraction.Document {
        lock.withLock { _calls += 1 }
        let text = try String(contentsOf: url, encoding: .utf8)
        if text.hasPrefix("SLOW") {
            while !lock.withLock({ open }) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        switch text {
        case "UNSUPPORTED": throw ExtractionError.unsupported("xlsx")
        case "EMPTY": throw ExtractionError.empty
        case "BROKEN": throw ExtractionError.unreadable("corrupt")
        default: break
        }
        let pages = text.components(separatedBy: "\u{0C}").enumerated().map { ExtractedPage(page: $0.offset + 1, text: $0.element) }
        return DocumentExtraction.Document(kind: .text, pages: pages)
    }
}

@MainActor
final class ProjectIngestorTests: XCTestCase {
    var root: URL!
    var files: URL!
    var registry: ProjectIndexRegistry!
    var queue: GenerationQueue!
    var extractor: FakeExtractor!
    var embedder: FakeEmbedder?
    var busy = false
    var cited: Set<PageRef>? = []
    var persisted: (paused: Set<UUID>, stopped: Set<UUID>) = ([], [])
    let project = UUID()

    override func setUp() async throws {
        root = indexTempDir()
        files = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        registry = ProjectIndexRegistry(directory: { [root] in root!.appendingPathComponent($0.uuidString) }, idleDelay: 0.05)
        queue = GenerationQueue(pollInterval: 0.01)
        extractor = FakeExtractor()
        embedder = FakeEmbedder()
    }

    override func tearDown() async throws {
        registry?.closeAll()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func environment(extract: ((URL) async throws -> DocumentExtraction.Document)? = nil) -> ProjectIngestor.Environment {
        let ex = extractor!
        return ProjectIngestor.Environment(
            registry: registry,
            extract: extract ?? { try await ex.extract($0) },
            embedder: { [weak self] in self?.embedder },
            queue: queue,
            isForegroundBusy: { [weak self] in self?.busy ?? false },
            citedPages: { [weak self] _ in self?.cited },
            pollInterval: 0.01,
            embedRetryDelays: [0.02, 0.02])
    }

    func ingestor(paused: Set<UUID> = [], stopped: Set<UUID> = [],
                  extract: ((URL) async throws -> DocumentExtraction.Document)? = nil) -> ProjectIngestor {
        let i = ProjectIngestor(environment: environment(extract: extract), paused: paused, stopped: stopped)
        i.onPersist = { [weak self] in self?.persisted = ($0, $1) }
        return i
    }

    func file(_ name: String, _ text: String) throws -> URL {
        let url = files.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func corpus(_ n: Int, words: Int = 200) throws -> [URL] {
        var gen = CorpusGenerator(seed: 11)
        return try (0..<n).map { try file("doc\($0).txt", "unique\($0)marker " + gen.text(words: words)) }
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 30, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else { return XCTFail("timed out waiting for: \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func statuses(_ i: ProjectIngestor) -> [DocumentStatus] { (i.documents[project] ?? []).map(\.status) }

    func settle(_ i: ProjectIngestor) async throws {
        try await waitUntil("the ingest goes idle") { i.isIdle }
        await i.maintenanceFinished()
    }

    // MARK: -

    func testFilesBecomeSearchableThenEmbeddedInSlices() async throws {
        let i = ingestor()
        var changes = 0
        i.onChange = { changes += 1 }
        let results = await i.add(try corpus(3, words: 800) + [try file("same.txt", "x"), try file("same2.txt", "x")], to: project)
        XCTAssertEqual(results.prefix(4).map { if case .added = $0 { return true } else { return false } }, [true, true, true, true])
        XCTAssertEqual(results.last, .duplicate(of: 4))
        try await settle(i)
        XCTAssertEqual(statuses(i), [.embedded, .embedded, .embedded, .embedded])
        XCTAssertGreaterThan(embedder!.calls, 4, "documents embedded in several slices")
        XCTAssertEqual(i.progress(for: project), .idle)
        XCTAssertTrue(i.activity.isEmpty)
        XCTAssertGreaterThan(changes, 0)
        let h = try await registry.open(project)
        let hit = try await h.search("unique1marker", queryVector: ToyEmbedder().embed("unique1marker"))
        XCTAssertEqual(hit.hits.first?.doc, 2)
        XCTAssertTrue(hit.usedDense)
        XCTAssertFalse(queue.isBackgroundRunning, "no slice held after the last")
    }

    func testWordsOnlyWithoutEmbedderThenEmbeddedWhenInstalled() async throws {
        embedder = nil
        let i = ingestor()
        _ = await i.add(try corpus(2), to: project)
        try await settle(i)
        XCTAssertEqual(statuses(i), [.searchable, .searchable])
        XCTAssertTrue(i.progress(for: project).wordsOnly)
        XCTAssertEqual(i.displayStatus(i.documents[project]![0], in: project), .readyWordsOnly)
        embedder = FakeEmbedder()
        await i.embedderChanged()
        try await settle(i)
        XCTAssertEqual(statuses(i), [.embedded, .embedded])
        XCTAssertFalse(i.progress(for: project).wordsOnly)
    }

    func testFailuresAndRefusals() async throws {
        let i = ingestor()
        let results = await i.add([try file("a.txt", "UNSUPPORTED"), try file("b.txt", "EMPTY"), try file("c.txt", "BROKEN"),
                                   try file("d.xlsx", "sheet"), try file("e.txt", "fine words here")], to: project)
        XCTAssertEqual(results[3], .notSupported, "refused at add by extension")
        try await settle(i)
        let docs = i.documents[project] ?? []
        XCTAssertEqual(docs.map(\.status), [.unsupported, .empty, .failed, .embedded])
        XCTAssertEqual(docs[2].error, "unreadable: corrupt")
        XCTAssertEqual(i.displayStatus(docs[0], in: project), .notSupported)
    }

    func testPauseHoldsTheProjectAndSurvivesARelaunch() async throws {
        let i = ingestor()
        i.pause(project)
        XCTAssertEqual(persisted.paused, [project])
        _ = await i.add(try corpus(2), to: project)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(statuses(i), [.staged, .staged], "copied, then held")
        XCTAssertEqual(i.progress(for: project).state, .paused)
        XCTAssertEqual(extractor.calls, 0)
        i.shutdown()
        registry.closeAll()

        // Relaunch: the pause comes back with the persisted set.
        let again = ingestor(paused: persisted.paused)
        await again.open(project)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(extractor.calls, 0)
        XCTAssertEqual(again.progress(for: project).state, .paused)
        again.resume(project)
        XCTAssertEqual(persisted.paused, [])
        try await settle(again)
        XCTAssertEqual(statuses(again), [.embedded, .embedded])
    }

    func testPauseTakesEffectBetweenEmbeddingSlices() async throws {
        embedder!.delay = 0.02
        let i = ingestor()
        _ = await i.add(try corpus(1, words: 1500), to: project)
        try await waitUntil("embedding started") { self.embedder!.calls > 0 }
        i.pause(project)
        try await waitUntil("the slice ends") { i.queue.inFlight == nil }
        let calls = embedder!.calls
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(embedder!.calls, calls, "no slice while paused")
        XCTAssertEqual(statuses(i), [.searchable], "searchable by words meanwhile")
        i.resume(project)
        try await settle(i)
        XCTAssertEqual(statuses(i), [.embedded])
    }

    func testStopMarksTheRestNotIndexedAndIndexNowResumes() async throws {
        let i = ingestor()
        let slow = try file("slow.txt", "SLOW then words")
        _ = await i.add([slow] + (try corpus(2)), to: project)
        try await waitUntil("the first file is being read") { self.extractor.calls == 1 }
        await i.stop(project)
        try await settle(i)
        XCTAssertEqual(statuses(i), [.notIndexed, .notIndexed, .notIndexed])
        XCTAssertEqual(persisted.stopped, [project])
        XCTAssertEqual(i.progress(for: project), .idle)
        extractor.release()
        await i.indexNow(project)
        XCTAssertEqual(persisted.stopped, [])
        try await settle(i)
        XCTAssertEqual(statuses(i), [.embedded, .embedded, .embedded])
    }

    func testAStoppedProjectIsNotEmbeddedAtLaunch() async throws {
        embedder = nil
        let i = ingestor()
        _ = await i.add(try corpus(1), to: project)
        try await settle(i)
        await i.stop(project)
        i.shutdown()
        registry.closeAll()
        embedder = FakeEmbedder()
        let again = ingestor(stopped: persisted.stopped)
        await again.open(project)
        try await settle(again)
        XCTAssertEqual(statuses(again), [.searchable])
        XCTAssertEqual(embedder!.calls, 0)
    }

    func testAStopPersistedBeforeItsWriteIsFinishedAtOpen() async throws {
        // A quit after the Stop was saved, before its write: still staged.
        let dir = root.appendingPathComponent(project.uuidString)
        let index = try ProjectIndex(directory: dir)
        for url in try corpus(2) { try index.addCopy(of: url) }
        index.close()
        let i = ingestor(stopped: [project])
        await i.open(project)
        try await settle(i)
        XCTAssertEqual(statuses(i), [.notIndexed, .notIndexed])
        XCTAssertEqual(extractor.calls, 0)
        XCTAssertEqual(i.progress(for: project), .idle)
        await i.indexNow(project)
        try await settle(i)
        XCTAssertEqual(statuses(i), [.embedded, .embedded])
    }

    func testAStopDuringIndexNowWins() async throws {
        // At every point of an Index Now a Stop can come in, nothing is
        // queued or resumed after it.
        for yields in [0, 1, 2, 3, 4, 6, 8, 12, 16, 24] {
            try await tearDown()
            try await setUp()
            embedder = nil
            let i = ingestor()
            _ = await i.add(try corpus(2), to: project)
            try await settle(i)
            _ = await i.add([try file("slow.txt", "SLOW then words")], to: project)
            try await waitUntil("the slow file is being read") { self.extractor.calls == 3 }
            await i.stop(project)
            try await settle(i)
            XCTAssertEqual(statuses(i), [.searchable, .searchable, .notIndexed])
            extractor.release()
            let slow = FakeEmbedder()
            slow.delay = 0.2
            embedder = slow
            let resumed = Task { await i.indexNow(self.project) }
            // Begun (the Stop lifted), then `yields` turns further in.
            while !persisted.stopped.isEmpty { await Task.yield() }
            for _ in 0..<yields { await Task.yield() }
            await i.stop(project)
            await resumed.value
            try await settle(i)
            XCTAssertEqual(persisted.stopped, [project], "after \(yields) yields")
            XCTAssertEqual(statuses(i), [.searchable, .searchable, .notIndexed], "after \(yields) yields")
            XCTAssertEqual(i.progress(for: project), .idle, "after \(yields) yields")
            i.shutdown()
        }
    }

    func testWaitsWhileTheChatModelGenerates() async throws {
        busy = true
        let i = ingestor()
        _ = await i.add(try corpus(1), to: project)
        try await waitUntil("waiting") { i.progress(for: project).state == .waiting }
        XCTAssertEqual(extractor.calls, 0)
        busy = false
        try await settle(i)
        XCTAssertEqual(statuses(i), [.embedded])
    }

    func testAGenerationGetsTheQueueAtTheNextSlice() async throws {
        embedder!.delay = 0.03
        let i = ingestor()
        _ = await i.add(try corpus(1, words: 1200), to: project)
        try await waitUntil("embedding started") { self.embedder!.calls > 0 }
        let ticket = try await queue.acquire()
        let callsAtGrant = embedder!.calls
        XCTAssertEqual(statuses(i), [.searchable], "granted mid-document, at a slice boundary")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(embedder!.calls, callsAtGrant, "no new slice while the generation holds the queue")
        XCTAssertEqual(i.progress(for: project).state, .waiting)
        ticket.release()
        try await settle(i)
        XCTAssertEqual(statuses(i), [.embedded])
    }

    func testRepeatedEmbedderFailuresFallBackToWords() async throws {
        embedder!.failure = EmbedRunner.Failure.fatal("verify_failed")
        let i = ingestor()
        _ = await i.add(try corpus(2), to: project)
        try await settle(i)
        XCTAssertEqual(statuses(i), [.searchable, .searchable])
        XCTAssertNotNil(i.embeddingUnavailable)
        XCTAssertTrue(i.progress(for: project).wordsOnly)
        XCTAssertEqual(embedder!.calls, 3, "the first try and two retries")
        embedder!.failure = nil
        await i.embedderChanged()
        try await settle(i)
        XCTAssertEqual(statuses(i), [.embedded, .embedded])
    }

    func testAnEmbedderRemovedMidDocumentLeavesItSearchable() async throws {
        embedder!.delay = 0.02
        let i = ingestor()
        _ = await i.add(try corpus(1, words: 1500), to: project)
        try await waitUntil("embedding started") { self.embedder?.calls ?? 0 > 0 }
        embedder = nil
        try await settle(i)
        XCTAssertEqual(statuses(i), [.searchable])
        XCTAssertTrue(i.progress(for: project).wordsOnly)
    }

    func testARefusedDocumentIsSkippedNotCountedAgainstTheEmbedder() async throws {
        embedder!.refuse = "poisonword"
        let i = ingestor()
        _ = await i.add([try file("bad.txt", "poisonword and more"), try file("good.txt", "plain good words")], to: project)
        try await settle(i)
        XCTAssertEqual(statuses(i), [.searchable, .embedded], "the refused one stays searchable by words")
        XCTAssertNil(i.embeddingUnavailable)
        XCTAssertEqual(i.progress(for: project), .idle)
    }

    func testARunnerTimeoutIsRetriedNotARefusal() async throws {
        embedder!.timeouts = 1
        let i = ingestor()
        _ = await i.add([try file("a.txt", "plain good words")], to: project)
        try await settle(i)
        XCTAssertEqual(statuses(i), [.embedded], "tried again after the back-off")
        XCTAssertNil(i.embeddingUnavailable)
    }

    func testAFileAddedDuringAStopIsIndexed() async throws {
        for yields in [0, 1, 2, 3, 5, 8, 12] {
            try await tearDown()
            try await setUp()
            let i = ingestor()
            _ = await i.add(try corpus(1), to: project)
            try await settle(i)
            let stopping = Task { await i.stop(self.project) }
            for _ in 0..<yields { await Task.yield() }
            let results = await i.add([try file("new.txt", "fresh words")], to: project)
            await stopping.value
            try await settle(i)
            guard case .added? = results.first else {
                XCTAssertEqual(results, [.failed("indexing was stopped")], "after \(yields) yields")
                continue
            }
            XCTAssertEqual(statuses(i), [.embedded, .embedded], "a file added after the Stop restarts it (\(yields) yields)")
            XCTAssertEqual(persisted.stopped, [], "after \(yields) yields")
            i.shutdown()
        }
    }

    func testAnAddDuringTheRepairOfAStoppedProjectAtOpen() async throws {
        for yields in [0, 1, 2, 3, 5, 8] {
            try await tearDown()
            try await setUp()
            let dir = root.appendingPathComponent(project.uuidString)
            let index = try ProjectIndex(directory: dir)
            for url in try corpus(1) { try index.addCopy(of: url) }
            index.close()
            let i = ingestor(stopped: [project])
            let opening = Task { await i.open(self.project) }
            for _ in 0..<yields { await Task.yield() }
            let results = await i.add([try file("new.txt", "fresh words")], to: project)
            _ = await opening.value
            try await settle(i)
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(statuses(i), [.notIndexed, .embedded], "the old one stays stopped, the new one is indexed (\(yields) yields)")
            i.shutdown()
        }
    }

    func testRemovingADocumentWhileItIsRead() async throws {
        let i = ingestor()
        _ = await i.add([try file("slow.txt", "SLOW words")] + (try corpus(1)), to: project)
        try await waitUntil("reading") { self.extractor.calls == 1 }
        try await i.removeDocument(1, from: project)
        try await settle(i)
        XCTAssertEqual(i.documents[project]?.map(\.doc), [2])
        XCTAssertEqual(statuses(i), [.embedded])
    }

    func testTheEstimateLeavesTheWaitsOut() async throws {
        busy = true
        let i = ingestor()
        _ = await i.add(try corpus(3), to: project)
        try await Task.sleep(nanoseconds: 300_000_000)
        busy = false
        embedder!.delay = 0.05   // the second file's embedding keeps the run open
        try await waitUntil("one finished") {
            let p = i.progress(for: project)
            return p.done >= 1 && p.state != .idle
        }
        let eta = try XCTUnwrap(i.progress(for: project).remainingSeconds)
        XCTAssertLessThan(eta, 0.3, "the 0.3 s waited for the chat isn't work")
        try await settle(i)
    }

    func testAPausedEmbedderIsRetriedNotCountedAsAFailure() async throws {
        embedder!.failure = EmbedRunner.Failure.paused
        let i = ingestor()
        _ = await i.add(try corpus(1), to: project)
        try await waitUntil("several paused attempts") { self.embedder!.calls > 5 }
        XCTAssertNil(i.embeddingUnavailable)
        embedder!.failure = nil
        try await settle(i)
        XCTAssertEqual(statuses(i), [.embedded])
    }

    func testForgetCancelsClosesAndNeverReopens() async throws {
        let i = ingestor()
        _ = await i.add([try file("slow.txt", "SLOW words")] + (try corpus(1)), to: project)
        try await waitUntil("reading") { self.extractor.calls == 1 }
        await i.forget(project)
        XCTAssertFalse(registry.openProjects.contains(project))
        let dir = root.appendingPathComponent(project.uuidString)
        try FileManager.default.removeItem(at: dir)
        extractor.release()
        try await settle(i)
        let late = await i.add(try corpus(1), to: project)
        XCTAssertEqual(late.count, 1)
        if case .failed = late[0] {} else { XCTFail("an add to a deleted project fails") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "the directory isn't recreated")
        XCTAssertNil(i.documents[project])
    }

    func testReconcileAtOpenQueuesWhatWasLeft() async throws {
        // Files added by an earlier run that quit before reading them.
        let dir = root.appendingPathComponent(project.uuidString)
        let index = try ProjectIndex(directory: dir)
        for url in try corpus(2) { try index.addCopy(of: url) }
        index.close()
        let i = ingestor()
        await i.open(project)
        try await settle(i)
        XCTAssertEqual(statuses(i), [.embedded, .embedded])
    }

    func testRemovingADocumentSweepsUncitedTombstones() async throws {
        let i = ingestor()
        _ = await i.add([try file("two.txt", "first page words\u{0C}second page words"), try file("b.txt", "other words")], to: project)
        try await settle(i)
        cited = [PageRef(doc: 1, rev: 1, page: 2)]
        try await i.removeDocument(1, from: project)
        try await settle(i)
        let h = try await registry.open(project)
        let left = try await h.write { try $0.db.rows("SELECT doc, page FROM pages WHERE doc = 1") { [$0.int(0), $0.int(1)] } }
        XCTAssertEqual(left, [[1, 2]], "the cited page kept, the other swept")
        XCTAssertEqual(statuses(i), [.embedded])
    }

    func testNoSweepWhenTheChatsCouldNotAllBeRead() async throws {
        let i = ingestor()
        _ = await i.add([try file("a.txt", "first\u{0C}second"), try file("b.txt", "other")], to: project)
        try await settle(i)
        cited = nil
        try await i.removeDocument(1, from: project)
        try await settle(i)
        let h = try await registry.open(project)
        let left = try await h.write { try $0.db.scalarInt("SELECT count(*) FROM pages WHERE doc = 1") }
        XCTAssertEqual(left, 2)
    }
}

/// The ingest with the real extractor child (`LLMTray --extract`), as in the
/// app: generated text and HTML files reach `searchable`.
@MainActor
final class ProjectIngestExtractorTests: XCTestCase {
    func testTextAndHTMLThroughTheRealExtractor() async throws {
        let beside = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("LLMTray").path
        let binary = ProcessInfo.processInfo.environment["LLMTRAY_BINARY"] ?? beside
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary), "no app binary at \(binary) -- swift build first")
        let root = indexTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectIndexRegistry(directory: { root.appendingPathComponent($0.uuidString) }, idleDelay: 0.05)
        defer { registry.closeAll() }
        let i = ProjectIngestor(environment: ProjectIngestor.Environment(
            registry: registry,
            extract: { try await DocumentExtraction.run(executable: binary, url: $0) },
            embedder: { nil },
            queue: GenerationQueue(pollInterval: 0.01),
            pollInterval: 0.01))
        let text = root.appendingPathComponent("notes.md")
        try "# Поставка\n\nДоговор поставки оборудования zebrafish42 подписан в марте.".write(to: text, atomically: true, encoding: .utf8)
        let html = root.appendingPathComponent("page.html")
        try "<!doctype html><html><head><title>t</title><script>var hidden = 'scriptword';</script></head><body><h1>Release notes</h1><p>The quokka99 build ships on Friday.</p></body></html>"
            .write(to: html, atomically: true, encoding: .utf8)
        let project = UUID()
        let added = await i.add([text, html], to: project)
        XCTAssertEqual(added, [.added(1), .added(2)])
        let deadline = Date().addingTimeInterval(60)
        while !i.isIdle, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        await i.maintenanceFinished()
        XCTAssertEqual(i.documents[project]?.map(\.status), [.searchable, .searchable])
        XCTAssertEqual(i.documents[project]?.map(\.kind), ["text", "html"])
        let h = try await registry.open(project)
        let ru = try await h.search("договора")
        XCTAssertEqual(ru.hits.first?.doc, 1)
        let en = try await h.search("quokka99")
        XCTAssertEqual(en.hits.first?.doc, 2)
        let script = try await h.search("scriptword")
        XCTAssertTrue(script.hits.isEmpty, "script text isn't document text")
    }
}
