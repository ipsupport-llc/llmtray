import XCTest
@testable import LLMTrayCore

final class ProjectToolResultsTests: XCTestCase {
    let project = UUID()

    func hit(_ id: String, doc: Int = 1, page: Int = 1, text: String) -> ProjectHit {
        ProjectHit(id: id, doc: doc, rev: 1, page: page, chunk: nil, name: "contract.pdf", heading: nil, text: text)
    }

    func testRenderedWholeWhenItFits() {
        let output = ProjectToolOutput(project: project, preamble: "1 file still indexing.",
                                       hits: [hit("c1", page: 2, text: "Оплата в течение 10 дней."), hit("c2", doc: 2, page: 5, text: "Penalty 0.1%.")],
                                       epilogue: "cursor: abc")
        let r = output.rendered(byteBudget: 10_000)
        XCTAssertTrue(r.text.hasPrefix(ProjectToolOutput.framing))
        XCTAssertTrue(r.text.contains("1 file still indexing."))
        XCTAssertTrue(r.text.contains("[1:2] contract.pdf\n\"\"\"\nОплата в течение 10 дней.\n\"\"\""))
        XCTAssertTrue(r.text.contains("[2:5] contract.pdf"))
        XCTAssertTrue(r.text.hasSuffix("cursor: abc"))
        XCTAssertFalse(r.text.contains(ProjectToolOutput.cutMarker))
        XCTAssertEqual(r.returned.map(\.id), ["c1", "c2"])
        XCTAssertEqual(r.whole, ["c1", "c2"])
    }

    func testCutWithMarkerWithinBudget() {
        let long = String(repeating: "Договор поставки. ", count: 400)   // ~12 KB
        let output = ProjectToolOutput(project: project, hits: [hit("c1", text: long), hit("c2", text: "second")])
        for budget in [700, 1_500, 4_000] {
            let r = output.rendered(byteBudget: budget)
            XCTAssertLessThanOrEqual(r.text.utf8.count, budget, "\(budget)")
            XCTAssertTrue(r.text.contains(ProjectToolOutput.cutMarker), "\(budget)")
            XCTAssertTrue(r.text.contains("1 more result(s) didn't fit"), "\(budget)")
            XCTAssertEqual(r.returned.map(\.id), ["c1"], "a cut piece was shown: it may be cited")
            XCTAssertTrue(r.whole.isEmpty, "a cut piece may be sent again, whole")
            XCTAssertNotNil(r.text.data(using: .utf8), "cut at a character boundary")
        }
    }

    func testNoPieceWhenTooLittleRoom() {
        let output = ProjectToolOutput(project: project, hits: [hit("c1", text: String(repeating: "x", count: 5_000))])
        let r = output.rendered(byteBudget: ProjectToolOutput.framing.utf8.count + 100)
        XCTAssertTrue(r.returned.isEmpty)
        XCTAssertFalse(r.text.contains("xxx"))
    }

    func testAlreadySentOnlyNamed() {
        let output = ProjectToolOutput(project: project, hits: [hit("c1", page: 3, text: "the same chunk"), hit("c2", text: "new")])
        let r = output.rendered(byteBudget: 10_000, alreadySent: ["c1"])
        XCTAssertFalse(r.text.contains("the same chunk"))
        XCTAssertTrue(r.text.contains("[1:3] contract.pdf: shown earlier in this turn."))
        XCTAssertEqual(r.returned.map(\.id), ["c1", "c2"])
    }

    func testLongPreambleCut() {
        let output = ProjectToolOutput(project: project, preamble: String(repeating: "file.txt ready\n", count: 500))
        let r = output.rendered(byteBudget: 1_000)
        XCTAssertLessThanOrEqual(r.text.utf8.count, 1_000)
        XCTAssertTrue(r.text.contains(ProjectToolOutput.cutMarker))
    }

    func testAllowance() {
        // 32k context, 1k answer, 3.3k margin (10%): half the rest, capped.
        XCTAssertEqual(ProjectTextBudget.allowance(contextTokens: 32_768, requestTokens: 8_000, maxTokens: 1_024), 8_000)
        XCTAssertEqual(ProjectTextBudget.allowance(contextTokens: 32_768, requestTokens: 20_000, maxTokens: 1_024), 4_233)
        XCTAssertNil(ProjectTextBudget.allowance(contextTokens: 32_768, requestTokens: 28_000, maxTokens: 1_024))
        XCTAssertNil(ProjectTextBudget.allowance(contextTokens: 4_096, requestTokens: 5_000, maxTokens: 1_024))
        XCTAssertEqual(ProjectTextBudget.bytes(forTokens: 1_000), 2_000)
    }

    /// A long chat with repeated searches: each result fits its share, a
    /// chunk isn't sent twice, and the room runs out rather than overflows.
    func testRepeatedSearchesInALongChat() {
        let context = 16_384, maxTokens = 1_024
        var estimator = PromptTokenEstimator()
        estimator.calibrate(.init(bytes: 20_000), promptTokens: 5_000)
        var addedBytes = 0
        var sent: Set<String> = []
        var rounds = 0, named = 0
        let chunk = String(repeating: "Покупатель уплачивает неустойку. ", count: 60)   // ~3.6 KB
        while let tokens = ProjectTextBudget.allowance(contextTokens: context,
                                                       requestTokens: estimator.estimate(countedPlus: .init(bytes: addedBytes)) ?? 0,
                                                       maxTokens: maxTokens) {
            rounds += 1
            XCTAssertLessThan(rounds, 20)
            // Overlapping the last search.
            let hits = (0..<5).map { hit("c\(rounds + $0)", page: rounds + $0, text: "c\(rounds + $0): " + chunk) }
            let r = ProjectToolOutput(project: project, hits: hits).rendered(byteBudget: ProjectTextBudget.bytes(forTokens: tokens), alreadySent: sent)
            XCTAssertLessThanOrEqual(r.text.utf8.count, ProjectTextBudget.bytes(forTokens: tokens))
            for repeated in hits where sent.contains(repeated.id) {
                XCTAssertFalse(r.text.contains(repeated.text.prefix(40)), "\(repeated.id) sent again")
            }
            if r.text.contains("shown earlier in this turn") { named += 1 }
            sent.formUnion(r.whole)
            addedBytes += r.text.utf8.count
            let estimate = estimator.estimate(countedPlus: .init(bytes: addedBytes)) ?? 0
            XCTAssertLessThanOrEqual(estimate + maxTokens, context, "never past the context")
        }
        XCTAssertGreaterThan(rounds, 1)
        XCTAssertGreaterThan(named, 0, "a repeated chunk was only named")
    }

    func testCitationMarkers() {
        let text = "По договору [1:2] оплата — 10 дней [1:2]; неустойка [2:5, 1:3]. См. также [ 4 : 7 ] и [x:1], [1], [1:2:3]."
        let markers = CitationMarkers.markers(in: text)
        XCTAssertEqual(markers.map(\.doc), [1, 2, 1, 4])
        XCTAssertEqual(markers.map(\.page), [2, 5, 3, 7])
        XCTAssertTrue(CitationMarkers.markers(in: "[99999999999999999999:1] no digits overflow").isEmpty)
    }

    func testResolveOnlyReturnedPages() {
        let returned = [
            Citation(project: project, doc: 1, rev: 1, page: 2, chunk: 10, name: "a.pdf"),
            Citation(project: project, doc: 2, rev: 3, page: 5, name: "b.docx"),
            Citation(project: project, doc: 1, rev: 2, page: 2, chunk: 11, name: "a.pdf"),
        ]
        let resolved = CitationMarkers.resolve("[1:2] and [9:9] and [2:5] and again [1:2]", returned: returned)
        XCTAssertEqual(resolved.map(\.doc), [1, 2], "[9:9] matches nothing: plain text")
        XCTAssertEqual(resolved.first?.rev, 2, "the later revision")
        XCTAssertTrue(CitationMarkers.resolve("[1:2]", returned: []).isEmpty)
        XCTAssertEqual(CitationMarkers.unique(resolved + resolved).count, 2)
    }

    func testCitationCodable() throws {
        let c = Citation(project: project, doc: 3, rev: 1, page: 12, name: "Отчёт.xlsx")
        let back = try JSONDecoder().decode(Citation.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
        XCTAssertNil(back.chunk)
    }

    // MARK: - the citation scan

    func testCitedPagesReadsTheChatsNotTheLibraryNextToThem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = UUID(), other = UUID()
        // The library file of a normal install, not a chat.
        try #"{"version":1,"projects":[{"id":"\#(project.uuidString)","name":"P"}]}"#
            .write(to: dir.appendingPathComponent("library.json"), atomically: true, encoding: .utf8)
        try "notes".write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let chat = """
        {"id":"\(UUID().uuidString)","title":"t","createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z",
         "messages":[{"role":"user","content":"q"},
                     {"role":"assistant","content":"a","citations":[
                        {"project":"\(project.uuidString)","doc":1,"rev":2,"page":3,"name":"a.pdf"},
                        {"project":"\(other.uuidString)","doc":9,"rev":1,"page":1,"name":"x.pdf"}]}]}
        """
        try chat.write(to: dir.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionCitations.citedPages(inDirectory: dir.path, project: project), [PageRef(doc: 1, rev: 2, page: 3)])
        XCTAssertNil(SessionCitations.sessionID(fileName: "library.json"))

        // A chat that can't be read: no list at all.
        try "{".write(to: dir.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
        XCTAssertNil(SessionCitations.citedPages(inDirectory: dir.path, project: project))
        XCTAssertEqual(SessionCitations.citedPages(inDirectory: dir.path + "-missing", project: project), [])
    }
}
