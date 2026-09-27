import Foundation

/// The junk check: is this text layer worth indexing, or should the page go
/// to the next tier (OCR)? A score in 0...1 -- the max of several signals, so
/// the reason is inspectable; >= `threshold` is junk. An empty page is 1.
public enum Junk {
    public static let threshold = 0.5

    public struct Signals: CustomStringConvertible {
        public var glyphs = 0
        public var replacement = 0.0   // U+FFFD share
        public var control = 0.0       // C0 (bar tab/newline) / C1 / NUL share
        public var privateUse = 0.0    // PUA share: unmapped glyph ids
        public var mixedWords = 0.0    // words mixing Cyrillic with Latin/Greek/Latin-Ext (U+0138 for к)
        public var mojibake = 0.0      // Latin-1 letters among letters: cp1251 read as Latin-1
        public var alnum = 1.0         // letters+digits per glyph
        public var score = 0.0
        public var description: String {
            String(format: "n=%d fffd=%.3f ctl=%.3f pua=%.3f mixed=%.3f moji=%.3f alnum=%.2f -> %.2f",
                   glyphs, replacement, control, privateUse, mixedWords, mojibake, alnum, score)
        }
    }

    public static func score(_ text: String) -> Double { signals(text).score }

    enum Script { case cyrillic, latin, latinExt, greek, other }

    static func script(_ v: UInt32) -> Script {
        switch v {
        case 0x0400...0x052F: return .cyrillic
        case 0x41...0x5A, 0x61...0x7A: return .latin
        // Latin-1 letters, Latin Extended-A/B: legit in Western text, but in a
        // Cyrillic word they are a broken ToUnicode (U+0138 "ĸ" for "к").
        case 0xC0...0x24F: return .latinExt
        case 0x0370...0x03FF: return .greek
        default: return .other
        }
    }

    public static func signals(_ text: String) -> Signals {
        var s = Signals()
        var n = 0, fffd = 0, ctl = 0, pua = 0, alnum = 0, letters = 0, latin1Letters = 0
        var words = 0, mixed = 0
        var wordScripts = Set<Int>()
        var wordLen = 0
        func endWord() {
            if wordLen >= 2 {
                words += 1
                if wordScripts.contains(0) && wordScripts.count > 1 { mixed += 1 }
            }
            wordScripts.removeAll(keepingCapacity: true)
            wordLen = 0
        }
        for u in text.unicodeScalars {
            let v = u.value
            if u.properties.isWhitespace { endWord(); continue }
            n += 1
            if v == 0xFFFD { fffd += 1 }
            if (v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D && v != 0x0C) || (0x7F...0x9F).contains(v) { ctl += 1 }
            if (0xE000...0xF8FF).contains(v) || v >= 0xF0000 { pua += 1 }
            let isLetter = u.properties.isAlphabetic
            if isLetter || u.properties.numericType != nil { alnum += 1 }
            if isLetter {
                letters += 1
                if (0xC0...0xFF).contains(v) && v != 0xD7 && v != 0xF7 { latin1Letters += 1 }
                let sc = script(v)
                switch sc {
                case .cyrillic: wordScripts.insert(0)
                case .latin: wordScripts.insert(1)
                case .latinExt: wordScripts.insert(2)
                case .greek: wordScripts.insert(3)
                case .other: break
                }
                wordLen += 1
            } else {
                endWord()
            }
        }
        endWord()
        s.glyphs = n
        guard n > 0 else { s.score = 1; return s }
        let dn = Double(n)
        s.replacement = Double(fffd) / dn
        s.control = Double(ctl) / dn
        s.privateUse = Double(pua) / dn
        s.mixedWords = words > 0 ? Double(mixed) / Double(words) : 0
        s.mojibake = letters > 0 ? Double(latin1Letters) / Double(letters) : 0
        s.alnum = Double(alnum) / dn
        func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
        let parts = [
            clamp(s.replacement * 20),              // 2.5% U+FFFD -> 0.5
            clamp(s.control * 20),
            clamp(s.privateUse * 10),               // 5% PUA -> 0.5
            clamp(s.mixedWords * 5),                // 10% of words mixed -> 0.5
            clamp((s.mojibake - 0.25) / 0.3),       // fr/de/pt/cs/is/sv measured 0.06-0.20; cp1251-as-Latin-1 ~1.0
            clamp((0.75 - s.alnum) / 0.5),          // symbol soup; number tables stay > 0.6
        ]
        // Very short pages carry little evidence; don't let one stray glyph decide.
        let weight = n < 20 ? Double(n) / 20 : 1
        s.score = (parts.max() ?? 0) * weight
        return s
    }
}
