import Foundation

/// A document's HTML as text, without WebKit: one linear pass over the
/// bytes, nothing that could load a URL. Unlike `WebParsing.text` (made for
/// search-result snippets), it drops script, style, head (but its title),
/// svg and template, and keeps the structure a chunker needs: paragraphs as
/// blank lines, list items as "- ", table rows as "a | b | c", <pre> as is.
/// Entities go through `WebParsing.decodeEntities`.
public enum HTMLText {
    static let blockTags: Set<String> = [
        "p", "div", "br", "li", "ul", "ol", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "header", "footer", "nav", "aside", "main", "blockquote", "pre",
        "hr", "dl", "dt", "dd", "figure", "figcaption", "form", "fieldset", "address", "title",
        "caption", "thead", "tbody", "tfoot", "details", "summary",
    ]
    /// Blocks set off by a blank line rather than a line break.
    static let paragraphTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "table", "blockquote", "pre", "title"]
    /// Skipped with everything inside, up to their closing tag.
    static let skipTags: Set<String> = ["script", "style", "template", "svg", "noscript", "iframe", "object", "math", "head"]
    /// Skipped elements whose content is raw text: a "<script>" inside one is not a tag.
    static let rawText: Set<String> = ["script", "style"]

    public static func text(_ html: String) -> String {
        let b = Array(html.utf8)
        let n = b.count
        var out: [UInt8] = []
        out.reserveCapacity(n / 3)
        var i = 0
        var skipUntil: String?     // inside <script> etc.: its closing tag's name
        var skipDepth = 0          // the same element nested inside it (<template> in <template>)
        var rawUntil: [UInt8]?     // inside <script>/<style>, wherever: "</" + its name ends it
        var inTitle = false        // <title> inside the skipped <head>
        var pre = 0
        var pendingSpace = false
        var cellsInRow = 0
        // Where the current run of text began in `out`: its entities are
        // decoded when a tag (or the end) closes it.
        var runStart = 0
        var runHasEntity = false

        func closeRun() {
            if runHasEntity {
                let decoded = WebParsing.decodeEntities(String(decoding: out[runStart...], as: UTF8.self))
                out.removeSubrange(runStart...)
                out.append(contentsOf: Array(decoded.utf8))
            }
            runHasEntity = false
        }

        func newline(_ count: Int) {
            while out.last == 0x20 { out.removeLast() }
            if out.isEmpty { return }
            var have = 0
            var j = out.count - 1
            while j >= 0, have < count, out[j] == 0x0A { have += 1; j -= 1 }   // only up to `count`: no rescans
            for _ in have..<max(have, count) { out.append(0x0A) }
            pendingSpace = false
        }

        func isNameByte(_ c: UInt8) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
        }

        while i < n {
            let c = b[i]
            if c == 0x3C /* < */ {
                // Script and style are raw text, inside <head> too: only their own
                // closing tag counts there, not a "<!--" or another "<tag".
                if let raw = rawUntil {
                    var k = 0
                    if i + 1 < n, b[i + 1] == 0x2F {
                        while k < raw.count, i + 2 + k < n, (b[i + 2 + k] | 0x20) == raw[k] { k += 1 }
                    }
                    // The whole name, not a prefix: "</scripture>" doesn't end a script.
                    let end = i + 2 + k
                    if k < raw.count || (end < n && isNameByte(b[end])) { i += 1; continue }
                    rawUntil = nil
                }
                // A comment, to its "-->" (or the end).
                if i + 3 < n, b[i + 1] == 0x21, b[i + 2] == 0x2D, b[i + 3] == 0x2D {
                    var j = i + 4
                    while j + 2 < n, !(b[j] == 0x2D && b[j + 1] == 0x2D && b[j + 2] == 0x3E) { j += 1 }
                    i = min(n, j + 3)
                    continue
                }
                var j = i + 1
                let closing = j < n && b[j] == 0x2F
                if closing { j += 1 }
                let nameStart = j
                while j < n, isNameByte(b[j]) { j += 1 }
                if j == nameStart {
                    // "<!DOCTYPE", "<?xml": skipped; a bare "<" is text.
                    if j < n, b[j] == 0x21 || b[j] == 0x3F {
                        while j < n, b[j] != 0x3E { j += 1 }
                        i = j + 1
                        continue
                    }
                    if skipUntil == nil || inTitle {
                        if pendingSpace { out.append(0x20); pendingSpace = false }
                        out.append(c)
                    }
                    i += 1
                    continue
                }
                closeRun()
                let name = String(decoding: b[nameStart..<j].map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }, as: UTF8.self)
                // Past the attributes: a ">" inside quotes doesn't end the tag.
                var quote: UInt8 = 0
                while j < n {
                    let d = b[j]
                    if quote != 0 { if d == quote { quote = 0 } } else if d == 0x22 || d == 0x27 { quote = d } else if d == 0x3E { break }
                    j += 1
                }
                let selfClosed = j > 0 && j < n && b[j - 1] == 0x2F
                i = j + 1
                if !closing && !selfClosed && rawText.contains(name) { rawUntil = Array(name.utf8) }
                if let skip = skipUntil {
                    if name == skip && !rawText.contains(skip) {
                        if !closing && !selfClosed { skipDepth += 1 } else if closing && skipDepth > 0 { skipDepth -= 1; runStart = out.count; continue }
                    }
                    if closing && name == skip && skipDepth == 0 { skipUntil = nil; inTitle = false }
                    if name == "title" && skip == "head" {
                        inTitle = !closing
                        newline(2)
                    }
                    runStart = out.count
                    continue
                }
                if !closing && skipTags.contains(name) {
                    if !selfClosed { skipUntil = name; skipDepth = 0 }   // <svg/> has nothing to skip
                    runStart = out.count
                    continue
                }
                if name == "pre" { pre = max(0, pre + (closing ? -1 : 1)) }
                if name == "td" || name == "th" {
                    if !closing {
                        if cellsInRow > 0 { out.append(contentsOf: Array(" | ".utf8)) }
                        cellsInRow += 1
                        pendingSpace = false
                    }
                } else if name == "li" && !closing {
                    newline(1)
                    out.append(contentsOf: Array("- ".utf8))
                } else if blockTags.contains(name) {
                    if name == "tr" { cellsInRow = 0 }
                    newline(paragraphTags.contains(name) ? 2 : 1)
                }
                runStart = out.count
                continue
            }
            if skipUntil != nil && !inTitle { i += 1; continue }
            if pre == 0 && (c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09) {
                if let last = out.last, last != 0x0A, last != 0x20 { pendingSpace = true }
                i += 1
                continue
            }
            if pendingSpace { out.append(0x20); pendingSpace = false }
            if c == 0x26 /* & */ { runHasEntity = true }
            out.append(c)
            i += 1
        }
        closeRun()
        return String(decoding: out, as: UTF8.self)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
