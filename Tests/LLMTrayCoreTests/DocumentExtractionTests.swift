import XCTest
@testable import LLMTrayCore

/// The parent's reading of a run, from lines and an end made up here.
final class DocumentExtractionTests: XCTestCase {
    private func exit(status: Int32? = 0, signal: Int32? = nil, limit: ProcessRunner.SupervisedLimit? = nil) -> ProcessRunner.SupervisedExit {
        ProcessRunner.SupervisedExit(status: status, signal: signal, limit: limit, peakFootprint: 0, jetsamApplied: false,
                                     stdoutBytes: 0, stderrTail: "", wallTime: 0)
    }

    private func page(_ n: Int, _ text: String, junk: Double? = nil) -> String {
        ExtractorMessage.page(ExtractedPage(page: n, text: text, junk: junk)).line
    }

    private func summary(_ kind: DocumentKind, _ pages: Int, _ failure: ExtractionError? = nil) -> String {
        ExtractorMessage.summary(ExtractionSummary(kind: kind, pages: pages, milliseconds: 1, failure: failure)).line
    }

    private func run(_ lines: [String], caps: ExtractionCaps = ExtractionCaps(),
                     exit end: ProcessRunner.SupervisedExit? = nil) -> Result<DocumentExtraction.Document, ExtractionError> {
        let c = DocumentExtraction.Collector(caps: caps)
        var stopped = false
        for line in lines where !stopped { stopped = !c.consume(line) }
        let e = end ?? (stopped ? exit(status: nil, signal: SIGKILL, limit: .stoppedByCaller) : exit())
        return Result { try c.finish(e) }.mapError { $0 as! ExtractionError }
    }

    func testCompleteDocument() throws {
        let doc = try run([page(1, "one"), page(2, "two"), summary(.pdf, 2)]).get()
        XCTAssertEqual(doc.kind, .pdf)
        XCTAssertEqual(doc.pages.map(\.text), ["one", "two"])
    }

    func testTheChildsFailureIsTheDocuments() {
        XCTAssertEqual(run([summary(.docx, 0, .tooLarge(.zipRatio))]), .failure(.tooLarge(.zipRatio)))
        // Pages written before a failure don't make it a partial success.
        XCTAssertEqual(run([page(1, "a"), summary(.text, 1, .tooLarge(.text))]), .failure(.tooLarge(.text)))
    }

    func testLimitsMapToFailures() {
        XCTAssertEqual(run([page(1, "a")], exit: exit(status: nil, signal: SIGKILL, limit: .timeout)), .failure(.timeout))
        XCTAssertEqual(run([], exit: exit(status: nil, signal: SIGXCPU, limit: .cpu)), .failure(.timeout))
        XCTAssertEqual(run([], exit: exit(status: nil, signal: SIGKILL, limit: .memory)), .failure(.memory))
        XCTAssertEqual(run([], exit: exit(status: nil, signal: SIGKILL, limit: .stdout)), .failure(.tooLarge(.output)))
    }

    func testParentSideCaps() {
        var caps = ExtractionCaps()
        caps.maxPages = 2
        XCTAssertEqual(run([page(1, "a"), page(2, "b"), page(3, "c"), summary(.pdf, 3)], caps: caps), .failure(.tooLarge(.pages)))
        caps = ExtractionCaps()
        caps.maxTextBytes = 5
        XCTAssertEqual(run([page(1, "abc"), page(2, "def"), summary(.pdf, 2)], caps: caps), .failure(.tooLarge(.text)))
    }

    func testBrokenProtocolIsACrash() {
        guard case .failure(.crashed) = run(["garbage"]) else { return XCTFail() }
        guard case .failure(.crashed) = run([page(2, "skipped one")]) else { return XCTFail() }
        guard case .failure(.crashed) = run([page(1, "a"), summary(.pdf, 2)]) else { return XCTFail("pages missing") }
        guard case .failure(.crashed) = run([summary(.pdf, 0), page(1, "late")]) else { return XCTFail() }
        guard case .failure(.crashed) = run([page(1, "a")]) else { return XCTFail("no summary") }
        XCTAssertEqual(run([page(1, "a"), summary(.pdf, 1)], exit: exit(status: nil, signal: SIGSEGV)), .failure(.crashed("signal 11")))
        XCTAssertEqual(run([page(1, "a"), summary(.pdf, 1)], exit: exit(status: 1)), .failure(.crashed("exit 1")))
    }

    func testEmptyJunkAndUnsupported() {
        XCTAssertEqual(run([page(1, "  \n"), summary(.text, 1)]), .failure(.empty))
        XCTAssertEqual(run([summary(.text, 0)]), .failure(.empty))
        XCTAssertEqual(run([page(1, "Íàñòîÿùèé", junk: 0.9), page(2, ""), summary(.pdf, 2)]), .failure(.junk))
        // One good page is enough; the junk one stays flagged.
        let doc = try? run([page(1, "Íàñòîÿùèé", junk: 0.9), page(2, "fine", junk: 0), summary(.pdf, 2)]).get()
        XCTAssertEqual(doc?.pages.map(\.isJunk), [true, false])
        XCTAssertEqual(run([summary(.pptx, 0)]), .failure(.unsupported("pptx")))
    }
}
