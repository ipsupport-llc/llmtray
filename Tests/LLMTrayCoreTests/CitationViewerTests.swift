import Foundation
@testable import LLMTrayCore
import XCTest

final class CitationViewerTests: XCTestCase {
    func testOpensInViewer() {
        XCTAssertTrue(CitationViewer.opensInViewer(URL(fileURLWithPath: "/p/files/3.pdf")))
        XCTAssertTrue(CitationViewer.opensInViewer(URL(fileURLWithPath: "/Users/me/Docs/Report.PDF")))
        XCTAssertFalse(CitationViewer.opensInViewer(URL(fileURLWithPath: "/p/files/4.docx")))
        XCTAssertFalse(CitationViewer.opensInViewer(URL(fileURLWithPath: "/p/files/5.txt")))
        XCTAssertFalse(CitationViewer.opensInViewer(URL(fileURLWithPath: "/p/pdf")))
    }

    func testPageIndexIsClamped() {
        XCTAssertEqual(CitationViewer.pageIndex(1, pageCount: 10), 0)
        XCTAssertEqual(CitationViewer.pageIndex(7, pageCount: 10), 6)
        XCTAssertEqual(CitationViewer.pageIndex(10, pageCount: 10), 9)
        XCTAssertEqual(CitationViewer.pageIndex(12, pageCount: 10), 9, "a changed file may be shorter")
        XCTAssertEqual(CitationViewer.pageIndex(0, pageCount: 10), 0)
        XCTAssertEqual(CitationViewer.pageIndex(-3, pageCount: 10), 0)
        XCTAssertNil(CitationViewer.pageIndex(1, pageCount: 0))
    }

    func testQuoteRange() {
        let page = "Heading\nThe payment is due in ten days.\nLate fees apply after that."
        let whole = CitationViewer.quoteRange("The payment is due in ten days.\nLate fees apply", in: page)
        XCTAssertEqual(whole.map { (page as NSString).substring(with: $0) }, "The payment is due in ten days.\nLate fees apply")
        // Not all of it is on the page now: its first line is.
        let partial = CitationViewer.quoteRange("  The payment is due in ten days.\nSomething else", in: page)
        XCTAssertEqual(partial.map { (page as NSString).substring(with: $0) }, "The payment is due in ten days.")
        XCTAssertNil(CitationViewer.quoteRange("Nowhere on this page", in: page))
        XCTAssertNil(CitationViewer.quoteRange("Late\nnothing", in: page), "a first line too short to match safely")
        XCTAssertNil(CitationViewer.quoteRange(" \n ", in: page))
        XCTAssertNil(CitationViewer.quoteRange("text", in: ""))
    }

    func testQuoteRangeMatchesDecomposedText() {
        // PDFKit on macOS 14 returns decomposed text; the index may hold either.
        let page = "Caf\u{0065}\u{0301} au lait, r\u{0065}\u{0301}sum\u{0065}\u{0301}"
        let range = CitationViewer.quoteRange("Caf\u{00E9} au lait", in: page)
        XCTAssertEqual(range?.location, 0)
        XCTAssertEqual(range?.length, 13, "in the page's UTF-16 units")
    }

    func testQuoteRangeInUTF16Units() {
        let page = "\u{1F4C4} Emoji first, then the quote here."
        let range = CitationViewer.quoteRange("the quote here.", in: page)
        XCTAssertEqual(range.map { (page as NSString).substring(with: $0) }, "the quote here.")
    }
}
