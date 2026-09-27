import Foundation

/// A document's type, told from its content, never its extension: an xlsx
/// named .docx, a pdf named .txt or a doc named .xls come out as what they
/// are. Containers (zip, OLE2) are told apart by their members.
public enum DocumentKind: String, Codable, Equatable, Sendable {
    case pdf, docx, odt, doc, rtf, html, text
    // Recognized, not indexed by this version.
    case xlsx, pptx, xls, ppt, image
    case encryptedOffice = "encrypted-office"
    case zip
    case compoundFile = "cfb"
    case unknown

    /// What v1a indexes (adr/0012, "Formats offered"): plain text, Markdown
    /// and code (all `text`), the PDF text layer, docx/doc/odt/rtf, HTML.
    public var isSupported: Bool {
        switch self {
        case .pdf, .docx, .odt, .doc, .rtf, .html, .text: return true
        default: return false
        }
    }

    /// The formats only Apple's importers (`NSAttributedString`) read, which
    /// run only in a child without network access.
    public var needsAppleImporter: Bool {
        switch self {
        case .docx, .odt, .doc, .rtf: return true
        default: return false
        }
    }

    public static func detect(_ data: Data, caps: ExtractionCaps = ExtractionCaps()) -> DocumentKind {
        let head = [UInt8](data.prefix(1024))
        func starts(_ s: [UInt8], at o: Int = 0) -> Bool {
            head.count >= o + s.count && Array(head[o..<(o + s.count)]) == s
        }
        if starts(Array("%PDF-".utf8)) { return .pdf }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) {
            return zipKind(data, caps: caps)
        }
        if starts(CompoundFile.magic) {
            guard let names = try? CompoundFile.topLevelNames(data) else { return .compoundFile }
            let lower = Set(names.map { $0.lowercased() })
            if lower.contains("encryptedpackage") { return .encryptedOffice }
            if lower.contains("worddocument") { return .doc }
            if lower.contains("workbook") || lower.contains("book") { return .xls }
            if lower.contains("powerpoint document") { return .ppt }
            return .compoundFile
        }
        if starts(Array("{\\rtf".utf8)) { return .rtf }
        // Readers accept "%PDF-" anywhere in the first KB -- after the exact
        // signatures, so a docx quoting it isn't taken for a PDF.
        if data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil { return .pdf }
        if starts([0x89, 0x50, 0x4E, 0x47]) || starts([0xFF, 0xD8, 0xFF]) || starts(Array("GIF8".utf8))
            || starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A])
            || (starts(Array("ftyp".utf8), at: 4) && head.count >= 12
                && ["heic", "heix", "mif1", "avif"].contains(String(decoding: head[8..<12], as: UTF8.self))) {
            return .image
        }
        // Text: UTF-16 with a BOM, or no NUL in the first 64 KB (UTF-8 or an
        // 8-bit legacy encoding, decoded later).
        let probe = data.prefix(64 * 1024)
        let utf16 = starts([0xFF, 0xFE]) || starts([0xFE, 0xFF])
        if !utf16 && probe.contains(0) { return .unknown }
        // The probe's end may cut a UTF-8 sequence: back off continuation bytes.
        var lead = probe.prefix(4096)
        if !utf16, lead.count == 4096 {
            var cut = lead.endIndex
            while cut > lead.startIndex, cut > lead.endIndex - 4, lead[cut - 1] & 0xC0 == 0x80 { cut -= 1 }
            if cut > lead.startIndex, lead[cut - 1] & 0xC0 == 0xC0 { cut -= 1 }
            lead = lead[..<cut]
        }
        let leadText = PlainText.decode(Data(lead))
        let leading = leadText
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            .prefix(1024).lowercased()
        if leading.hasPrefix("<!doctype html") || leading.hasPrefix("<html")
            || (leading.hasPrefix("<") && (leading.contains("<html") || leading.contains("<body") || leading.contains("<head"))) {
            return .html
        }
        return .text
    }

    private static func zipKind(_ data: Data, caps: ExtractionCaps) -> DocumentKind {
        guard let zip = try? CappedZip(data: data, caps: caps) else { return .zip }
        if zip.entry("word/document.xml") != nil { return .docx }
        if zip.entry("xl/workbook.xml") != nil { return .xlsx }
        if zip.entry("ppt/presentation.xml") != nil { return .pptx }
        if let m = try? zip.read("mimetype"), String(decoding: m.prefix(100), as: UTF8.self)
            .hasPrefix("application/vnd.oasis.opendocument.text") { return .odt }
        // A renamed main part, named only by [Content_Types].xml.
        if let ct = try? zip.read("[Content_Types].xml") {
            let s = String(decoding: ct, as: UTF8.self)
            if s.contains("wordprocessingml.document.main") { return .docx }
            if s.contains("spreadsheetml.sheet.main") { return .xlsx }
            if s.contains("presentationml.presentation.main") { return .pptx }
        }
        return .zip
    }
}

/// Just enough of OLE2 / Compound File Binary ([MS-CFB]) to name the root
/// storage's streams, which is what tells .doc from .xls and .ppt. Every
/// chain walk is bounded by the sector count: a FAT loop is an error, not a
/// hang.
enum CompoundFile {
    static let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    struct Invalid: Error {}

    private static func u16(_ d: Data, _ o: Int) -> Int {
        guard o >= 0, o + 2 <= d.count else { return 0 }
        return d.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian) }
    }

    private static func u32(_ d: Data, _ o: Int) -> Int {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        return d.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian) }
    }

    static func topLevelNames(_ input: Data) throws -> [String] {
        let data = input.startIndex == 0 ? input : Data(input)
        guard data.count >= 512, Array(data.prefix(8)) == magic else { throw Invalid() }
        let shift = u16(data, 0x1E)
        guard shift == 9 || shift == 12 else { throw Invalid() }
        let size = 1 << shift
        let sectorCount = max(0, data.count / size - 1)
        func sector(_ n: Int) throws -> Data {
            let off = (n + 1) * size
            guard n >= 0, off < data.count else { throw Invalid() }
            var d = data.subdata(in: off..<min(data.count, off + size))
            if d.count < size { d.append(Data(count: size - d.count)) }   // a short last sector
            return d
        }
        // The FAT's own sectors: 109 in the header, the rest in the DIFAT chain.
        let fatSectorCount = u32(data, 0x2C)
        guard fatSectorCount <= sectorCount + 1 else { throw Invalid() }
        var fatSectors: [Int] = (0..<109).map { u32(data, 0x4C + $0 * 4) }.filter { $0 < 0xFFFF_FFFA }
        var next = u32(data, 0x44)
        var steps = 0
        while next < 0xFFFF_FFFA, fatSectors.count < fatSectorCount {
            steps += 1
            if steps > sectorCount + 1 { throw Invalid() }
            let s = try sector(next)
            let per = size / 4 - 1
            fatSectors += (0..<per).map { u32(s, $0 * 4) }.filter { $0 < 0xFFFF_FFFA }
            next = u32(s, per * 4)
        }
        // FAT entries are looked up in place: a hostile header can claim a
        // FAT far larger than the chain we walk.
        let perSector = size / 4
        func fat(_ s: Int) throws -> Int {
            let i = s / perSector
            guard i < min(fatSectors.count, fatSectorCount) else { throw Invalid() }
            let off = (fatSectors[i] + 1) * size + (s % perSector) * 4
            guard off + 4 <= data.count else { throw Invalid() }
            return u32(data, off)
        }
        // The directory's chain.
        var directory = Data()
        var s = u32(data, 0x30)
        steps = 0
        while s < 0xFFFF_FFFA {
            steps += 1
            if steps > sectorCount + 1 { throw Invalid() }
            directory.append(try sector(s))
            if directory.count > 16 << 20 { throw Invalid() }   // real ones are a few KB
            s = try fat(s)
        }
        // 128-byte entries; the root's children are a red-black tree of siblings.
        let count = directory.count / 128
        guard count > 0, directory[66] == 5 else { throw Invalid() }
        func name(_ i: Int) -> String {
            let o = i * 128
            let length = min(64, u16(directory, o + 64))
            let units = stride(from: 0, to: max(0, length - 2), by: 2).map { UInt16(u16(directory, o + $0)) }
            return String(decoding: units, as: UTF16.self)
        }
        var names: [String] = []
        var stack = [u32(directory, 76)]
        var seen = Set<Int>()
        while let i = stack.popLast() {
            guard i < count, seen.insert(i).inserted else { continue }
            names.append(name(i))
            stack.append(u32(directory, i * 128 + 68))
            stack.append(u32(directory, i * 128 + 72))
        }
        return names
    }
}
