import XCTest
@testable import LLMTrayCore

final class XMLPartCheckTests: XCTestCase {
    private func check(_ xml: String, depth: Int = 256, allowExternal: Bool = false) throws {
        try XMLPartCheck.check(Data(xml.utf8), part: "p.xml", maxDepth: depth, allowExternalDoctype: allowExternal)
    }

    func testOrdinaryPartPasses() {
        XCTAssertNoThrow(try check("<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"x\"><w:t>a &amp; b</w:t></w:document>"))
    }

    func testBillionLaughsIsRefused() {
        let laughs = """
        <?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">\
        <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">]><lolz>&lol3;</lolz>
        """
        XCTAssertThrowsError(try check(laughs))
        // Even where an external DOCTYPE is allowed: this one has a subset.
        XCTAssertThrowsError(try check(laughs, allowExternal: true))
    }

    func testExternalEntityIsRefused() {
        let xxe = "<?xml version=\"1.0\"?><!doctype r [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><r>&x;</r>"
        XCTAssertThrowsError(try check(xxe))
        XCTAssertThrowsError(try check(xxe, allowExternal: true))
    }

    func testBareExternalDoctypeOnlyWhereAllowed() {
        // What ODF writers put on META-INF/manifest.xml.
        let manifest = "<?xml version=\"1.0\"?><!DOCTYPE manifest:manifest PUBLIC \"-//OpenOffice.org//DTD Manifest 1.0//EN\" \"Manifest.dtd\"><manifest:manifest xmlns:manifest=\"urn:x\"/>"
        XCTAssertThrowsError(try check(manifest))
        XCTAssertNoThrow(try check(manifest, allowExternal: true))
    }

    func testDoctypeFoundAnywhereAndInAnyCase() {
        let late = "<?xml version=\"1.0\"?><!--" + String(repeating: "x", count: 100_000) + "--><!DoCtYpE r [ ]><r/>"
        XCTAssertEqual(XMLPartCheck.doctype(Data(late.utf8)), .internalSubset)
        XCTAssertNil(XMLPartCheck.doctype(Data("<r>no doctype here</r>".utf8)))
    }

    func testDoctypeInUTF16IsRefused() {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE r SYSTEM \"x.dtd\"><r/>"
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            let data = xml.data(using: encoding)!
            XCTAssertEqual(XMLPartCheck.doctype(data), .internalSubset, "\(encoding)")
            XCTAssertThrowsError(try XMLPartCheck.check(data, part: "p", maxDepth: 256, allowExternalDoctype: true))
        }
    }

    func testNestingCap() {
        func nested(_ n: Int) -> String { String(repeating: "<a>", count: n) + String(repeating: "</a>", count: n) }
        XCTAssertNoThrow(try check(nested(256)))
        XCTAssertThrowsError(try check(nested(257))) { XCTAssertEqual($0 as? ExtractionError, .tooLarge(.xmlDepth)) }
        // 200k levels: stopped at the cap, quickly.
        let start = Date()
        XCTAssertThrowsError(try check(nested(200_000)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testMalformedAndTruncated() {
        XCTAssertThrowsError(try check("<a><b></a>"))
        XCTAssertThrowsError(try check("<?xml version=\"1.0\"?><w:document><w:t>cut"))
        XCTAssertThrowsError(try check(""))
    }
}
