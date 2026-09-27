import XCTest
@testable import LLMTrayCore

/// Stands in for the query side of the embed runner: ToyEmbedder's vectors
/// under the test index's set ("toy-hash"), or a failure, or a delay.
final class FakeQueryEmbedder: ProjectQueryEmbedder, @unchecked Sendable {
    var model = "toy-hash"
    var failure: Error?
    var delay: TimeInterval = 0
    /// Waits out `delay` even when cancelled (a runner slow to give up).
    var ignoresCancellation = false
    private(set) var calls = 0

    func embedQuery(_ text: String) async throws -> [Float] {
        calls += 1
        if delay > 0, ignoresCancellation {
            let end = Date().addingTimeInterval(delay)
            while Date() < end { usleep(5_000) }
        } else if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        }
        if let failure { throw failure }
        return ToyEmbedder().embed(text)
    }
}

// MARK: - declaration and arguments (no index)

final class ProjectFilesArgumentTests: XCTestCase {
    func summary(_ documents: Int, searchable: Int) -> ProjectIndexSummary {
        ProjectIndexSummary(documents: documents, searchable: searchable, embedded: 0, pending: documents - searchable, failed: 0)
    }

    func testModeFollowsTheProjectsFiles() {
        let id = UUID()
        XCTAssertEqual(ProjectFilesMode(featureOn: true, project: nil), .none, "no project")
        XCTAssertEqual(ProjectFilesMode(featureOn: true, project: ProjectContext(id: id, name: "p")), .none, "no files")
        let staged = ProjectContext(id: id, name: "p", files: summary(3, searchable: 0))
        XCTAssertEqual(ProjectFilesMode(featureOn: true, project: staged), .listing, "files, none searchable")
        let ready = ProjectContext(id: id, name: "p", files: summary(3, searchable: 1))
        XCTAssertEqual(ProjectFilesMode(featureOn: true, project: ready), .all)
        XCTAssertTrue(ready.hasSearchableFiles)
        XCTAssertEqual(ProjectFilesMode(featureOn: false, project: ready), .none, "the feature off")
    }

    func testDeclarationPerMode() throws {
        XCTAssertNil(ProjectFiles.definition(for: .none))
        func properties(_ mode: ProjectFilesMode) throws -> [String] {
            let function = try XCTUnwrap(ProjectFiles.definition(for: mode)?["function"] as? [String: Any])
            XCTAssertEqual(function["name"] as? String, "project_files")
            let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
            XCTAssertNil(parameters["required"], "every field optional")
            return (try XCTUnwrap(parameters["properties"] as? [String: Any])).keys.sorted()
        }
        XCTAssertEqual(try properties(.listing), [], "listing only: no fields at all")
        XCTAssertEqual(try properties(.all), ["cursor", "doc", "pages", "query"], "top_k is read, never declared")
    }

    func request(_ json: String) -> Result<ProjectFiles.Request, ProjectFiles.ArgumentError>? {
        let parsed = ToolArgumentParser.parse(json, schema: ProjectFiles.schema)
        guard parsed.isValid else { return nil }
        return ProjectFiles.request(parsed.values)
    }

    func testCallsReadWithAliases() {
        XCTAssertEqual(try request(#"{"q":"срок оплаты"}"#)?.get(), .search(query: "срок оплаты", doc: nil, limit: 5))
        XCTAssertEqual(try request(#"{"search":"x","file":2,"k":50}"#)?.get(), .search(query: "x", doc: 2, limit: 10), "capped at 10")
        XCTAssertEqual(try request(#"{"query":"x","top_k":0}"#)?.get(), .search(query: "x", doc: nil, limit: 1))
        XCTAssertEqual(try request(#"{"document":"2","page":"3-5"}"#)?.get(), .read(.init(doc: 2, page: 3, last: 5)))
        XCTAssertEqual(try request(#"{"doc":2,"pages":12}"#)?.get(), .read(.init(doc: 2, page: 12, last: 12)), "a number for the page")
        XCTAssertEqual(try request(#"{"file_id":4}"#)?.get(), .read(.init(doc: 4, page: 1, last: Int.max)), "doc alone: from its start")
        XCTAssertEqual(try request("{}")?.get(), .list(from: 0))
        XCTAssertEqual(try request(#"{"query":"  "}"#)?.get(), .list(from: 0), "an empty query lists")
        XCTAssertEqual(try request(#"{"cursor":"list:40"}"#)?.get(), .list(from: 40))
        XCTAssertEqual(try request(#"{"next":"3:4:120:9"}"#)?.get(), .read(.init(doc: 3, page: 4, offset: 120, last: 9)))
        XCTAssertEqual(try request(#"{"cursor":"3:4:0:9","query":"x"}"#)?.get(), .read(.init(doc: 3, page: 4, last: 9)), "a cursor wins")
    }

    func testPageRanges() {
        XCTAssertEqual(ProjectFiles.pageRange("12"), 12...12)
        XCTAssertEqual(ProjectFiles.pageRange("3-5"), 3...5)
        XCTAssertEqual(ProjectFiles.pageRange("3 – 5"), 3...5)
        XCTAssertEqual(ProjectFiles.pageRange("3..5"), 3...5)
        XCTAssertEqual(ProjectFiles.pageRange("3 to 5"), 3...5)
        XCTAssertEqual(ProjectFiles.pageRange("p. 7"), 7...7)
        XCTAssertEqual(ProjectFiles.pageRange("Pages 2-4"), 2...4)
        XCTAssertEqual(ProjectFiles.pageRange("9-4"), 4...9, "turned round")
        XCTAssertEqual(ProjectFiles.pageRange("5-"), 5...Int.max)
        XCTAssertEqual(ProjectFiles.pageRange("all"), 1...Int.max)
        for bad in ["", "abc", "0", "3,5", "1-2-3", "-4", "x-3"] {
            XCTAssertNil(ProjectFiles.pageRange(bad), bad)
        }
    }

    func testErrorsSayHowToRetry() throws {
        func error(_ json: String) throws -> String {
            guard case .failure(let e) = try XCTUnwrap(request(json)) else { XCTFail("no error for \(json)"); return "" }
            return e.message
        }
        XCTAssertEqual(try error(#"{"pages":"3-5"}"#),
                       #"project_files: "pages" needs "doc", the file's id (call with no arguments to list them). "#
                       + #"Retry: project_files({"doc":<integer>,"pages":"3-5"})"#)
        XCTAssertTrue(try error(#"{"doc":2,"pages":"3,5"}"#).hasSuffix(#"Retry: project_files({"doc":2,"pages":"3-5"})"#))
        XCTAssertTrue(try error(#"{"cursor":"page two"}"#).contains(#""cursor" must be one a result gave"#))
        XCTAssertTrue(try error(#"{"doc":0}"#).contains("a file's id from the list"))
        // A name for the id: the schema's own error, with a retry.
        let parsed = ToolArgumentParser.parse(#"{"doc":"contract.pdf","pages":"2"}"#, schema: ProjectFiles.schema)
        XCTAssertEqual(parsed.errorMessage(tool: ProjectFiles.schema),
                       #"project_files: "doc" must be an integer, not "contract.pdf". Retry: project_files({"doc":<integer>,"pages":"2"})"#)
    }

    func testCursorText() {
        let c = ProjectFiles.ReadCursor(doc: 3, page: 12, offset: 450, last: 20)
        XCTAssertEqual(c.text, "3:12:450:20")
        XCTAssertEqual(ProjectFiles.ReadCursor(c.text), c)
        let withRev = ProjectFiles.ReadCursor(doc: 3, rev: 2, page: 12, offset: 450, last: 20)
        XCTAssertEqual(withRev.text, "3:2:12:450:20")
        XCTAssertEqual(ProjectFiles.ReadCursor(withRev.text), withRev)
        for bad in ["3:12:450", "0:1:0:1", "3:5:0:4", "3:1:-1:2", "a:b:c:d", "3:0:1:0:2", "3:1:2:3:4:5"] {
            XCTAssertNil(ProjectFiles.ReadCursor(bad), bad)
        }
    }

    /// The trust barrier sees project_files as a project tool whatever it's
    /// asked (the listing included): a batch holding one has its network and
    /// generator calls refused before any of them runs.
    func testTrustBarrierInABatch() {
        let batch: [(id: String, kind: ToolTrust.Kind)] = [
            ("1", ProjectFiles.trustKind), ("2", .guarded), ("3", .ordinary), ("4", .guarded),
        ]
        XCTAssertEqual(ToolTrust.refusedUpFront(batch, projectTextThisTurn: false), ["2", "4"])
        XCTAssertEqual(ToolTrust.refusedUpFront([("2", .guarded)], projectTextThisTurn: true), ["2"], "and for the rest of the turn")
    }

    func testChatOwnership() {
        var library = ChatLibrary()
        let chat = UUID()
        let a = library.addProject(named: "a"), b = library.addProject(named: "b")
        library.move(chat, to: a.id)
        XCTAssertTrue(library.chat(chat, isIn: a.id))
        library.move(chat, to: b.id)
        XCTAssertFalse(library.chat(chat, isIn: a.id), "moved")
        XCTAssertTrue(library.chat(chat, isIn: b.id))
        library.deleteProject(b.id)
        XCTAssertFalse(library.chat(chat, isIn: b.id), "deleted")
    }
}

// MARK: - against a real index

@MainActor
final class ProjectFilesServiceTests: XCTestCase {
    var root: URL!
    var registry: ProjectIndexRegistry!
    var embedder: FakeQueryEmbedder?
    var wordsOnlyReason: String?
    let project = UUID()
    var owned = true

    override func setUp() async throws {
        root = indexTempDir()
        registry = ProjectIndexRegistry(directory: { [root] in root!.appendingPathComponent($0.uuidString) }, idleDelay: 0.05)
        embedder = FakeQueryEmbedder()
        wordsOnlyReason = nil
        owned = true
    }

    override func tearDown() async throws {
        registry?.closeAll()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func service(timeout: TimeInterval = 5) -> ProjectFilesService {
        ProjectFilesService(environment: .init(registry: registry, queryEmbedder: { [weak self] in self?.embedder },
                                               wordsOnlyReason: { [weak self] in self?.wordsOnlyReason }, embedTimeout: timeout))
    }

    @discardableResult
    func add(_ text: String, name: String, embed: Bool = true) async throws -> Int64 {
        let h = try await registry.open(project)
        return try await h.write { try $0.addText(text, name: name, embed: embed) }
    }

    func run(_ request: ProjectFiles.Request, budget: Int = 16_000, fileText: Bool = true,
             service s: ProjectFilesService? = nil) async -> ProjectFilesAnswer {
        await (s ?? service()).run(request, project: project, byteBudget: budget, fileTextAllowed: fileText,
                                   stillOwned: { self.owned })
    }

    func output(_ answer: ProjectFilesAnswer, file: StaticString = #filePath, line: UInt = #line) -> ProjectToolOutput {
        guard case .output(let o) = answer else {
            XCTFail("not file text: \(answer)", file: file, line: line)
            return ProjectToolOutput(project: project)
        }
        return o
    }

    /// Three documents; the contract's page 2 is about the payment deadline.
    func addCorpus() async throws -> (contract: Int64, memo: Int64, notes: Int64) {
        let contract = try await add("""
            Supply contract between the parties. The supplier delivers the goods in the agreed quality.\u{0C}\
            Payment deadline: the buyer pays the invoice within ten banking days of delivery.\u{0C}\
            Termination: either party may end the contract with thirty days written notice.
            """, name: "contract.txt")
        let memo = try await add("Memo about the office move. The server room moves to the second floor in March.", name: "memo.txt")
        let notes = try await add("Meeting notes: the team discussed the invoice template and the new logo.", name: "notes.txt")
        return (contract, memo, notes)
    }

    // MARK: search

    /// End to end: the answer's [doc:page] marker becomes the right citation.
    func testSearchAnswersWithTheRightPage() async throws {
        let docs = try await addCorpus()
        let answer = await run(.search(query: "when must the invoice be paid, payment deadline", doc: nil, limit: 5))
        let o = output(answer)
        let top = try XCTUnwrap(o.hits.first)
        XCTAssertEqual(top.doc, Int(docs.contract))
        XCTAssertEqual(top.page, 2)
        XCTAssertEqual(top.name, "contract.txt")
        XCTAssertEqual(top.rev, 1)
        XCTAssertNotNil(top.chunk)
        XCTAssertTrue(top.text.contains("ten banking days"), "verbatim page text")
        XCTAssertEqual(embedder?.calls, 1, "the query was embedded")
        XCTAssertFalse(o.preamble.contains("words only"), o.preamble)

        // Through the chat's fitting and the answer's markers.
        let fitted = o.rendered(byteBudget: 16_000)
        XCTAssertTrue(fitted.text.contains("[\(docs.contract):2] contract.txt"))
        let returned = fitted.returned.map { Citation(project: project, doc: $0.doc, rev: $0.rev, page: $0.page, chunk: $0.chunk, name: $0.name) }
        let cited = CitationMarkers.resolve("The buyer pays within ten banking days [\(docs.contract):2]; see also [9:9].", returned: returned)
        XCTAssertEqual(cited.map(\.doc), [Int(docs.contract)], "an unmatched marker stays text")
        XCTAssertEqual(cited.first?.page, 2)
        XCTAssertEqual(cited.first?.name, "contract.txt")
        XCTAssertEqual(cited.first?.project, project)
    }

    func testAtMostTwoHitsPerFileUnlessNarrowed() async throws {
        let pages = (1...8).map { "Invoice number \($0) for the delivery of goods, invoice total and invoice date." }
        let big = try await add(pages.joined(separator: "\u{0C}"), name: "invoices.txt")
        let other = try await add("One more invoice, from another supplier.", name: "other.txt")
        let o = output(await run(.search(query: "invoice", doc: nil, limit: 5)))
        XCTAssertEqual(o.hits.filter { $0.doc == Int(big) }.count, 2, "a question across files isn't answered from one")
        XCTAssertTrue(o.hits.contains { $0.doc == Int(other) })
        let narrowed = output(await run(.search(query: "invoice", doc: big, limit: 5)))
        XCTAssertEqual(narrowed.hits.count, 5)
        XCTAssertTrue(narrowed.hits.allSatisfy { $0.doc == Int(big) })
    }

    func testWordsOnlyIsSaid() async throws {
        _ = try await addCorpus()
        // Not installed.
        embedder = nil
        var o = output(await run(.search(query: "payment deadline", doc: nil, limit: 5)))
        XCTAssertTrue(o.preamble.contains("Searched by words only (the meaning-search model isn't installed)"), o.preamble)
        XCTAssertFalse(o.hits.isEmpty, "found by words")
        // Paused: a generation holds the GPU.
        let paused = FakeQueryEmbedder()
        paused.failure = EmbedRunner.Failure.paused
        embedder = paused
        o = output(await run(.search(query: "payment deadline", doc: nil, limit: 5)))
        XCTAssertTrue(o.preamble.contains("an image or music generation is using the GPU"), o.preamble)
        XCTAssertEqual(o.hits.first?.page, 2)
        // Too slow.
        let slow = FakeQueryEmbedder()
        slow.delay = 2
        embedder = slow
        o = output(await run(.search(query: "payment deadline", doc: nil, limit: 5), service: service(timeout: 0.05)))
        XCTAssertTrue(o.preamble.contains("didn't answer in time"), o.preamble)
        // The runner's own timeout, or killed as unresponsive: too slow too.
        for failure in [EmbedRunner.Failure.runner(code: "timeout", message: "10 s"), .unresponsive] {
            let timedOut = FakeQueryEmbedder()
            timedOut.failure = failure
            embedder = timedOut
            o = output(await run(.search(query: "payment deadline", doc: nil, limit: 5)))
            XCTAssertTrue(o.preamble.contains("didn't answer in time"), o.preamble)
        }
        // Another failure: its description, readable.
        let died = FakeQueryEmbedder()
        died.failure = EmbedRunner.Failure.died("exit 9")
        embedder = died
        o = output(await run(.search(query: "payment deadline", doc: nil, limit: 5)))
        XCTAssertTrue(o.preamble.contains("meaning search is unavailable: the embedder stopped: exit 9"), o.preamble)
        // Off for this session.
        embedder = FakeQueryEmbedder()
        wordsOnlyReason = "the embedder kept failing"
        o = output(await run(.search(query: "payment deadline", doc: nil, limit: 5)))
        XCTAssertTrue(o.preamble.contains("the embedder kept failing"), o.preamble)
        XCTAssertEqual(embedder?.calls, 0)
        // Another model's vectors: nothing to score with this query.
        wordsOnlyReason = nil
        embedder?.model = "other-model@1"
        o = output(await run(.search(query: "payment deadline", doc: nil, limit: 5)))
        XCTAssertTrue(o.preamble.contains("re-indexed for another meaning-search model"), o.preamble)
    }

    func testAnotherModelsVectorsDontStartTheEmbedder() async throws {
        _ = try await addCorpus()
        let other = FakeQueryEmbedder()
        other.model = "other-model@1"
        other.delay = 2
        embedder = other
        let started = Date()
        let o = output(await run(.search(query: "payment deadline", doc: nil, limit: 5), service: service(timeout: 5)))
        XCTAssertTrue(o.preamble.contains("re-indexed for another meaning-search model"), o.preamble)
        XCTAssertEqual(other.calls, 0, "no query embedding for vectors it can't score")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(o.hits.first?.page, 2, "found by words")
    }

    func testNothingEmbeddedDoesntStartTheEmbedder() async throws {
        try await add("Payment within ten days.", name: "a.txt", embed: false)
        let o = output(await run(.search(query: "payment", doc: nil, limit: 5)))
        XCTAssertTrue(o.preamble.contains("no file is indexed for meaning yet"), o.preamble)
        XCTAssertEqual(embedder?.calls, 0)
        XCTAssertEqual(o.hits.count, 1)
    }

    func testPartlyEmbeddedStillIndexingAndFailedAreNoted() async throws {
        _ = try await addCorpus()
        try await add("Payment terms of the old contract.", name: "old.txt", embed: false)
        let h = try await registry.open(project)
        let src = root.appendingPathComponent("waiting.txt")
        try "waiting".write(to: src, atomically: true, encoding: .utf8)
        let staged = try await h.write { try $0.addCopy(of: src, name: "waiting.txt") }
        try "broken".write(to: src, atomically: true, encoding: .utf8)
        let broken = try await h.write { idx -> Int64 in
            let d = try idx.addCopy(of: src, name: "broken.pdf")
            try idx.failExtraction(try idx.beginExtraction(doc: d), error: "damaged")
            return d
        }
        let o = output(await run(.search(query: "payment", doc: nil, limit: 5)))
        XCTAssertTrue(o.preamble.contains("Searched by words only in 4. old.txt (not yet indexed for meaning)"), o.preamble)
        XCTAssertTrue(o.preamble.contains("Still being indexed, not searched: \(staged). waiting.txt"), o.preamble)
        XCTAssertTrue(o.preamble.contains("Couldn't be read, not searched: \(broken). broken.pdf"), o.preamble)
        // Narrowed to a file that isn't ready: its status, no search.
        guard case .text(let text) = await run(.search(query: "x", doc: staged, limit: 5)) else { return XCTFail() }
        XCTAssertEqual(text, "File \(staged) (waiting.txt) is waiting to be indexed: it can't be searched yet.")
        guard case .text(let missing) = await run(.search(query: "x", doc: 99, limit: 5)) else { return XCTFail() }
        XCTAssertTrue(missing.hasPrefix("project_files: no file 99 in this project"), missing)
    }

    func testSearchResultFitsTheBudget() async throws {
        let long = (1...30).map { "Clause \($0): the payment is due within \($0) days of the invoice date, " + String(repeating: "terms ", count: 60) }
        try await add(long.joined(separator: "\u{0C}"), name: "long.txt")
        try await add(long.joined(separator: "\u{0C}") + " (copy)", name: "long2.txt")
        let o = output(await run(.search(query: "payment invoice", doc: nil, limit: 10)))
        let budget = 1200
        let fitted = o.rendered(byteBudget: budget)
        XCTAssertLessThanOrEqual(fitted.text.utf8.count, budget)
        XCTAssertLessThan(fitted.returned.count, o.hits.count, "the rest didn't fit")
    }

    // MARK: read

    func testReadIsVerbatimAndTheCursorContinuesExactly() async throws {
        let pages = (1...4).map { p in (1...40).map { "Page \(p) sentence \($0) says ёжик and 😀 things." }.joined(separator: " ") }
        let doc = try await add(pages.joined(separator: "\u{0C}"), name: "book.txt")
        // Everything fits: each page whole, nothing to continue.
        let all = output(await run(.read(.init(doc: doc, page: 1, last: .max)), budget: 100_000))
        XCTAssertEqual(all.hits.map(\.text), pages)
        XCTAssertEqual(all.hits.map(\.page), [1, 2, 3, 4])
        XCTAssertEqual(all.epilogue, "")

        // A small budget: cut pieces, a cursor each time, and together
        // exactly the pages -- nothing skipped, nothing twice.
        let budget = 1500
        var read: [Int: String] = [:]
        var request = ProjectFiles.Request.read(.init(doc: doc, page: 1, last: 4))
        var calls = 0
        while calls < 100 {
            calls += 1
            let o = output(await run(request, budget: budget + ProjectFilesService.slackBytes))
            XCTAssertTrue(o.fitsWhole(byteBudget: budget), "never cut by the chat's fitting")
            XCTAssertFalse(o.rendered(byteBudget: budget).text.contains(ProjectToolOutput.cutMarker))
            XCTAssertFalse(o.hits.isEmpty)
            for h in o.hits { read[h.page, default: ""] += h.text }
            guard let range = o.epilogue.range(of: #"(?<="cursor":")[^"]+"#, options: .regularExpression) else { break }
            let cursor = try XCTUnwrap(ProjectFiles.ReadCursor(String(o.epilogue[range])))
            request = .read(cursor)
        }
        XCTAssertGreaterThan(calls, 4, "the budget did cut")
        XCTAssertEqual((1...4).map { read[$0] }, pages)
    }

    /// The same page read again in the turn under another budget: another
    /// range, another id -- never taken for the piece shown earlier.
    func testRereadUnderAnotherBudgetIsNotShownEarlier() async throws {
        let text = (1...200).map { "word\($0)" }.joined(separator: " ")
        let doc = try await add(text, name: "one.txt")
        let small = output(await run(.read(.init(doc: doc, page: 1, last: 1)), budget: 900))
        let large = output(await run(.read(.init(doc: doc, page: 1, last: 1)), budget: 4000))
        XCTAssertLessThan(small.hits[0].text.count, large.hits[0].text.count)
        XCTAssertNotEqual(small.hits[0].id, large.hits[0].id)
        let sent = small.rendered(byteBudget: 900).whole
        XCTAssertFalse(large.rendered(byteBudget: 4000, alreadySent: sent).text.contains("shown earlier"))
        XCTAssertEqual(large.hits[0].text, text, "the whole page this time")
    }

    /// A cursor of a revision the file no longer has: read again, not
    /// continued at an offset into other text.
    func testCursorOfAnOlderRevision() async throws {
        let doc = try await add((1...300).map { "old\($0)" }.joined(separator: " ") + "\u{0C}second page", name: "f.txt")
        let first = output(await run(.read(.init(doc: doc, page: 1, last: 2)), budget: 900))
        let range = try XCTUnwrap(first.epilogue.range(of: #"(?<="cursor":")[^"]+"#, options: .regularExpression))
        let cursor = try XCTUnwrap(ProjectFiles.ReadCursor(String(first.epilogue[range])))
        XCTAssertEqual(cursor.rev, 1)
        let h = try await registry.open(project)
        try await h.write { idx in
            let job = try idx.beginReindex(doc: doc)
            try idx.commitExtraction(job, pages: ProjectIndex.pages("new text\u{0C}new second"), kind: "text")
        }
        // Read again from that page of the new revision, in the same call.
        let changed = output(await run(.read(cursor)))
        XCTAssertTrue(changed.preamble.hasPrefix("File \(doc) (f.txt) has changed since that read (indexed again): "
                                                 + "page 1 is read again from its start"), changed.preamble)
        XCTAssertEqual(changed.hits.map(\.text), ["new text", "new second"])
        XCTAssertEqual(changed.hits.map(\.rev), [2, 2])
    }

    func testReadRangeAndErrors() async throws {
        let doc = try await add("one\u{0C}two\u{0C}three", name: "three.txt")
        let o = output(await run(.read(.init(doc: doc, page: 2, last: 9))))
        XCTAssertEqual(o.hits.map(\.text), ["two", "three"])
        XCTAssertEqual(o.preamble, "three.txt has 3 page(s).")
        XCTAssertEqual(o.hits.first?.id, "r\(doc).1.2.0-3", "the range it holds")
        guard case .text(let past) = await run(.read(.init(doc: doc, page: 7, last: 7))) else { return XCTFail() }
        XCTAssertEqual(past, "File \(doc) (three.txt) has 3 page(s); page 7 isn't one of them.")
    }

    func testALongNameStillLeavesRoomForTheTextAndEveryCursorMovesOn() async throws {
        let name = String(repeating: "n", count: 190) + ".txt"
        let text = (1...200).map { "word\($0)" }.joined(separator: " ")
        let doc = try await add(text, name: name)
        let budget = ProjectTextBudget.bytes(forTokens: ProjectTextBudget.minimumTokens)
        var request = ProjectFiles.Request.read(.init(doc: doc, page: 1, last: 1))
        var read = ""
        var cursors: [String] = []
        for _ in 0..<60 {
            let o = output(await run(request, budget: budget))
            let hit = try XCTUnwrap(o.hits.first, "text every time: \(o.preamble)")
            XCTAssertEqual(hit.name, name, "the citation keeps the whole name")
            XCTAssertTrue(o.rendered(byteBudget: budget).text.contains(String(repeating: "n", count: 40) + "…"))
            read += hit.text
            guard let range = o.epilogue.range(of: #"(?<="cursor":")[^"]+"#, options: .regularExpression) else { break }
            let next = String(o.epilogue[range])
            XCTAssertFalse(cursors.contains(next), "a cursor that doesn't move on")
            cursors.append(next)
            request = .read(try XCTUnwrap(ProjectFiles.ReadCursor(next)))
        }
        XCTAssertEqual(read, text, "the whole page, once")
    }

    func testTheTimeoutDoesntWaitForTheEmbedderToGiveUp() async throws {
        _ = try await addCorpus()
        let stubborn = FakeQueryEmbedder()
        stubborn.delay = 1.5
        stubborn.ignoresCancellation = true
        embedder = stubborn
        let started = Date()
        let o = output(await run(.search(query: "payment deadline", doc: nil, limit: 5), service: service(timeout: 0.05)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertTrue(o.preamble.contains("didn't answer in time"), o.preamble)
        XCTAssertEqual(o.hits.first?.page, 2)
    }

    // MARK: listing

    func testListingAndItsCursor() async throws {
        let docs = try await addCorpus()
        let o = output(await run(.list(from: 0)))
        XCTAssertTrue(o.preamble.contains("3 file(s) in this project"), o.preamble)
        XCTAssertTrue(o.preamble.contains("\(docs.contract). contract.txt -- 3 pages -- ready"), o.preamble)
        XCTAssertTrue(o.preamble.contains("\(docs.memo). memo.txt -- 1 page -- ready"), o.preamble)
        XCTAssertTrue(o.preamble.contains(#"Search: project_files({"query":"...""#))
        XCTAssertTrue(o.hits.isEmpty)

        for i in 0..<20 { try await add("File \(i) text", name: "file-with-a-longish-name-\(i).txt", embed: false) }
        var seen: [String] = []
        var request = ProjectFiles.Request.list(from: 0)
        for _ in 0..<30 {
            let page = output(await run(request, budget: 700))
            XCTAssertTrue(page.fitsWhole(byteBudget: 700 - ProjectFilesService.slackBytes))
            seen += page.preamble.split(separator: "\n").map(String.init).filter { $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }
            guard let range = page.epilogue.range(of: #"(?<="cursor":"list:)\d+"#, options: .regularExpression) else { break }
            request = .list(from: Int(page.epilogue[range])!)
        }
        XCTAssertEqual(seen.count, 23, "every file once")
        XCTAssertEqual(Set(seen).count, 23)
    }

    func testNoRoomForAnyLineGivesNoCursor() async throws {
        for i in 0..<3 { try await add("File \(i) text", name: "f\(i).txt", embed: false) }
        let o = output(await run(.list(from: 0), budget: 250))
        XCTAssertTrue(o.preamble.contains("no room to list them"), o.preamble)
        XCTAssertEqual(o.epilogue, "", "no cursor past a file that wasn't shown")
    }

    func testAFileLineLongerThanTheRoomStillListsTheRest() async throws {
        // A name as long as the listing's room (a file's display name isn't
        // bounded by the file system's).
        let long = String(repeating: "a-very-long-file-name-", count: 40) + ".txt"
        let h = try await registry.open(project)
        let src = root.appendingPathComponent("s.txt")
        try "x".write(to: src, atomically: true, encoding: .utf8)
        let first = try await h.write { try $0.addCopy(of: src, name: long) }
        for i in 0..<3 { try await add("File \(i) text", name: "f\(i).txt", embed: false) }
        let budget = 700
        var seen: [String] = []
        var request = ProjectFiles.Request.list(from: 0)
        for _ in 0..<10 {
            let page = output(await run(request, budget: budget))
            XCTAssertTrue(page.fitsWhole(byteBudget: budget - ProjectFilesService.slackBytes), page.preamble)
            XCTAssertFalse(page.preamble.contains("no room"), page.preamble)
            seen += page.preamble.split(separator: "\n").map(String.init).filter { $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }
            guard let range = page.epilogue.range(of: #"(?<="cursor":"list:)\d+"#, options: .regularExpression) else { break }
            request = .list(from: Int(page.epilogue[range])!)
        }
        XCTAssertEqual(seen.count, 4, "every file, the long one cut: \(seen)")
        XCTAssertTrue(seen[0].hasPrefix("\(first). a-very-long-file-name-"), seen[0])
        XCTAssertTrue(seen[0].contains("… -- ? pages -- waiting to be indexed"), seen[0])
    }

    func testNothingSearchableYetAnswersWithTheListing() async throws {
        let h = try await registry.open(project)
        let src = root.appendingPathComponent("s.txt")
        try "x".write(to: src, atomically: true, encoding: .utf8)
        _ = try await h.write { try $0.addCopy(of: src, name: "s.txt") }
        let o = output(await run(.search(query: "x", doc: nil, limit: 5)))
        XCTAssertTrue(o.preamble.hasPrefix("No file can be searched or read yet"), o.preamble)
        XCTAssertTrue(o.preamble.contains("1. s.txt -- ? pages -- waiting to be indexed"), o.preamble)
        XCTAssertFalse(o.preamble.contains("Search:"), "no hint to search")
    }

    // MARK: the room, ownership, the project

    func testNoRoomRefusesSearchAndRead() async throws {
        _ = try await addCorpus()
        let search = await run(.search(query: "payment", doc: nil, limit: 5), fileText: false)
        XCTAssertEqual(search, .refused(ProjectTextBudget.noRoomText))
        let read = await run(.read(.init(doc: 1, page: 1, last: 1)), fileText: false)
        XCTAssertEqual(read, .refused(ProjectTextBudget.noRoomText))
        let list = await run(.list(from: 0), fileText: false)
        XCTAssertTrue(output(list).preamble.contains("contract.txt"))
    }

    func testChatMovedMidTurnIsRefused() async throws {
        _ = try await addCorpus()
        owned = false
        let search = await run(.search(query: "payment", doc: nil, limit: 5))
        XCTAssertEqual(search, .refused(ProjectFiles.notInProjectText))
        let list = await run(.list(from: 0))
        XCTAssertEqual(list, .refused(ProjectFiles.notInProjectText), "the listing too")

        // Moved while it searched: checked again before any text goes out.
        var checks = 0
        let answer = await service().run(.search(query: "payment", doc: nil, limit: 5), project: project, byteBudget: 16_000,
                                         stillOwned: { checks += 1; return checks == 1 })
        XCTAssertEqual(answer, .refused(ProjectFiles.notInProjectText))
        XCTAssertEqual(checks, 2)
    }

    func testDeletedProjectIsRefused() async throws {
        _ = try await addCorpus()
        registry.retire(project)
        let list = await run(.list(from: 0))
        XCTAssertEqual(list, .refused(ProjectFiles.projectGoneText))
    }

    // MARK: citations

    func testCitationTarget() async throws {
        let doc = try await add("one\u{0C}two", name: "a.txt")
        let dir = root.appendingPathComponent(project.uuidString)
        let cite = Citation(project: project, doc: Int(doc), rev: 1, page: 2, name: "a.txt")
        guard case .file(let url, let page, let changed) = CitationTarget.resolve(cite, projectDirectory: dir) else { return XCTFail() }
        XCTAssertEqual(url.lastPathComponent, "\(doc).txt")
        XCTAssertEqual(page, 2)
        XCTAssertFalse(changed)
        var older = cite
        older.rev = 0
        guard case .file(_, _, true) = CitationTarget.resolve(older, projectDirectory: dir) else { return XCTFail("a changed revision") }
        var gone = cite
        gone.doc = 42
        XCTAssertEqual(CitationTarget.resolve(gone, projectDirectory: dir), .gone)
        XCTAssertEqual(CitationTarget.resolve(cite, projectDirectory: root.appendingPathComponent("nowhere")), .gone)
        let h = try await registry.open(project)
        try await h.write { try $0.remove(doc: doc) }
        XCTAssertEqual(CitationTarget.resolve(cite, projectDirectory: dir), .gone, "removed")
    }
}
