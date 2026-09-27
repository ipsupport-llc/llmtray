import XCTest
@testable import LLMTrayCore

final class ExtractorMessageTests: XCTestCase {
    func testDecodesTheChildsLines() {
        XCTAssertEqual(ExtractorMessage(line: #"{"page":2,"text":"Привет\n","tier":1,"junk":0.25,"error":null}"#),
                       .page(ExtractedPage(page: 2, text: "Привет\n", tier: 1, junk: 0.25)))
        XCTAssertEqual(ExtractorMessage(line: #"{"page":1,"text":"","tier":1,"error":"page unreadable"}"#),
                       .page(ExtractedPage(page: 1, text: "", error: "page unreadable")))
        XCTAssertEqual(ExtractorMessage(line: #"{"summary":{"kind":"pdf","pages":3,"milliseconds":40}}"#),
                       .summary(ExtractionSummary(kind: .pdf, pages: 3, milliseconds: 40)))
        XCTAssertEqual(ExtractorMessage(line: #"{"summary":{"kind":"docx","pages":0,"milliseconds":2,"failure":{"code":"too-large","detail":"zip-ratio"}}}"#),
                       .summary(ExtractionSummary(kind: .docx, pages: 0, milliseconds: 2, failure: .tooLarge(.zipRatio))))
    }

    func testRejectsOtherLines() {
        for line in ["", "not json", "{}", #"{"page":"1","text":"x","tier":1}"#, #"{"text":"x"}"#,
                     #"{"summary":{"kind":"nope","pages":1,"milliseconds":1}}"#,
                     #"{"summary":{"kind":"pdf","pages":0,"milliseconds":1,"failure":{"code":"bogus"}}}"#,
                     #"{"summary":{"kind":"pdf","pages":0,"milliseconds":1,"failure":{"code":"too-large","detail":"bogus"}}}"#] {
            XCTAssertNil(ExtractorMessage(line: line), line)
        }
    }

    func testRoundTripsEveryFailure() {
        let failures: [ExtractionError] = [
            .tooLarge(.fileBytes), .tooLarge(.pages), .tooLarge(.text), .tooLarge(.output), .tooLarge(.zipEntries),
            .tooLarge(.zipPart), .tooLarge(.zipTotal), .tooLarge(.zipRatio), .tooLarge(.xmlDepth),
            .timeout, .memory, .unsupported("xlsx"), .unavailableOnSystem, .encrypted, .unreadable("zip: x"),
            .crashed("signal 9"), .junk, .empty,
        ]
        for failure in failures {
            let message = ExtractorMessage.summary(ExtractionSummary(kind: .docx, pages: 0, milliseconds: 1, failure: failure))
            XCTAssertFalse(message.line.contains("\n"))
            XCTAssertEqual(ExtractorMessage(line: message.line), message, "\(failure)")
        }
        let page = ExtractorMessage.page(ExtractedPage(page: 7, text: "a\n\"b\"\\ / \u{0}\u{1F} ё", junk: 0.5))
        XCTAssertFalse(page.line.contains("\n"))
        XCTAssertEqual(ExtractorMessage(line: page.line), page)
    }

    func testPageFlags() {
        XCTAssertTrue(ExtractedPage(page: 1, text: "x", junk: 0.5).isJunk)
        XCTAssertFalse(ExtractedPage(page: 1, text: "x", junk: 0.49).isJunk)
        XCTAssertFalse(ExtractedPage(page: 1, text: "x").isJunk)
        XCTAssertFalse(ExtractedPage(page: 1, text: " \n\t").hasText)
    }

    func testCapsJSONKeepsDefaultsForMissingKeys() throws {
        let caps = try JSONDecoder().decode(ExtractionCaps.self, from: Data(#"{"maxPages":3,"timeoutSeconds":1.5}"#.utf8))
        var expected = ExtractionCaps()
        expected.maxPages = 3
        expected.timeoutSeconds = 1.5
        XCTAssertEqual(caps, expected)
        XCTAssertEqual(try JSONDecoder().decode(ExtractionCaps.self, from: Data(ExtractionCaps().json.utf8)), ExtractionCaps())
        XCTAssertThrowsError(try JSONDecoder().decode(ExtractionCaps.self, from: Data(#"{"maxPages":"many"}"#.utf8)))
        // Text of short CRLF lines at the text cap still fits the output cap.
        var small = ExtractionCaps()
        small.maxTextBytes = 200_000
        small.maxPages = 1
        let crlf = String(repeating: "\r\n", count: 100_000)   // 200 KB, 400 KB escaped
        XCTAssertLessThanOrEqual(ExtractorMessage.page(ExtractedPage(page: 1, text: crlf)).line.utf8.count + 1, small.maxOutputBytes)
    }
}
