import Foundation

public enum Kind: String {
    case pdf, docx, xlsx, pptx, odt, doc, xls, ppt, rtf, html, text
    case image
    case encryptedOOXML = "encrypted-ooxml"
    case unknownZip = "zip"
    case unknownCFB = "cfb"
    case unknown
}

/// Type from content, never from the extension. Containers (zip, CFB) are
/// told apart by their members, which is also what makes a docx-named
/// xlsx or an xls-named doc come out right.
public enum Detect {
    public static func kind(of data: Data, limits: Limits = Limits()) -> Kind {
        let head = [UInt8](data.prefix(1024))
        func starts(_ s: [UInt8], at o: Int = 0) -> Bool {
            head.count >= o + s.count && Array(head[o..<(o + s.count)]) == s
        }
        // PDF: "%PDF-" may be preceded by junk; readers accept it within 1 KB.
        if let r = data.prefix(1024).range(of: Data("%PDF-".utf8)), r.lowerBound - data.startIndex < 1024 { return .pdf }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) {
            guard let zip = try? ZipArchive(data: data, limits: limits) else { return .unknownZip }
            if zip.has("word/document.xml") { return .docx }
            if zip.has("xl/workbook.xml") { return .xlsx }
            if zip.has("ppt/presentation.xml") { return .pptx }
            if zip.has("mimetype"), let m = try? zip.read("mimetype"),
               String(decoding: m, as: UTF8.self).hasPrefix("application/vnd.oasis.opendocument.text") { return .odt }
            // Parts named by [Content_Types].xml only (a renamed main part).
            if let ct = try? zip.read("[Content_Types].xml") {
                let s = String(decoding: ct, as: UTF8.self)
                if s.contains("wordprocessingml.document.main") { return .docx }
                if s.contains("spreadsheetml.sheet.main") { return .xlsx }
                if s.contains("presentationml.presentation.main") { return .pptx }
            }
            return .unknownZip
        }
        if starts(CFB.magic) {
            guard let cfb = try? CFB(data: data) else { return .unknownCFB }
            let names = Set(cfb.topLevelNames().map { $0.lowercased() })
            if names.contains("encryptedpackage") { return .encryptedOOXML }
            if names.contains("worddocument") { return .doc }
            if names.contains("workbook") || names.contains("book") { return .xls }
            if names.contains("powerpoint document") { return .ppt }
            return .unknownCFB
        }
        if starts(Array("{\\rtf".utf8)) { return .rtf }
        if starts([0x89, 0x50, 0x4E, 0x47]) || starts([0xFF, 0xD8, 0xFF]) || starts(Array("GIF8".utf8))
            || starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A])
            || (starts(Array("ftyp".utf8), at: 4) && head.count >= 12
                && ["heic", "heix", "mif1", "avif"].contains(String(decoding: head[8..<12], as: UTF8.self))) {
            return .image
        }
        // Text-like: UTF-8 (or a UTF-16 BOM) with no NULs in the first 64 KB.
        let probe = data.prefix(64 * 1024)
        let utf16 = starts([0xFF, 0xFE]) || starts([0xFE, 0xFF])
        if !utf16 && probe.contains(0) { return .unknown }
        let text: String
        if utf16 {
            text = String(data: probe, encoding: .utf16) ?? ""
        } else {
            // A cut in the middle of a multi-byte sequence at the probe edge is fine.
            var p = probe
            while !p.isEmpty, String(data: p, encoding: .utf8) == nil, probe.count - p.count < 4 { p = p.dropLast() }
            guard let t = String(data: p, encoding: .utf8) else { return .text } // 8-bit legacy text; decoded later
            text = t
        }
        let lead = text.prefix(1024).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stripped = lead.hasPrefix("\u{feff}") ? String(lead.dropFirst()) : lead
        if stripped.hasPrefix("<!doctype html") || stripped.hasPrefix("<html")
            || (stripped.hasPrefix("<") && (lead.contains("<html") || lead.contains("<body") || lead.contains("<head"))) {
            return .html
        }
        return .text
    }
}
