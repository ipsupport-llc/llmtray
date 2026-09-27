import Foundation

/// The one normalization chunk bodies and queries share (adr/0012): NFC,
/// Unicode's locale-free case mapping, ё → е, soft hyphens and invisible
/// format characters dropped, control characters and whitespace runs made
/// one space. Latin and Cyrillic look-alikes stay distinct (Cyrillic А
/// U+0410 is not Latin A): telling scripts apart is the junk check's job at
/// extraction, not the index's. FTS5's `remove_diacritics 2` folds Latin
/// only -- not ё/е, not й/и -- so ё → е has to happen here.
public enum IndexText {
    public static func normalize(_ s: String) -> String {
        // NFC first, so a decomposed "е\u{0308}" is "ё" before the ё rule.
        // lowercased() is locale-free (no Turkish dotless i) and maps Ё → ё.
        let lower = s.precomposedStringWithCanonicalMapping.lowercased()
        var out = String.UnicodeScalarView()
        out.reserveCapacity(lower.unicodeScalars.count)
        var lastWasSpace = true   // also trims the start
        for u in lower.unicodeScalars {
            switch u.value {
            case 0x0451:   // ё
                out.append("е")
                lastWasSpace = false
            case 0x00AD, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF,     // soft hyphen, zero-width
                 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:   // bidi marks and overrides
                continue
            default:
                if u.properties.isWhitespace || u.properties.generalCategory == .control {
                    if !lastWasSpace { out.append(" ") }
                    lastWasSpace = true
                } else {
                    out.append(u)
                    lastWasSpace = false
                }
            }
        }
        if out.last == " " { out.removeLast() }
        // lowercased() can leave non-NFC sequences (İ → i + U+0307).
        return String(out).precomposedStringWithCanonicalMapping
    }

    /// A rough token count for chunk sizing: XLM-R's tokenizer gives about
    /// one token per 4 characters of Latin text and per ~3 of Cyrillic,
    /// and at least one per word.
    public static func estimatedTokens(_ s: Substring.UnicodeScalarView) -> Int {
        var scalars = 0, words = 0, inWord = false, cyrillic = 0
        for u in s {
            scalars += 1
            if (0x0400...0x04FF).contains(u.value) { cyrillic += 1 }
            let space = u.properties.isWhitespace
            if !space && !inWord { words += 1 }
            inWord = !space
        }
        let latin = scalars - cyrillic
        let byChars = (latin + 3) / 4 + (cyrillic + 2) / 3
        return max(words, byChars)
    }

    public static func estimatedTokens(_ s: String) -> Int {
        estimatedTokens(Substring(s).unicodeScalars)
    }
}

/// FTS5 MATCH expressions for one query, both built from untrusted text.
public struct LexicalQuery: Equatable, Sendable {
    /// Terms for `chunks_fts` (unicode61).
    public var terms: [String]
    /// Terms for `chunks_tri` (trigram): pseudo-stemmed, 3+ characters.
    public var trigramTerms: [String]

    public var words: String? { IndexQuery.expression(terms) }
    public var trigram: String? { IndexQuery.expression(trigramTerms) }
}

/// Builds MATCH expressions so raw text never reaches MATCH (44 of 65
/// hostile strings would have been syntax errors, adr/0012): the query is
/// normalized, split into letter/digit runs, each run double-quoted (so
/// AND/OR/NOT/NEAR, `*`, `^`, `-`, `:`, parentheses and quotes are inert),
/// the runs joined with OR -- at most 24 terms of 64 characters. bm25 and
/// the fusion sort the rest out.
public enum IndexQuery {
    public static let maxTerms = 24
    public static let maxTermLength = 64
    /// Trigram needs three characters; shorter terms go to unicode61 only.
    public static let trigramMinLength = 3

    public static func terms(_ raw: String) -> [String] {
        // Bounded before normalizing: a 100k-character query is 24 terms at most.
        // Cut at a word boundary, so the last term isn't a fragment.
        var head = raw
        if raw.unicodeScalars.count > 8192 {
            var cut = Array(raw.unicodeScalars.prefix(8192))
            while let last = cut.last, last.properties.isAlphabetic || last.properties.numericType != nil { cut.removeLast() }
            head = String(String.UnicodeScalarView(cut))
        }
        let normalized = IndexText.normalize(head)
        var seen = Set<String>(), out: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            guard !current.isEmpty else { return }
            var term = String(current)
            if current.count > maxTermLength { term = String(String.UnicodeScalarView(current.prefix(maxTermLength))) }
            if seen.insert(term).inserted { out.append(term) }
            current = String.UnicodeScalarView()
        }
        for u in normalized.unicodeScalars {
            let p = u.properties
            // unicode61's token characters: letters, numbers (and marks,
            // which remove_diacritics drops).
            let isMark = p.generalCategory == .nonspacingMark || p.generalCategory == .spacingMark || p.generalCategory == .enclosingMark
            if p.isAlphabetic || p.numericType != nil || isMark {
                // A mark never starts a term (it would fuse with the quote).
                if isMark && current.isEmpty { continue }
                current.append(u)
            } else {
                flush()
                if out.count >= maxTerms { break }
            }
        }
        flush()
        return Array(out.prefix(maxTerms))
    }

    static func quote(_ term: String) -> String {
        "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func expression(_ terms: [String]) -> String? {
        terms.isEmpty ? nil : terms.map(quote).joined(separator: " OR ")
    }

    public static func build(_ raw: String) -> LexicalQuery {
        let ts = terms(raw)
        var seen = Set<String>()
        let tri = ts.map(stemForTrigram).filter {
            $0.unicodeScalars.count >= trigramMinLength && seen.insert($0).inserted
        }
        return LexicalQuery(terms: ts, trigramTerms: tri)
    }

    /// Longest first. Crude on purpose: it only has to make a substring
    /// query reach the other case forms ("договоров" → "договор" finds
    /// договора, договору); bm25 and RRF rank the rest.
    static let russianEndings: [String] = [
        "иями", "ями", "ами", "ией", "ого", "его", "ому", "ему", "ыми", "ими",
        "иях", "ях", "ах", "ов", "ев", "ей", "ий", "ый", "ой", "ая", "яя", "ое", "ее",
        "ые", "ие", "ым", "им", "ом", "ем", "ам", "ям", "ую", "юю", "ия", "ию",
        "а", "я", "о", "е", "ы", "и", "у", "ю", "ь", "й",
    ]

    /// A Cyrillic word of 6+ letters loses its inflection ending, keeping a
    /// stem of 5+; anything else is returned as is.
    public static func stemForTrigram(_ term: String) -> String {
        let scalars = Array(term.unicodeScalars)
        guard scalars.count >= 6, scalars.allSatisfy({ (0x0430...0x044F).contains($0.value) }) else { return term }
        for ending in russianEndings where term.hasSuffix(ending) {
            let stemLength = scalars.count - ending.unicodeScalars.count
            if stemLength >= 5 { return String(String.UnicodeScalarView(scalars.prefix(stemLength))) }
        }
        return term
    }
}
