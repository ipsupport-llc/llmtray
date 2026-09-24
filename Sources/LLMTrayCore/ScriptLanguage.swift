import Foundation

/// Which Wikipedias a query is likely written for, from its script: a
/// Cyrillic, Japanese or Arabic title 404s on en.wiki (or finds a thinner
/// article), so its own language is tried first, English last.
public enum ScriptLanguage {
    public static func wikipediaCandidates(for text: String) -> [String] {
        var langs: [String] = []
        let scalars = text.unicodeScalars.map(\.value)
        func has(_ range: ClosedRange<UInt32>) -> Bool { scalars.contains { range.contains($0) } }
        func hasAny(_ chars: String) -> Bool { text.unicodeScalars.contains { chars.unicodeScalars.contains($0) } }

        if has(0x0400...0x04FF) {
            if hasAny("іїєґІЇЄҐ") { langs += ["uk", "ru"] }
            else if hasAny("ўЎ") { langs += ["be", "ru"] }
            else if hasAny("ёыэъЁЫЭЪ") { langs += ["ru", "uk"] }
            else { langs += ["ru", "uk", "bg", "sr"] }
        }
        if has(0x3040...0x30FF) { langs.append("ja") }                          // kana
        if has(0xAC00...0xD7AF) || has(0x1100...0x11FF) { langs.append("ko") }  // hangul
        if has(0x4E00...0x9FFF) { langs += ["zh", "ja"] }                        // han
        if has(0x0600...0x06FF) { langs.append("ar") }
        if has(0x0590...0x05FF) { langs.append("he") }
        if has(0x0370...0x03FF) { langs.append("el") }
        if has(0x0900...0x097F) { langs.append("hi") }
        if has(0x0E00...0x0E7F) { langs.append("th") }
        langs.append("en")
        var seen = Set<String>()
        return langs.filter { seen.insert($0).inserted }
    }
}
