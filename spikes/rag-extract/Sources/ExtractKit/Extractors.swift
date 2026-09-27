import AppKit
import Foundation
import PDFKit

public enum Extract {
    /// Detects the type and runs the matching extractor, emitting pages.
    public static func run(path: String, limits: Limits, emitter: Emitter, forceKind: Kind? = nil) throws -> Kind {
        let url = URL(fileURLWithPath: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size <= limits.maxFileBytes else { throw ExtractError("file is \(size) bytes > cap \(limits.maxFileBytes)") }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let kind = forceKind ?? Detect.kind(of: data, limits: limits)
        switch kind {
        case .pdf: try pdf(data, limits: limits, emitter: emitter)
        case .docx, .odt:
            // NSAttributedString unzips by itself, with no caps: a 2 GB bomb
            // docx took the child past 1 GB before the kill. Inflate every XML
            // member through the capped reader first (and throw away the result).
            if !limits.skipZipPrecheck { try zipPrecheck(data, limits: limits) }
            try attributed(data, kind: kind, emitter: emitter)
        case .doc, .rtf: try attributed(data, kind: kind, emitter: emitter)
        case .html: try html(data, limits: limits, emitter: emitter)
        case .text: text(data, limits: limits, emitter: emitter)
        case .xlsx: try XLSX.extract(data, limits: limits, emitter: emitter)
        case .pptx: try PPTX.extract(data, limits: limits, emitter: emitter)
        case .xls: try XLS.extract(data, limits: limits, emitter: emitter)
        case .ppt: try PPT.extract(data, limits: limits, emitter: emitter)
        case .image: emitter.emit(PageOut(page: 1, text: "", error: "image: needs tier 2 (OCR)"))
        case .encryptedOOXML: throw ExtractError("password-protected Office document")
        case .unknownZip:
            _ = try ZipArchive(data: data, limits: limits)   // surfaces the zip's own error, if any
            throw ExtractError("unsupported type (zip without a known main part)")
        case .unknownCFB, .unknown: throw ExtractError("unsupported type (\(kind.rawValue))")
        }
        return kind
    }

    static func zipPrecheck(_ data: Data, limits: Limits) throws {
        let zip = try ZipArchive(data: data, limits: limits)
        for name in zip.order where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
            _ = try zip.read(name, keep: false)
        }
    }

    // MARK: PDF

    public static func pdf(_ data: Data, limits: Limits, emitter: Emitter) throws {
        guard let doc = PDFDocument(data: data) else { throw ExtractError("pdf: PDFKit could not open it (corrupt or truncated)") }
        if doc.isLocked { throw ExtractError("pdf: password-protected") }
        let n = doc.pageCount
        if n == 0 { throw ExtractError("pdf: no pages") }
        if n > limits.maxPages {
            FileHandle.standardError.write("pdf: \(n) pages, extracting the first \(limits.maxPages)\n".data(using: .utf8)!)
        }
        for i in 0..<min(n, limits.maxPages) {
            let keepGoing: Bool = autoreleasepool {
                guard let page = doc.page(at: i) else {
                    return emitter.emit(PageOut(page: i + 1, text: "", error: "pdf: page unreadable"))
                }
                let text = page.string ?? ""
                return emitter.emit(PageOut(page: i + 1, text: text))
            }
            if !keepGoing { break }
        }
    }

    // MARK: docx / doc / odt / rtf

    public static func attributed(_ data: Data, kind: Kind, emitter: Emitter) throws {
        let type: NSAttributedString.DocumentType
        switch kind {
        case .docx: type = .officeOpenXML
        case .doc: type = .docFormat
        case .odt: type = .openDocument
        default: type = .rtf
        }
        var attrs: NSDictionary?
        let s = try NSAttributedString(data: data, options: [.documentType: type], documentAttributes: &attrs)
        emitter.emit(PageOut(page: 1, text: s.string))
    }

    // MARK: HTML (own parser; no WebKit, no network)

    public static func html(_ data: Data, limits: Limits, emitter: Emitter) throws {
        let s = decodeText(data)
        emitter.emit(PageOut(page: 1, text: HTMLText.text(s)))
    }

    // MARK: plain text / code

    public static func text(_ data: Data, limits: Limits, emitter: Emitter) {
        // Stream in 1 MB slices so a 1 GB file never becomes one String;
        // the emitter's text cap ends it.
        let slice = 1 << 20
        var off = 0
        var page = 1
        var carry = Data()
        while off < data.count {
            let end = min(data.count, off + slice)
            var chunk = carry + data[(data.startIndex + off)..<(data.startIndex + end)]
            carry = Data()
            // Don't split a UTF-8 sequence across pages.
            var back = 0
            while back < 4, back < chunk.count, chunk[chunk.endIndex - 1 - back] & 0xC0 == 0x80 { back += 1 }
            if back < chunk.count, chunk[chunk.endIndex - 1 - back] & 0x80 != 0, end < data.count {
                carry = chunk.suffix(back + 1)
                chunk = chunk.dropLast(back + 1)
            }
            if !emitter.emit(PageOut(page: page, text: decodeText(Data(chunk)))) { break }
            page += 1
            off = end
        }
    }

    /// UTF-8, UTF-16 with BOM, else Windows-1251 (the common Russian legacy
    /// encoding), else Latin-1.
    public static func decodeText(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16) ?? ""
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        let cp1251 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)))
        return String(data: data, encoding: cp1251) ?? String(decoding: data, as: UTF8.self)
    }
}
