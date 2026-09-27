import Foundation

/// Text normalization applied identically to chunk bodies and to queries.
/// NFC, case folding (Unicode default, locale-independent), ё→е, invisible
/// format characters dropped, whitespace runs collapsed. Latin and Cyrillic
/// look-alikes are NOT folded together (Cyrillic А U+0410 stays distinct from
/// Latin A U+0041): mapping between scripts is the junk check's job at
/// extraction, not the index's.
public enum Normalizer {
    public static func normalize(_ s: String) -> String {
        // 1. NFC first so a decomposed "е\u{0308}" becomes "ё" before the ё rule.
        let nfc = s.precomposedStringWithCanonicalMapping
        // 2. Case folding. `lowercased()` is Unicode's default, locale-free mapping
        //    (no Turkish dotless-i surprises); it maps Ё→ё, so step 3 covers both.
        let lower = nfc.lowercased()
        var out = String.UnicodeScalarView()
        out.reserveCapacity(lower.unicodeScalars.count)
        var lastWasSpace = false
        for u in lower.unicodeScalars {
            switch u.value {
            case 0x0451: out.append("е"); lastWasSpace = false          // ё → е
            case 0x00AD, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF:          // soft hyphen, zero-width
                continue
            default:
                if u.properties.isWhitespace {
                    if !lastWasSpace { out.append(" ") }
                    lastWasSpace = true
                } else {
                    out.append(u); lastWasSpace = false
                }
            }
        }
        // 3. lowercased() can produce non-NFC sequences (e.g. İ → i + U+0307); re-compose.
        return String(out).precomposedStringWithCanonicalMapping
    }
}

/// Builds FTS5 MATCH expressions from untrusted user/model text. Raw text never
/// reaches MATCH: the query is normalized, split into letter/digit runs, and each
/// run becomes a double-quoted FTS5 string (so AND/OR/NOT/NEAR, *, ^, -, :, ( )
/// and quotes are inert). Terms are OR-ed: ranking (bm25) and RRF sort it out.
public struct LexicalQuery: Equatable {
    /// Terms for chunks_fts (unicode61).
    public var terms: [String]
    /// Terms for chunks_tri (trigram): pseudo-stemmed, ≥3 characters only.
    public var triTerms: [String]
    /// MATCH expression for chunks_fts, nil if no terms.
    public var words: String? { QueryBuilder.expression(terms) }
    /// MATCH expression for chunks_tri, nil if no term has ≥3 characters.
    public var trigram: String? { QueryBuilder.expression(triTerms) }
}

public enum QueryBuilder {
    public static let maxTerms = 24
    public static let maxTermLength = 64

    public static func terms(_ raw: String) -> [String] {
        let n = Normalizer.normalize(raw)
        var seen = Set<String>(), out: [String] = []
        var cur = String.UnicodeScalarView()
        func flush() {
            if !cur.isEmpty {
                var t = String(cur)
                if t.unicodeScalars.count > maxTermLength { t = String(String.UnicodeScalarView(t.unicodeScalars.prefix(maxTermLength))) }
                if seen.insert(t).inserted { out.append(t) }
                cur = String.UnicodeScalarView()
            }
        }
        for u in n.unicodeScalars {
            let p = u.properties
            // Letters, numbers and combining marks form terms (unicode61's notion
            // of a token char is L*, N*, Co; marks are removed by remove_diacritics).
            let isMark = p.generalCategory == .nonspacingMark || p.generalCategory == .spacingMark || p.generalCategory == .enclosingMark
            if p.isAlphabetic || p.numericType != nil || isMark {
                // a mark never starts a term (it would fuse with the opening quote
                // into one grapheme; harmless to SQLite, but confusing)
                if isMark && cur.isEmpty { continue }
                cur.append(u)
            } else {
                flush()
            }
        }
        flush()
        return Array(out.prefix(maxTerms))
    }

    static func quote(_ t: String) -> String {
        "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func expression(_ ts: [String]) -> String? {
        ts.isEmpty ? nil : ts.map(quote).joined(separator: " OR ")
    }

    public static func build(_ raw: String) -> LexicalQuery {
        let ts = terms(raw)
        // Trigram gets pseudo-stems: "договоров" → "договор" so the substring
        // match also finds other case forms. Deduped after stemming.
        var triSeen = Set<String>()
        let tri = ts.map(stemForTrigram).filter { $0.unicodeScalars.count >= 3 && triSeen.insert($0).inserted }
        return LexicalQuery(terms: ts, triTerms: tri)
    }

    /// Longest-first Russian inflection endings. Crude on purpose: it only has to
    /// make a substring query hit the other forms; bm25 + RRF rank the rest.
    static let ruEndings: [String] = [
        "иями", "ями", "ами", "ией", "ого", "его", "ому", "ему", "ыми", "ими",
        "иях", "ях", "ах", "ов", "ев", "ей", "ий", "ый", "ой", "ая", "яя", "ое", "ее",
        "ые", "ие", "ым", "им", "ом", "ем", "ам", "ям", "ую", "юю", "ия", "ие", "ию",
        "а", "я", "о", "е", "ы", "и", "у", "ю", "ь", "й",
    ]

    public static func stemForTrigram(_ t: String) -> String {
        let scalars = Array(t.unicodeScalars)
        guard scalars.count >= 6,
              scalars.allSatisfy({ (0x0430...0x044F).contains($0.value) }) else { return t }
        for e in ruEndings where t.hasSuffix(e) {
            let stemLen = scalars.count - e.unicodeScalars.count
            if stemLen >= 5 { return String(String.UnicodeScalarView(scalars.prefix(stemLen))) }
        }
        return t
    }
}
