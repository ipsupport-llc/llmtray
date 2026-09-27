import Foundation

/// HTML to text without WebKit: a single linear pass over the bytes. Never
/// fetches anything -- there is nothing here that could (no URL loading, no
/// WebView), which is the point. Keeps block structure (paragraphs, list
/// items, table rows as "a | b | c"), drops script/style/template/svg/head
/// (except <title>), decodes entities.
public enum HTMLText {
    static let blockTags: Set<String> = [
        "p", "div", "br", "li", "ul", "ol", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "header", "footer", "nav", "aside", "main", "blockquote", "pre",
        "hr", "dl", "dt", "dd", "figure", "figcaption", "form", "fieldset", "address", "title",
        "caption", "thead", "tbody", "tfoot", "details", "summary",
    ]
    static let skipTags: Set<String> = ["script", "style", "template", "svg", "noscript", "iframe", "object", "math", "head"]

    public static func text(_ html: String) -> String {
        let b = Array(html.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(b.count / 3)
        var i = 0
        let n = b.count
        var skipUntil: String? = nil      // inside <script> etc.: wait for its close tag
        var inTitle = false
        var pre = 0
        var pendingSpace = false
        var cellsInRow = 0

        func newline(_ count: Int = 1) {
            while let last = out.last, last == 0x20 { out.removeLast() }
            var have = 0
            var j = out.count - 1
            while j >= 0, out[j] == 0x0A { have += 1; j -= 1 }
            if out.isEmpty { return }
            for _ in have..<max(have, count) { out.append(0x0A) }
            pendingSpace = false
        }

        func lower(_ s: ArraySlice<UInt8>) -> String {
            String(decoding: s.map { ($0 >= 0x41 && $0 <= 0x5A) ? $0 + 32 : $0 }, as: UTF8.self)
        }

        while i < n {
            let c = b[i]
            if c == 0x3C /* < */ {
                // Comment
                if i + 3 < n, b[i + 1] == 0x21, b[i + 2] == 0x2D, b[i + 3] == 0x2D {
                    var j = i + 4
                    while j + 2 < n, !(b[j] == 0x2D && b[j + 1] == 0x2D && b[j + 2] == 0x3E) { j += 1 }
                    i = min(n, j + 3)
                    continue
                }
                // Tag name
                var j = i + 1
                let closing = j < n && b[j] == 0x2F
                if closing { j += 1 }
                let nameStart = j
                while j < n, (b[j] >= 0x41 && b[j] <= 0x5A) || (b[j] >= 0x61 && b[j] <= 0x7A) || (b[j] >= 0x30 && b[j] <= 0x39) { j += 1 }
                if j == nameStart {
                    // "<!DOCTYPE", "<?xml", or a bare "<" in text.
                    if j < n, b[j] == 0x21 || b[j] == 0x3F {
                        while j < n, b[j] != 0x3E { j += 1 }
                        i = j + 1
                        continue
                    }
                    if skipUntil == nil { out.append(c) }
                    i += 1
                    continue
                }
                let name = lower(b[nameStart..<j])
                // Skip attributes, honouring quotes (a ">" inside one doesn't end the tag).
                var quote: UInt8 = 0
                while j < n {
                    let d = b[j]
                    if quote != 0 { if d == quote { quote = 0 } } else if d == 0x22 || d == 0x27 { quote = d } else if d == 0x3E { break }
                    j += 1
                }
                i = j + 1
                if let skip = skipUntil {
                    if closing && name == skip { skipUntil = nil }
                    if name == "title" && skip == "head" { inTitle = !closing; if closing { newline(2) } }
                    continue
                }
                if !closing && skipTags.contains(name) {
                    // A self-closed <svg/> or <script .../> has nothing to skip.
                    if j > 0, j - 1 < n, b[j - 1] == 0x2F { continue }
                    skipUntil = name
                    continue
                }
                if name == "pre" { pre += closing ? -1 : 1 }
                if name == "td" || name == "th" {
                    if !closing { if cellsInRow > 0 { out.append(contentsOf: Array(" | ".utf8)) }; cellsInRow += 1; pendingSpace = false }
                    continue
                }
                if name == "tr" { cellsInRow = 0 }
                if name == "li" && !closing { newline(); out.append(contentsOf: Array("- ".utf8)); continue }
                if blockTags.contains(name) {
                    let para = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "table", "blockquote", "pre", "title"].contains(name)
                    newline(para ? 2 : 1)
                }
                continue
            }
            if skipUntil != nil && !inTitle { i += 1; continue }
            if c == 0x26 /* & */ {
                var j = i + 1
                while j < n, j - i < 34, b[j] != 0x3B, b[j] != 0x3C, b[j] != 0x20, b[j] != 0x26 { j += 1 }
                if j < n, b[j] == 0x3B, let decoded = entity(String(decoding: b[(i + 1)..<j], as: UTF8.self)) {
                    if pendingSpace { out.append(0x20); pendingSpace = false }
                    out.append(contentsOf: Array(decoded.utf8))
                    i = j + 1
                    continue
                }
            }
            if pre == 0 && (c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09) {
                if let last = out.last, last != 0x0A, last != 0x20 { pendingSpace = true }
                i += 1
                continue
            }
            if pendingSpace { out.append(0x20); pendingSpace = false }
            out.append(c)
            i += 1
        }
        let s = String(decoding: out, as: UTF8.self)
        return s.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»", "hellip": "…", "copy": "©",
        "reg": "®", "trade": "™", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "bdquo": "„", "bull": "•", "middot": "·", "times": "×", "divide": "÷", "euro": "€",
        "deg": "°", "plusmn": "±", "sect": "§", "para": "¶", "shy": "", "thinsp": " ", "ensp": " ",
        "emsp": " ", "zwnj": "", "zwj": "", "minus": "−", "larr": "←", "rarr": "→", "le": "≤",
        "ge": "≥", "ne": "≠", "infin": "∞", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "numero": "№", "cent": "¢", "pound": "£", "yen": "¥", "iexcl": "¡", "iquest": "¿",
    ]

    static func entity(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let hex = name.hasPrefix("#x") || name.hasPrefix("#X")
            guard let code = UInt32(name.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                  let scalar = Unicode.Scalar(code), code != 0 else { return nil }
            return String(Character(scalar))
        }
        return named[name] ?? named[name.lowercased()]
    }
}
