import XCTest
@testable import LLMTrayCore

final class DocumentKindTests: XCTestCase {
    private func kind(_ s: String) -> DocumentKind { DocumentKind.detect(Data(s.utf8)) }

    /// A minimal OLE2 file: header, one FAT sector, one directory sector
    /// holding the root and one stream named `stream`.
    static func compoundFile(stream: String, loop: Bool = false) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ bytes: [UInt8], at o: Int) { header.replaceSubrange(o..<(o + bytes.count), with: bytes) }
        put(CompoundFile.magic, at: 0)
        put(le16(0x3E), at: 0x18); put(le16(3), at: 0x1A); put(le16(0xFFFE), at: 0x1C)
        put(le16(9), at: 0x1E); put(le16(6), at: 0x20)
        put(le32(1), at: 0x2C)            // one FAT sector
        put(le32(1), at: 0x30)            // directory at sector 1
        put(le32(4096), at: 0x38)
        put(le32(0xFFFF_FFFE), at: 0x3C); put(le32(0), at: 0x40)
        put(le32(0xFFFF_FFFE), at: 0x44); put(le32(0), at: 0x48)
        for i in 0..<109 { put(le32(i == 0 ? 0 : 0xFFFF_FFFF), at: 0x4C + i * 4) }
        var fat = [UInt8](repeating: 0xFF, count: 512)
        fat.replaceSubrange(0..<4, with: le32(0xFFFF_FFFD))                  // sector 0: the FAT
        fat.replaceSubrange(4..<8, with: le32(loop ? 1 : 0xFFFF_FFFE))       // sector 1: the directory
        func entry(_ name: String, type: UInt8, child: Int) -> [UInt8] {
            var e = [UInt8](repeating: 0, count: 128)
            let units = Array(name.utf16) + [0]
            for (i, u) in units.enumerated() { e[i * 2] = UInt8(u & 0xFF); e[i * 2 + 1] = UInt8(u >> 8) }
            e.replaceSubrange(64..<66, with: le16(units.count * 2))
            e[66] = type
            e.replaceSubrange(68..<72, with: le32(0xFFFF_FFFF))
            e.replaceSubrange(72..<76, with: le32(0xFFFF_FFFF))
            e.replaceSubrange(76..<80, with: le32(child))
            return e
        }
        let directory = entry("Root Entry", type: 5, child: 1) + entry(stream, type: 2, child: 0xFFFF_FFFF)
            + [UInt8](repeating: 0, count: 256)
        return Data(header + fat + directory)
    }

    func testByMagic() {
        XCTAssertEqual(kind("%PDF-1.7\n..."), .pdf)
        XCTAssertEqual(kind("junk before it %PDF-1.4"), .pdf)
        XCTAssertEqual(kind("{\\rtf1\\ansi hello}"), .rtf)
        XCTAssertEqual(DocumentKind.detect(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), .image)
        XCTAssertEqual(DocumentKind.detect(Data([0xFF, 0xD8, 0xFF, 0xE0])), .image)
    }

    func testHTMLAndText() {
        XCTAssertEqual(kind("<!DOCTYPE html><html><body>x</body></html>"), .html)
        XCTAssertEqual(kind("\u{FEFF}  <html lang=ru>"), .html)
        XCTAssertEqual(kind("<div><head></head></div>"), .html)
        XCTAssertEqual(kind("# Markdown\n\nSome *text*"), .text)
        XCTAssertEqual(kind("func main() { print(\"<html>\") }"), .text)
        XCTAssertEqual(kind("<?xml version=\"1.0\"?><w:wordDocument/>"), .text)   // WordML 2003
        XCTAssertEqual(DocumentKind.detect("Привет".data(using: .utf16)!), .text)
        let cp1251 = "Договор".data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue))))!
        XCTAssertEqual(DocumentKind.detect(cp1251), .text)
        XCTAssertEqual(DocumentKind.detect(Data([0x7F, 0x45, 0x4C, 0x46, 0, 0, 0])), .unknown)   // a binary
        XCTAssertEqual(DocumentKind.detect(Data()), .text)
    }

    func testZipContainersByTheirParts() {
        XCTAssertEqual(DocumentKind.detect(TestZip.docx(body: TestZip.paragraph("x"))), .docx)
        let xlsx = TestZip(); xlsx.add("xl/workbook.xml", "<workbook/>")
        XCTAssertEqual(DocumentKind.detect(xlsx.finish()), .xlsx)
        let pptx = TestZip(); pptx.add("ppt/presentation.xml", "<p/>")
        XCTAssertEqual(DocumentKind.detect(pptx.finish()), .pptx)
        let odt = TestZip()
        odt.add("mimetype", "application/vnd.oasis.opendocument.text", store: true)
        odt.add("content.xml", "<office:document-content/>")
        XCTAssertEqual(DocumentKind.detect(odt.finish()), .odt)
        let ods = TestZip(); ods.add("mimetype", "application/vnd.oasis.opendocument.spreadsheet", store: true)
        XCTAssertEqual(DocumentKind.detect(ods.finish()), .zip)
        // The main part renamed, found through [Content_Types].xml.
        let renamed = TestZip()
        renamed.add("[Content_Types].xml", "<Types><Override PartName=\"/w/main.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>")
        XCTAssertEqual(DocumentKind.detect(renamed.finish()), .docx)
        let plain = TestZip(); plain.add("readme.txt", "hi")
        XCTAssertEqual(DocumentKind.detect(plain.finish()), .zip)
        // Truncated: a zip that can't be read is just a zip.
        XCTAssertEqual(DocumentKind.detect(TestZip.docx(body: "").prefix(100)), .zip)
    }

    func testCompoundFilesByTheirStreams() {
        XCTAssertEqual(DocumentKind.detect(Self.compoundFile(stream: "WordDocument")), .doc)
        XCTAssertEqual(DocumentKind.detect(Self.compoundFile(stream: "Workbook")), .xls)
        XCTAssertEqual(DocumentKind.detect(Self.compoundFile(stream: "PowerPoint Document")), .ppt)
        XCTAssertEqual(DocumentKind.detect(Self.compoundFile(stream: "EncryptedPackage")), .encryptedOffice)
        XCTAssertEqual(DocumentKind.detect(Self.compoundFile(stream: "Other")), .compoundFile)
        // A FAT loop or a cut file: an error, not a hang.
        XCTAssertEqual(DocumentKind.detect(Self.compoundFile(stream: "WordDocument", loop: true)), .compoundFile)
        XCTAssertEqual(DocumentKind.detect(Self.compoundFile(stream: "WordDocument").prefix(600)), .compoundFile)
    }

    func testSupportedSetIsV1a() {
        XCTAssertEqual(Set([DocumentKind.pdf, .docx, .odt, .doc, .rtf, .html, .text, .xlsx, .pptx, .xls, .ppt, .image,
                            .encryptedOffice, .zip, .compoundFile, .unknown].filter(\.isSupported)),
                       [.pdf, .docx, .odt, .doc, .rtf, .html, .text])
        XCTAssertEqual(Set([DocumentKind.pdf, .docx, .odt, .doc, .rtf, .html, .text].filter(\.needsAppleImporter)),
                       [.docx, .odt, .doc, .rtf])
    }
}
