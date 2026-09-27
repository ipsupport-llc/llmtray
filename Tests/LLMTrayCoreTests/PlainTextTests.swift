import XCTest
@testable import LLMTrayCore

final class PlainTextTests: XCTestCase {
    func testDecoding() {
        XCTAssertEqual(PlainText.decode(Data("Привет, world".utf8)), "Привет, world")
        XCTAssertEqual(PlainText.decode("Привет".data(using: .utf16)!), "Привет")
        let cp1251 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)))
        XCTAssertEqual(PlainText.decode("Договор №5".data(using: cp1251)!), "Договор №5")
        // Never loses a byte: invalid UTF-8 is read as cp1251 whole (0xFF is "я").
        XCTAssertEqual(PlainText.decode(Data("hello".utf8) + Data([0xFF])), "helloя")
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
        // cp1251 text full of 0x80-0xBF bytes ("Ђ", "Ѓ"...): full-size pages, not a byte each.
        let legacy = Data(repeating: 0x80, count: 10_000)
        XCTAssertEqual(try PlainText.pages(legacy, caps: ExtractionCaps(), pageBytes: 1000).count, 10)
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
