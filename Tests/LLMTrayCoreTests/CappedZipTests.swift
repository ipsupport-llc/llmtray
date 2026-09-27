import XCTest
@testable import LLMTrayCore

final class CappedZipTests: XCTestCase {
    private func caps(_ edit: (inout ExtractionCaps) -> Void = { _ in }) -> ExtractionCaps {
        var c = ExtractionCaps()
        edit(&c)
        return c
    }

    private func assertThrows(_ expected: ExtractionError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let e as ExtractionError {
            XCTAssertEqual(e, expected, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    private func assertUnreadable(_ fragment: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("expected unreadable(\(fragment))", file: file, line: line)
        } catch ExtractionError.unreadable(let why) {
            XCTAssertTrue(why.contains(fragment), "\(why)", file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    func testReadsStoredAndDeflatedParts() throws {
        let z = TestZip()
        z.add("a.txt", "stored text", store: true)
        z.add("b.xml", "<r>" + String(repeating: "deflated ", count: 1000) + "</r>")
        let zip = try CappedZip(data: z.finish(), caps: caps())
        XCTAssertEqual(zip.entries.map(\.name), ["a.txt", "b.xml"])
        XCTAssertEqual(String(decoding: try zip.read("a.txt"), as: UTF8.self), "stored text")
        XCTAssertTrue(String(decoding: try zip.read("b.xml"), as: UTF8.self).hasSuffix("deflated </r>"))
        XCTAssertNoThrow(try zip.checkAll())
    }

    func testASlicedDataWorksLikeAWholeOne() throws {
        let whole = Data([1, 2, 3]) + TestZip.docx(body: TestZip.paragraph("x"))
        let zip = try CappedZip(data: whole.dropFirst(3), caps: caps())
        XCTAssertNotNil(zip.entry("word/document.xml"))
        XCTAssertNoThrow(try zip.checkAll())
    }

    // MARK: Bombs

    func testRatioBombStopsAtTheRatioCap() {
        let z = TestZip()
        z.add("word/document.xml", Data(count: 20 << 20))   // 20 MB of zeros -> ~20 KB
        let data = z.finish()
        XCTAssertLessThan(data.count, 100_000)
        assertThrows(.tooLarge(.zipRatio)) { try CappedZip(data: data, caps: caps()).checkAll() }
    }

    func testPartCapAndDeclaredSize() {
        let z = TestZip()
        z.add("big.bin", Data(count: 3 << 20))
        let data = z.finish()
        // The declared size alone refuses it.
        assertThrows(.tooLarge(.zipPart)) {
            try CappedZip(data: data, caps: caps { $0.maxZipPartBytes = 1 << 20; $0.maxZipRatio = 1e9 }).read("big.bin")
        }
    }

    func testLyingDeclaredSizeIsCaughtWhileInflating() {
        let z = TestZip()
        z.add("big.bin", Data(count: 3 << 20), declaredSize: 4096)
        let data = z.finish()
        assertThrows(.tooLarge(.zipPart)) {
            try CappedZip(data: data, caps: caps { $0.maxZipPartBytes = 1 << 20; $0.maxZipRatio = 1e9 }).read("big.bin", keep: false)
        }
        assertThrows(.tooLarge(.zipRatio)) {
            try CappedZip(data: data, caps: caps()).read("big.bin", keep: false)
        }
    }

    func testTotalCapAcrossParts() {
        let z = TestZip()
        for i in 0..<4 { z.add("p\(i).bin", Data(count: 1 << 20)) }
        let data = z.finish()
        assertThrows(.tooLarge(.zipTotal)) {
            try CappedZip(data: data, caps: caps { $0.maxZipTotalBytes = 3 << 20; $0.maxZipRatio = 1e9 }).checkAll()
        }
        XCTAssertNoThrow(try CappedZip(data: data, caps: caps { $0.maxZipRatio = 1e9 }).checkAll())
    }

    func testOverlappingEntriesAreRefused() {
        // Fifield's non-recursive bomb: many central records, one kernel.
        let z = TestZip()
        let kernel = TestZip.deflate(Data(count: 1 << 20))
        let at = z.offset
        z.addRaw("a.xml", method: 8, payload: kernel, size: 1 << 20, crc: TestZip.crc(Data(count: 1 << 20)))
        z.addRaw("b.xml", method: 8, payload: kernel, size: 1 << 20, crc: 0, offset: at)
        assertUnreadable("overlap") { _ = try CappedZip(data: z.finish(), caps: caps()) }
    }

    func testEntryCap() {
        let z = TestZip()
        for i in 0..<50 { z.add("f\(i).txt", "x", store: true) }
        let data = z.finish()
        assertThrows(.tooLarge(.zipEntries)) { _ = try CappedZip(data: data, caps: caps { $0.maxZipEntries = 49 }) }
        XCTAssertNoThrow(try CappedZip(data: data, caps: caps { $0.maxZipEntries = 50 }))
    }

    // MARK: Refused layouts

    func testZip64IsRefused() {
        let z = TestZip()
        z.add("a.txt", "x", store: true)
        z.endRecordCount = 0xFFFF
        assertUnreadable("zip64") { _ = try CappedZip(data: z.finish(), caps: caps()) }
    }

    func testEncryptedPartIsEncrypted() {
        let z = TestZip()
        z.add("word/document.xml", Data("<x/>".utf8), flags: 1)
        assertThrows(.encrypted) { try CappedZip(data: z.finish(), caps: caps()).checkAll() }
    }

    func testDuplicateNamesAreRefused() {
        let z = TestZip()
        z.add("word/document.xml", "<a/>")
        z.add("word/document.xml", "<b/>")
        assertUnreadable("two entries") { _ = try CappedZip(data: z.finish(), caps: caps()) }
    }

    func testLocalHeaderNamingAnotherPartIsRefused() {
        let z = TestZip()
        z.addRaw("word/document.xml", method: 0, payload: Data("<a/>".utf8), size: 4, crc: 0, localName: "word/other.xml")
        assertUnreadable("local header") { try CappedZip(data: z.finish(), caps: caps()).read("word/document.xml") }
    }

    func testNestedArchiveIsNeverHandedOut() throws {
        let inner = TestZip.docx(body: TestZip.paragraph("inner"))
        let z = TestZip()
        z.add("word/embeddings/x.xlsx", inner)
        let zip = try CappedZip(data: z.finish(), caps: caps())
        assertUnreadable("nested archive") { try zip.read("word/embeddings/x.xlsx") }
        // An embedded object is counted, never opened, by the pre-check...
        XCTAssertNoThrow(try zip.checkAll())
        // ...but an archive anywhere else refuses the container, stored or
        // deflated, whatever its name says.
        for store in [false, true] {
            let other = TestZip()
            other.add("word/media/image1.png", inner, store: store)
            assertUnreadable("nested archive") { try CappedZip(data: other.finish(), caps: caps()).checkAll() }
            let ole = TestZip()
            ole.add("word/media/x.bin", Data(CompoundFile.magic) + Data(count: 100), store: store)
            assertUnreadable("nested archive") { try CappedZip(data: ole.finish(), caps: caps()).checkAll() }
        }
    }

    func testLocalHeaderDisagreeingWithTheCentralRecordIsRefused() {
        // The central record says stored, 4 bytes; the local header says deflated.
        let z = TestZip()
        z.addRaw("a.xml", method: 0, payload: Data("<a/>".utf8), size: 4, crc: 0, localMethod: 8)
        assertUnreadable("disagrees") { try CappedZip(data: z.finish(), caps: caps()).checkAll() }
        let sizes = TestZip()
        sizes.addRaw("a.xml", method: 0, payload: Data("<a/>".utf8), size: 4, crc: 0, localSize: 4_000_000)
        assertUnreadable("disagrees") { try CappedZip(data: sizes.finish(), caps: caps()).checkAll() }
    }

    func testCentralDirectoryMustHoldExactlyItsEntries() {
        // Two records, the end record claiming one: the second would go unchecked.
        let z = TestZip()
        z.add("a.xml", "<a/>")
        z.add("b.xml", "<!DOCTYPE b [<!ENTITY x 'y'>]><b>&x;</b>")
        z.endRecordCount = 1
        assertUnreadable("more than") { _ = try CappedZip(data: z.finish(), caps: caps()) }
    }

    func testDataDescriptorBitMustAgree() {
        let z = TestZip()
        z.addRaw("a.xml", method: 0, payload: Data("<a/>".utf8), size: 4, crc: 0, localFlags: 8)
        assertUnreadable("disagrees") { try CappedZip(data: z.finish(), caps: caps()).checkAll() }
    }

    func testXMLFoundByContentAndVML() {
        let hostile = "<?xml version='1.0'?><!DOCTYPE v [<!ENTITY x 'y'>]><v>&x;</v>"
        for name in ["word/drawing.vml", "word/strange.bin", "customXml/item1", "word/media/x.xml", "word/media/main.bin", "word/media/evil.svg"] {
            let z = TestZip()
            z.add(name, hostile)
            assertUnreadable("DOCTYPE") { try CappedZip(data: z.finish(), caps: caps()).checkAll() }
        }
        // Padded past the bytes looked at first: still XML.
        let padded = TestZip()
        padded.add("word/padded.bin", String(repeating: " ", count: 200) + hostile)
        assertUnreadable("DOCTYPE") { try CappedZip(data: padded.finish(), caps: caps()).checkAll() }
        // Whitespace, then something that isn't XML: a blob, not refused.
        let blob = TestZip()
        blob.add("word/blob.bin", String(repeating: " ", count: 200) + "not xml at all")
        XCTAssertNoThrow(try CappedZip(data: blob.finish(), caps: caps()).checkAll())
        // A PNG, or an SVG with its DOCTYPE among the images, stays a counted blob.
        let svg = TestZip()
        svg.add("word/media/image2.svg", "<?xml version='1.0'?><!DOCTYPE svg PUBLIC '-//W3C//DTD SVG 1.1//EN' 'svg11.dtd'><svg/>")
        XCTAssertNoThrow(try CappedZip(data: svg.finish(), caps: caps()).checkAll())
        let png = TestZip()
        png.add("word/media/image1.png", Data([0x89, 0x50, 0x4E, 0x47]) + Data(count: 100))
        XCTAssertNoThrow(try CappedZip(data: png.finish(), caps: caps()).checkAll())
    }

    func testODFExternalDoctypeOnlyOnTheManifest() {
        let doctype = "<?xml version=\"1.0\"?><!DOCTYPE m PUBLIC \"-//OpenOffice.org//DTD Manifest 1.0//EN\" \"Manifest.dtd\"><m/>"
        let manifest = TestZip()
        manifest.add("META-INF/manifest.xml", doctype)
        XCTAssertNoThrow(try CappedZip(data: manifest.finish(), caps: caps()).checkAll(odf: true))
        assertUnreadable("DOCTYPE") { try CappedZip(data: manifest.finish(), caps: caps()).checkAll() }
        let content = TestZip()
        content.add("content.xml", doctype)
        assertUnreadable("DOCTYPE") { try CappedZip(data: content.finish(), caps: caps()).checkAll(odf: true) }
    }

    func testZip64ExtraFieldIsRefused() {
        let z = TestZip()
        z.addRaw("a.xml", method: 0, payload: Data("<a/>".utf8), size: 4, crc: 0,
                 centralExtra: Data([0x01, 0x00, 0x08, 0x00]) + Data(count: 8))
        assertUnreadable("zip64") { _ = try CappedZip(data: z.finish(), caps: caps()) }
    }

    func testUnknownMethodIsRefused() {
        let z = TestZip()
        z.addRaw("a.xml", method: 9, payload: Data([1, 2, 3]), size: 3, crc: 0)   // Deflate64
        assertUnreadable("method 9") { try CappedZip(data: z.finish(), caps: caps()).checkAll() }
    }

    func testTruncatedAndGarbageArchives() {
        let full = TestZip.docx(body: TestZip.paragraph("hello"))
        for cut in [10, full.count / 2, full.count - 10] {
            XCTAssertThrowsError(try CappedZip(data: full.prefix(cut), caps: caps()).checkAll(), "cut at \(cut)")
        }
        XCTAssertThrowsError(try CappedZip(data: Data("PK\u{03}\u{04}garbage".utf8), caps: caps()))
        XCTAssertThrowsError(try CappedZip(data: Data(), caps: caps()))
        // Corrupt deflate data in an otherwise sound archive.
        let z = TestZip()
        z.addRaw("a.xml", method: 8, payload: Data(repeating: 0xFF, count: 64), size: 100, crc: 0)
        XCTAssertThrowsError(try CappedZip(data: z.finish(), caps: caps()).checkAll())
    }

    func testCheckAllRunsTheXMLChecks() {
        let doctype = "<?xml version=\"1.0\"?><!DOCTYPE lol [<!ENTITY lol \"lol\">]><w:document>&lol;</w:document>"
        let z = TestZip()
        z.add("word/document.xml", doctype)
        assertUnreadable("DOCTYPE") { try CappedZip(data: z.finish(), caps: caps()).checkAll() }

        let deep = String(repeating: "<a>", count: 300) + String(repeating: "</a>", count: 300)
        let d = TestZip.docx(body: "", extra: [("word/deep.xml", Data(deep.utf8))])
        assertThrows(.tooLarge(.xmlDepth)) { try CappedZip(data: d, caps: caps()).checkAll() }
    }
}
