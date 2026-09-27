import XCTest
@testable import LLMTrayCore

final class PlainTextTests: XCTestCase {
    func testDecoding() {
        XCTAssertEqual(PlainText.decode(Data("Привет, world".utf8)), "Привет, world")
        XCTAssertEqual(PlainText.decode("Привет".data(using: .utf16)!), "Привет")
        let cp1251 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)))
        XCTAssertEqual(PlainText.decode("Договор №5".data(using: cp1251)!), "Договор №5")
        // A UTF-8 sequence cut at the end is dropped, not read as cp1251.
        XCTAssertEqual(PlainText.decode(Data("Да".utf8).dropLast()), "Д")
    }

    func testPagesCutAtNewlinesAndNeverInsideACharacter() throws {
        let line = String(repeating: "ж", count: 99) + "\n"   // 199 bytes
        let text = String(repeating: line, count: 100)
        let pages = try PlainText.pages(Data(text.utf8), caps: ExtractionCaps(), pageBytes: 1000)
        XCTAssertEqual(pages.joined(), text)
        XCTAssertTrue(pages.dropLast().allSatisfy { $0.hasSuffix("\n") })
        // No newline to cut at: still whole characters.
        let solid = String(repeating: "ж", count: 5000)
        let solidPages = try PlainText.pages(Data(solid.utf8), caps: ExtractionCaps(), pageBytes: 999)
        XCTAssertEqual(solidPages.joined(), solid)
        XCTAssertGreaterThan(solidPages.count, 5)
        XCTAssertEqual(try PlainText.pages(Data(), caps: ExtractionCaps()), [])
    }

    func testCaps() {
        var caps = ExtractionCaps()
        caps.maxTextBytes = 10_000
        XCTAssertThrowsError(try PlainText.pages(Data(count: 0) + Data(repeating: 0x61, count: 20_000), caps: caps)) {
            XCTAssertEqual($0 as? ExtractionError, .tooLarge(.text))
        }
        caps = ExtractionCaps()
        caps.maxPages = 3
        XCTAssertThrowsError(try PlainText.pages(Data(repeating: 0x61, count: 5000), caps: caps, pageBytes: 1000)) {
            XCTAssertEqual($0 as? ExtractionError, .tooLarge(.pages))
        }
    }
}
