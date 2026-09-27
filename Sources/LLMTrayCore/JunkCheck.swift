import Foundation

/// Is a text layer worth indexing, or should the page go to the next tier
/// (OCR)? Applied only where a next tier exists -- PDF pages (and images,
/// later). A score in 0...1, the max of six signals so the reason can be
/// read off; `threshold` and above is junk. Clean text in ~10 languages,
/// number tables and code scored at most 0.17 (Icelandic) in the spike;
/// broken ToUnicode maps and cp1251 read as Latin-1 score near 1.
public enum JunkCheck {
    public static let threshold = 0.5

    public struct Signals: Equatable {
        public var glyphs = 0
        /// U+FFFD among glyphs.
        public var replacement = 0.0
        /// C0 (but tab and line breaks), DEL and C1 among glyphs.
        public var control = 0.0
        /// Private use: glyphs a font never mapped.
        public var privateUse = 0.0
        /// Words mixing Cyrillic with Latin, Latin-Extended or Greek (U+0138 "ĸ" for "к").
        public var mixedWords = 0.0
        /// Latin-1 letters among letters: "Äîãîâîð" is cp1251 read as Latin-1.
        public var mojibake = 0.0
        /// Letters and digits per glyph; low is symbol soup.
        public var alphanumeric = 1.0
        public var score = 0.0
    }

    public static func score(_ text: String) -> Double { signals(text).score }

    public static func isJunk(_ text: String) -> Bool { score(text) >= threshold }

    private enum Script { case cyrillic, latin, latinExtended, greek, other }

    private static func script(_ v: UInt32) -> Script {
        switch v {
        case 0x0400...0x052F: return .cyrillic
        case 0x41...0x5A, 0x61...0x7A: return .latin
        // Latin-1 letters and Latin Extended-A/B: fine in Western text, a
        // broken font in a Cyrillic word.
        case 0xC0...0x24F: return .latinExtended
        case 0x0370...0x03FF: return .greek
        default: return .other
        }
    }

    public static func signals(_ text: String) -> Signals {
        var s = Signals()
        var n = 0, fffd = 0, control = 0, pua = 0, alnum = 0, letters = 0, latin1 = 0
        var words = 0, mixed = 0
        var wordHasCyrillic = false, wordHasOther = false
        var wordLength = 0
        func endWord() {
            if wordLength >= 2 {
                words += 1
                if wordHasCyrillic && wordHasOther { mixed += 1 }
            }
            wordHasCyrillic = false
            wordHasOther = false
            wordLength = 0
        }
        for u in text.unicodeScalars {
            if u.properties.isWhitespace { endWord(); continue }
            let v = u.value
            n += 1
            if v == 0xFFFD { fffd += 1 }
            if (v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D && v != 0x0C) || (0x7F...0x9F).contains(v) { control += 1 }
            if (0xE000...0xF8FF).contains(v) || v >= 0xF0000 { pua += 1 }
            let isLetter = u.properties.isAlphabetic
            if isLetter || u.properties.numericType != nil { alnum += 1 }
            guard isLetter else { endWord(); continue }
            letters += 1
            if (0xC0...0xFF).contains(v) && v != 0xD7 && v != 0xF7 { latin1 += 1 }
            switch script(v) {
            case .cyrillic: wordHasCyrillic = true
            case .latin, .latinExtended, .greek: wordHasOther = true
            case .other: break
            }
            wordLength += 1
        }
        endWord()
        s.glyphs = n
        guard n > 0 else { s.score = 1; return s }
        let count = Double(n)
        s.replacement = Double(fffd) / count
        s.control = Double(control) / count
        s.privateUse = Double(pua) / count
        s.mixedWords = words > 0 ? Double(mixed) / Double(words) : 0
        s.mojibake = letters > 0 ? Double(latin1) / Double(letters) : 0
        s.alphanumeric = Double(alnum) / count
        func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
        let parts = [
            clamp(s.replacement * 20),              // 2.5% U+FFFD -> 0.5
            clamp(s.control * 20),
            clamp(s.privateUse * 10),               // 5% private use -> 0.5
            clamp(s.mixedWords * 5),                // 10% of words mixed -> 0.5
            clamp((s.mojibake - 0.25) / 0.3),       // fr/de/pt/cs/is/sv 0.06-0.20; cp1251-as-Latin-1 ~1
            clamp((0.75 - s.alphanumeric) / 0.5),   // symbol soup; number tables stay above 0.6
        ]
        // A very short page is little evidence: one stray glyph doesn't decide.
        let weight = n < 20 ? count / 20 : 1
        s.score = (parts.max() ?? 0) * weight
        return s
    }
}
