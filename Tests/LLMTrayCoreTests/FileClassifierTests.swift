import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LLMTrayCore

final class FileClassifierTests: FolderTestCase {
    private func info(_ path: String, hash: Bool = false, classifier: FileClassifier = FileClassifier()) throws -> FileInfo {
        try classifier.info(walker.resolve(SafeFolderWalker.components(path)), walker: walker, hash: hash)
    }

    func testGitsBinaryHeuristic() {
        XCTAssertFalse(FileClassifier.isBinary(Data("plain\ttext\r\nwith\u{1B}[0m escapes\u{0C}\n".utf8)))
        XCTAssertTrue(FileClassifier.isBinary(Data([0x41, 0x00, 0x42])), "a NUL")
        // Non-printables: binary once they outnumber printable / 128.
        var mostlyText = Data(repeating: 0x61, count: 256)
        mostlyText.append(contentsOf: [0x01])
        XCTAssertFalse(FileClassifier.isBinary(mostlyText), "1 control byte per 256 printable")
        mostlyText.append(contentsOf: [0x02, 0x03])
        XCTAssertTrue(FileClassifier.isBinary(mostlyText), "3 per 256")
        XCTAssertFalse(FileClassifier.isBinary(Data("dos text".utf8) + Data([0x1A])), "a trailing ^Z isn't counted")
        XCTAssertFalse(FileClassifier.isBinary(Data("\u{7F}".utf8) + Data(repeating: 0x61, count: 128)))
    }

    func testEncodings() {
        XCTAssertEqual(FileClassifier.encoding(Data("hello".utf8)), .ascii)
        XCTAssertEqual(FileClassifier.encoding(Data("привет, мир".utf8)), .utf8)
        XCTAssertEqual(FileClassifier.encoding(Data([0xEF, 0xBB, 0xBF]) + Data("x".utf8)), .utf8BOM)
        XCTAssertEqual(FileClassifier.encoding(Data([0xFF, 0xFE, 0x41, 0x00])), .utf16LE)
        XCTAssertEqual(FileClassifier.encoding(Data([0xFE, 0xFF, 0x00, 0x41])), .utf16BE)
        let cp1251 = "Привет, это обычный русский текст".data(using: TextEncodingGuess.windows1251.stringEncoding)!
        XCTAssertEqual(FileClassifier.encoding(cp1251), .windows1251)
        let cp1252 = "Le garçon a mangé une crème brûlée à côté".data(using: .windowsCP1252)!
        XCTAssertEqual(FileClassifier.encoding(cp1252), .windows1252)
        // A window that cuts a UTF-8 sequence is still UTF-8.
        let cut = Data("ab€".utf8).dropLast()
        XCTAssertEqual(FileClassifier.encoding(Data(cut), complete: false), .utf8)
    }

    func testTextInfoIsBounded() throws {
        let lines = (1...100).map { "line \($0)" }.joined(separator: "\n")
        write("notes.md", lines)
        let i = try info("notes.md")
        XCTAssertEqual(i.isText, true)
        XCTAssertEqual(i.encoding, .ascii)
        XCTAssertEqual(i.lineCount, 100)
        XCTAssertEqual(i.lineCountComplete, true)
        XCTAssertEqual(i.head?.split(separator: "\n").count, 20)
        XCTAssertEqual(i.headTruncated, true)
        XCTAssertEqual(i.contentType, UTType("net.daringfireball.markdown")?.identifier ?? i.contentType)
        XCTAssertFalse(i.typeMismatch)
        // The line count stops at its cap and says so.
        var caps = FileClassifier.Caps()
        caps.lineCountBytes = 50
        caps.chunkBytes = 16
        let capped = try info("notes.md", classifier: FileClassifier(caps: caps))
        XCTAssertEqual(capped.lineCountComplete, false)
        XCTAssertLessThan(capped.lineCount!, 100)
        // The head is cut between characters.
        write("ru.txt", String(repeating: "я", count: 3000))
        let ru = try info("ru.txt")
        XCTAssertEqual(ru.encoding, .utf8)
        XCTAssertEqual(ru.head?.count, 1024)
        XCTAssertEqual(ru.lineCount, 1)
    }

    func testUTF16Text() throws {
        var data = Data([0xFF, 0xFE])
        data.append("one\ntwo\nthree".data(using: .utf16LittleEndian)!)
        writeData("u16.txt", data)
        let i = try info("u16.txt")
        XCTAssertEqual(i.isText, true)
        XCTAssertEqual(i.encoding, .utf16LE)
        XCTAssertEqual(i.lineCount, 3)
        XCTAssertEqual(i.head, "one\ntwo\nthree")
    }

    func testMagicBytesAgainstTheName() throws {
        writeData("report.txt", Data("%PDF-1.7\n%âãÏÓ\n1 0 obj".utf8))
        let pdf = try info("report.txt")
        XCTAssertEqual(pdf.contentType, UTType.pdf.identifier)
        XCTAssertEqual(pdf.mimeType, "application/pdf")
        XCTAssertEqual(pdf.extensionType, UTType.plainText.identifier)
        XCTAssertTrue(pdf.typeMismatch)
        XCTAssertEqual(pdf.isText, false)
        XCTAssertNil(pdf.head)
        // A docx is a zip: not a mismatch under its own name.
        writeData("doc.docx", Data([0x50, 0x4B, 0x03, 0x04]) + Data(count: 60))
        XCTAssertFalse(try info("doc.docx").typeMismatch)
        writeData("blob.bin", Data([0x00, 0x01, 0x02, 0x03]))
        let blob = try info("blob.bin")
        XCTAssertEqual(blob.isText, false)
        XCTAssertNil(blob.encoding)
    }

    func testImagePixelSize() throws {
        let path = grant + "/pic.png"
        let ctx = CGContext(data: nil, width: 7, height: 5, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let i = try info("pic.png")
        XCTAssertEqual(i.contentType, UTType.png.identifier)
        XCTAssertEqual(i.pixelWidth, 7)
        XCTAssertEqual(i.pixelHeight, 5)
        XCTAssertFalse(i.typeMismatch)
    }

    func testHashIsStreamedAndCapped() throws {
        let data = Data((0..<300_000).map { UInt8($0 % 251) })
        writeData("big.bin", data)
        var caps = FileClassifier.Caps()
        caps.chunkBytes = 4096
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try info("big.bin", hash: true, classifier: FileClassifier(caps: caps)).hash, .sha256(expected))
        XCTAssertNil(try info("big.bin").hash, "only when asked")
        caps.hashBytes = 1000
        XCTAssertEqual(try info("big.bin", hash: true, classifier: FileClassifier(caps: caps)).hash, .tooLarge(limit: 1000))
        // The time cap, on a clock that jumps a second per look.
        caps.hashBytes = 1 << 30
        caps.hashSeconds = 3
        var t = Date(timeIntervalSince1970: 0)
        let slow = FileClassifier(caps: caps) { t = t.addingTimeInterval(1); return t }
        XCTAssertEqual(try info("big.bin", hash: true, classifier: slow).hash, .timedOut(seconds: 3))
    }

    func testHardLinksAndNonFilesAreNotRead() throws {
        let target = write("real.txt", "private", in: outside)
        try fm.linkItem(atPath: target, toPath: grant + "/link.txt")
        let linked = try info("link.txt", hash: true)
        XCTAssertTrue(linked.hardLinked)
        XCTAssertNil(linked.head)
        XCTAssertNil(linked.isText)
        XCTAssertEqual(linked.hash, .withheld("hard link"))
        XCTAssertNotNil(linked.note)
        try fm.createSymbolicLink(atPath: grant + "/sym", withDestinationPath: outside + "/real.txt")
        let sym = try info("sym")
        XCTAssertEqual(sym.kind, .symlink)
        XCTAssertNil(sym.head)
        mkdir("App.app/Contents")
        XCTAssertEqual(try info("App.app").kind, .package)
    }
}
