import Foundation

/// Plain text, Markdown and code: decoded, and cut into "pages" of about
/// 1 MB so a large log never becomes one String.
public enum PlainText {
    /// UTF-8; UTF-16 with a BOM; else Windows-1251 (the common Russian legacy
    /// encoding), which maps every byte but one -- then Latin-1.
    public static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16) ?? ""
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        // A UTF-8 sequence cut at the end of a slice isn't a legacy encoding.
        for cut in 1...3 where data.count > cut {
            if let s = String(data: data.dropLast(cut), encoding: .utf8) { return s }
        }
        let cp1251 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)))
        return String(data: data, encoding: cp1251) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Pages of about `pageBytes`, cut after a newline where one is near and
    /// never inside a UTF-8 sequence. Throws `tooLarge(.text)` past
    /// `maxTextBytes` of decoded text, or `.pages` past `maxPages`.
    public static func pages(_ data: Data, caps: ExtractionCaps, pageBytes: Int = 1 << 20) throws -> [String] {
        let data = data.startIndex == 0 ? data : Data(data)
        // UTF-16 can't be cut by bytes safely without decoding; it is rare
        // and bounded by the file cap, so it is decoded whole.
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            let text = decode(data)
            if text.utf8.count > caps.maxTextBytes { throw ExtractionError.tooLarge(.text) }
            return [text]
        }
        var pages: [String] = []
        var total = 0
        var start = 0
        while start < data.count {
            var end = min(data.count, start + pageBytes)
            if end < data.count {
                // Back to the last newline in the slice's last quarter...
                if let nl = data[(start + pageBytes * 3 / 4)..<end].lastIndex(of: 0x0A) {
                    end = nl + 1
                } else {
                    // ...else off any UTF-8 continuation bytes.
                    while end > start + 1, data[end] & 0xC0 == 0x80 { end -= 1 }
                }
            }
            let text = decode(data[start..<end])
            total += text.utf8.count
            if total > caps.maxTextBytes { throw ExtractionError.tooLarge(.text) }
            pages.append(text)
            if pages.count > caps.maxPages { throw ExtractionError.tooLarge(.pages) }
            start = end
        }
        return pages
    }
}
