import Foundation

/// The model's Markdown as the page `make_document` prints (adr/0020): our
/// own converter, so nothing in the content becomes markup. Every character
/// of the content is escaped; the only tags are the ones built here
/// (`allowedTags`), the only attributes `class` (our own names), `href` on
/// `a` (http, https, mailto) and on the stylesheet's `link`, `src`/`alt` on
/// a chart's or picture's `img` (an `llmtray-doc:` address we resolved).
public enum DocumentHTML {
    /// What the converter can emit, and nothing else (a test checks).
    public static let allowedTags: Set<String> = Set([
        "html", "head", "meta", "title", "link", "body",
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li",
        "table", "thead", "tbody", "tr", "th", "td", "pre", "code", "blockquote",
        "a", "strong", "em", "del", "hr", "br", "sup", "span", "img", "nav", "section",
    ]).union(DocumentMath.tags)

    /// A picture or chart named in the content, and where it went.
    public enum ImageRef: Equatable, Sendable {
        case chart(String)
        case picture(String)
    }

    public struct Body: Sendable {
        public var html: String
        /// The charts and pictures the content placed, in order.
        public var placed: [ImageRef]
        /// The headings, for a table of contents: level and plain text.
        public var headings: [(level: Int, text: String)]
        /// The page grew past `maxBodyBytes` and was cut there: the
        /// document isn't made (adr/0020, Hardening 3).
        public var tooLarge: Bool
    }

    /// The body's size at most: 200,000 scalars of Markdown are at most a
    /// few megabytes of HTML, whatever their shape.
    public static let maxBodyBytes = 8 * 1024 * 1024

    /// `resolve` gives the `llmtray-doc:` address of a chart or picture the
    /// document has, nil for one it doesn't (it then reads as its alt text).
    public static func body(markdown: String, resolve: @escaping (ImageRef) -> String?) -> Body {
        var converter = Converter(resolve: resolve)
        let html = converter.blocks(lines(markdown))
        return Body(html: html, placed: converter.placed, headings: converter.headings, tooLarge: converter.tooLarge)
    }

    /// The whole page: our stylesheet, then the body, a table of contents
    /// when `toc` has entries -- after the title when the body opens with
    /// one, else first.
    public static func page(title: String, style: String, body: String, toc: [(level: Int, text: String)] = []) -> String {
        var out = "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(escape(title))</title>"
        out += "<link rel=\"stylesheet\" href=\"llmtray-doc://style/\(styleName(style)).css\"></head><body>"
        guard !toc.isEmpty else { return out + body + "</body></html>" }
        var nav = "<nav class=\"toc\"><ul>"
        for entry in toc { nav += "<li class=\"toc\(entry.level)\">\(escape(entry.text))</li>" }
        nav += "</ul></nav>"
        if body.hasPrefix("<h1>"), let end = body.range(of: "</h1>") {
            return out + body[..<end.upperBound] + nav + body[end.upperBound...] + "</body></html>"
        }
        return out + nav + body + "</body></html>"
    }

    /// A chart or picture the content never placed, at the end.
    public static func figure(src: String, caption: String) -> String {
        "<p class=\"figure\"><img src=\"\(escape(src))\" alt=\"\(escape(caption))\"></p>"
            + (caption.isEmpty ? "" : "<p class=\"caption\">\(escape(caption))</p>")
    }

    /// The styles there are; anything else is the report.
    public static let styles = ["report", "letter", "notes", "invoice"]

    public static func styleName(_ style: String) -> String { styles.contains(style) ? style : "report" }

    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default:
                // Control characters (but tab) never reach the page.
                if ch.value < 0x20 && ch != "\t" && ch != "\n" { continue }
                if ch.value == 0x7F { continue }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    /// A link's target if it may be one: http, https or mailto, nothing
    /// else (javascript:, file:, data:, relative paths).
    static func safeLink(_ raw: String) -> String? {
        let url = raw.trimmingCharacters(in: .whitespaces)
        guard !url.contains(where: { $0.isWhitespace || $0.unicodeScalars.contains { $0.value < 0x20 } }) else { return nil }
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") else { return nil }
        guard URL(string: url) != nil else { return nil }
        return url
    }

    static func lines(_ markdown: String) -> [String] {
        markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    // MARK: - Blocks

    struct Converter {
        let resolve: (ImageRef) -> String?
        var placed: [ImageRef] = []
        var headings: [(level: Int, text: String)] = []
        /// Nesting of quotes and lists: a hostile input can't recurse deep.
        var depth = 0
        var inlineDepth = 0
        /// Table cells left for the whole document: one table's padding
        /// can't be repeated a hundred times either.
        var cellsLeft = maxCells
        /// The body passed `maxBodyBytes`: the rest is dropped.
        var tooLarge = false

        init(resolve: @escaping (ImageRef) -> String?) { self.resolve = resolve }

        mutating func blocks(_ lines: [String]) -> String {
            depth += 1
            defer { depth -= 1 }
            if depth > 8 { return "<p>\(inline(lines.joined(separator: " ")))</p>" }
            var out = ""
            var i = 0
            var paragraph: [String] = []
            func flush(_ out: inout String, _ converter: inout Converter) {
                guard !paragraph.isEmpty else { return }
                out += converter.paragraphHTML(paragraph)
                paragraph = []
            }
            while i < lines.count {
                if depth == 1, out.utf8.count > DocumentHTML.maxBodyBytes { tooLarge = true; break }
                let line = lines[i]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { flush(&out, &self); i += 1; continue }
                // Fenced code.
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    flush(&out, &self)
                    let fence = String(trimmed.prefix(3))
                    var code: [String] = []
                    i += 1
                    while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        code.append(lines[i])
                        i += 1
                    }
                    i += 1
                    out += "<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>"
                    continue
                }
                // Display math on lines of its own: $$ … $$ or \[ … \].
                if let (math, next) = Self.displayMath(lines, from: i) {
                    flush(&out, &self)
                    out += math
                    i = next
                    continue
                }
                // Heading.
                if let (level, text) = Self.heading(trimmed) {
                    flush(&out, &self)
                    let plain = Self.plain(text)
                    headings.append((level, plain))
                    out += "<h\(level)>\(inline(text))</h\(level)>"
                    i += 1
                    continue
                }
                // Rule.
                if Self.isRule(trimmed) {
                    flush(&out, &self)
                    out += "<hr>"
                    i += 1
                    continue
                }
                // Quote.
                if trimmed.hasPrefix(">") {
                    flush(&out, &self)
                    var inner: [String] = []
                    while i < lines.count {
                        let t = lines[i].trimmingCharacters(in: .whitespaces)
                        guard t.hasPrefix(">") else { break }
                        var rest = t.dropFirst()
                        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                        inner.append(String(rest))
                        i += 1
                    }
                    out += "<blockquote>\(blocks(inner))</blockquote>"
                    continue
                }
                // Table: a row and a separator under it.
                // As GitHub's: the separator has as many cells as the header;
                // at most `maxColumns` of them, and `maxCells` in the table.
                if trimmed.hasPrefix("|"), i + 1 < lines.count,
                   let aligns = Self.tableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)),
                   aligns.count == Self.cells(trimmed).count, aligns.count <= Self.maxColumns,
                   aligns.count * 2 <= cellsLeft {
                    flush(&out, &self)
                    let header = Self.cells(trimmed)
                    var rows: [[String]] = []
                    i += 2
                    while i < lines.count {
                        let t = lines[i].trimmingCharacters(in: .whitespaces)
                        guard t.hasPrefix("|") else { break }
                        // Past the document's cells, the rows are text.
                        guard (rows.count + 2) * header.count <= cellsLeft else { break }
                        rows.append(Self.cells(t))
                        i += 1
                    }
                    cellsLeft -= (rows.count + 1) * header.count
                    out += table(header: header, aligns: aligns, rows: rows)
                    continue
                }
                // List.
                if let first = Self.listMarker(line) {
                    flush(&out, &self)
                    let base = Self.indent(line)
                    var block: [String] = []
                    while i < lines.count {
                        let l = lines[i]
                        let t = l.trimmingCharacters(in: .whitespaces)
                        if t.isEmpty {
                            // A blank line ends the list unless an item or an
                            // indented line follows.
                            if i + 1 < lines.count, Self.listMarker(lines[i + 1]) != nil || Self.indent(lines[i + 1]) >= 2 {
                                i += 1
                                continue
                            }
                            break
                        }
                        guard Self.listMarker(l) != nil || Self.indent(l) >= 2 else { break }
                        // A bullet list after a numbered one (or the other
                        // way round) at the same depth is a list of its own.
                        if !block.isEmpty, Self.indent(l) <= base, let m = Self.listMarker(l), m.ordered != first.ordered { break }
                        block.append(l)
                        i += 1
                    }
                    out += list(block)
                    continue
                }
                // A picture or chart on a line of its own: a figure.
                if let figure = figureLine(trimmed) {
                    flush(&out, &self)
                    out += figure
                    i += 1
                    continue
                }
                paragraph.append(line)
                i += 1
            }
            flush(&out, &self)
            return out
        }

        mutating func paragraphHTML(_ lines: [String]) -> String {
            var parts: [String] = []
            for (n, line) in lines.enumerated() {
                var l = line.trimmingCharacters(in: .whitespaces)
                let hardBreak = line.hasSuffix("  ") || l.hasSuffix("\\")
                if l.hasSuffix("\\") { l.removeLast() }
                parts.append(inline(l) + (hardBreak && n < lines.count - 1 ? "<br>" : ""))
            }
            return "<p>\(parts.joined(separator: " "))</p>"
        }

        mutating func table(header: [String], aligns: [String?], rows: [[String]]) -> String {
            func cell(_ tag: String, _ text: String, _ column: Int) -> String {
                let align = column < aligns.count ? aligns[column] : nil
                let cls = align.map { " class=\"\($0)\"" } ?? ""
                return "<\(tag)\(cls)>\(inline(text))</\(tag)>"
            }
            var out = "<table><thead><tr>"
            for (c, h) in header.enumerated() { out += cell("th", h, c) }
            out += "</tr></thead><tbody>"
            for row in rows {
                out += "<tr>"
                for c in 0..<header.count { out += cell("td", c < row.count ? row[c] : "", c) }
                out += "</tr>"
            }
            return out + "</tbody></table>"
        }

        mutating func list(_ lines: [String]) -> String {
            // Items at the first line's indent; deeper lines belong to the
            // item above (a nested list or a continuation).
            let base = Self.indent(lines[0])
            let ordered = Self.listMarker(lines[0])?.ordered ?? false
            var items: [[String]] = []
            for line in lines {
                if Self.indent(line) <= base, let marker = Self.listMarker(line) {
                    items.append([marker.text])
                } else if !items.isEmpty {
                    items[items.count - 1].append(String(line.dropFirst(min(Self.indent(line), base + 2))))
                }
            }
            let tag = ordered ? "ol" : "ul"
            var out = "<\(tag)>"
            for item in items {
                if item.count == 1 {
                    out += "<li>\(inline(item[0]))</li>"
                } else {
                    let rest = Array(item.dropFirst())
                    out += "<li>\(inline(item[0]))\(blocks(rest))</li>"
                }
            }
            return out + "</\(tag)>"
        }

        // MARK: Figures and inline

        mutating func figureLine(_ trimmed: String) -> String? {
            guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")"),
                  let (alt, src, end) = Self.bracketed(Array(trimmed), from: 1), end == trimmed.count,
                  let ref = Self.imageRef(src) else { return nil }
            guard let address = resolve(ref) else { return nil }
            placed.append(ref)
            return figure(src: address, caption: alt)
        }

        mutating func inline(_ text: String) -> String {
            // Spans in spans: bounded, the rest is text.
            inlineDepth += 1
            defer { inlineDepth -= 1 }
            if inlineDepth > 12 { return escape(text) }
            let chars = Array(text)
            var out = ""
            var i = 0
            var plain = ""
            func flushPlain() {
                if !plain.isEmpty { out += escape(plain); plain = "" }
            }
            while i < chars.count {
                let c = chars[i]
                // Code span.
                if c == "`", let close = Self.find("`", in: chars, from: i + 1) {
                    flushPlain()
                    out += "<code>\(escape(String(chars[(i + 1)..<close])))</code>"
                    i = close + 1
                    continue
                }
                // An escaped dollar is a dollar, never math.
                if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                    plain.append("$")
                    i += 2
                    continue
                }
                // Math: $…$, $$…$$, \(…\), \[…\].
                if c == "$" || c == "\\", let (math, next) = Self.inlineMath(chars, at: i) {
                    flushPlain()
                    out += math
                    i = next
                    continue
                }
                // Image inline: a chart or picture, else its alt text.
                if c == "!", i + 1 < chars.count, chars[i + 1] == "[",
                   let (alt, src, end) = Self.bracketed(chars, from: i + 1) {
                    flushPlain()
                    if let ref = Self.imageRef(src), let address = resolve(ref) {
                        placed.append(ref)
                        out += "<img src=\"\(escape(address))\" alt=\"\(escape(alt))\">"
                    } else {
                        out += escape(alt)
                    }
                    i = end
                    continue
                }
                // Link.
                if c == "[", let (label, target, end) = Self.bracketed(chars, from: i) {
                    flushPlain()
                    let inner = inline(label)
                    if let href = safeLink(target) {
                        out += "<a href=\"\(escape(href))\">\(inner)</a>"
                        // The address when the text isn't it: a PDF never
                        // hides where a link goes.
                        let shown = Self.plain(label).trimmingCharacters(in: .whitespaces)
                        if !Self.sameAddress(shown, href) { out += " <span class=\"addr\">(\(escape(Self.display(href))))</span>" }
                    } else {
                        out += inner
                    }
                    i = end
                    continue
                }
                // Bold, italic, strike.
                if let (tag, inner, next) = Self.emphasis(chars, at: i) {
                    flushPlain()
                    out += "<\(tag)>\(inline(inner))</\(tag)>"
                    i = next
                    continue
                }
                plain.append(c)
                i += 1
            }
            flushPlain()
            return out
        }

        // MARK: Helpers

        /// How far a closing marker, bracket or backtick is looked for: a
        /// 200,000-character line of asterisks stays linear.
        static let scanLimit = 1_000
        /// A table's columns, and the document's cells: padding short rows
        /// to the header can't multiply a 200,000-scalar input.
        static let maxColumns = 50
        static let maxCells = 20_000

        static func emphasis(_ chars: [Character], at i: Int) -> (String, String, Int)? {
            for (marker, tag) in [("**", "strong"), ("__", "strong"), ("~~", "del"), ("*", "em"), ("_", "em")] {
                let m = Array(marker)
                guard starts(chars, at: i, with: m) else { continue }
                // `_` inside a word stays (snake_case).
                if marker.hasPrefix("_"), i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber { continue }
                guard i + m.count < chars.count, !chars[i + m.count].isWhitespace,
                      let close = findMarker(m, in: chars, from: i + m.count), close > i + m.count else { continue }
                return (tag, String(chars[(i + m.count)..<close]), close + m.count)
            }
            return nil
        }

        /// How many lines display math may span.
        static let mathLines = 60

        /// `$$ … $$` or `\[ … \]` from line `i`, the delimiters starting
        /// and ending lines (one line or several): the MathML and the line
        /// after. Nil when it isn't that or can't be read (then it's text).
        static func displayMath(_ lines: [String], from i: Int) -> (String, Int)? {
            let first = lines[i].trimmingCharacters(in: .whitespaces)
            let pairs = [("$$", "$$"), ("\\[", "\\]")]
            guard let (open, close) = pairs.first(where: { first.hasPrefix($0.0) }) else { return nil }
            var text = String(first.dropFirst(open.count))
            var j = i
            while true {
                let t = text.trimmingCharacters(in: .whitespaces)
                if t.hasSuffix(close), j > i || t.count >= close.count {
                    let inner = String(t.dropLast(close.count))
                    // Something after the closing delimiter: not a block.
                    guard !inner.contains(close) else { return nil }
                    guard let math = DocumentMath.mathML(inner, display: true) else { return nil }
                    return (math, j + 1)
                }
                j += 1
                guard j < lines.count, j - i < mathLines else { return nil }
                text += "\n" + lines[j]
            }
        }

        /// Math inside a line at `i`: the MathML and the index after it.
        /// A `$` opens only before a non-space and closes only after one,
        /// not before a digit: "$5 and $10" stays money.
        static func inlineMath(_ chars: [Character], at i: Int) -> (String, Int)? {
            func close(_ m: [Character], from: Int) -> Int? {
                var j = from
                let end = min(chars.count, from + scanLimit)
                while j + m.count <= end {
                    if starts(chars, at: j, with: m) { return j }
                    j += 1
                }
                return nil
            }
            if chars[i] == "\\" {
                guard i + 1 < chars.count, chars[i + 1] == "(" || chars[i + 1] == "[" else { return nil }
                let display = chars[i + 1] == "["
                guard let j = close(display ? ["\\", "]"] : ["\\", ")"], from: i + 2),
                      let math = DocumentMath.mathML(String(chars[(i + 2)..<j]), display: display) else { return nil }
                return (math, j + 2)
            }
            if i + 1 < chars.count, chars[i + 1] == "$" {
                guard let j = close(["$", "$"], from: i + 2), j > i + 2,
                      let math = DocumentMath.mathML(String(chars[(i + 2)..<j]), display: true) else { return nil }
                return (math, j + 2)
            }
            guard i + 1 < chars.count, !chars[i + 1].isWhitespace else { return nil }
            var j = i + 1
            let end = min(chars.count, i + 1 + scanLimit)
            while j < end {
                if chars[j] == "$", chars[j - 1] != "\\" {
                    // Another dollar that can't close it: money ("$5 and
                    // $10, … 0$"), not math.
                    guard !chars[j - 1].isWhitespace, j + 1 == chars.count || !chars[j + 1].isNumber else { return nil }
                    guard j > i + 1, let math = DocumentMath.mathML(String(chars[(i + 1)..<j]), display: false) else { return nil }
                    return (math, j + 1)
                }
                j += 1
            }
            return nil
        }

        static func heading(_ trimmed: String) -> (Int, String)? {
            var level = 0
            for ch in trimmed { if ch == "#" { level += 1 } else { break } }
            guard (1...6).contains(level) else { return nil }
            let rest = trimmed.dropFirst(level)
            guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
            var text = rest.trimmingCharacters(in: .whitespaces)
            while text.hasSuffix("#") { text.removeLast() }
            return (level, text.trimmingCharacters(in: .whitespaces))
        }

        static func isRule(_ trimmed: String) -> Bool {
            let compact = trimmed.filter { !$0.isWhitespace }
            guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
            return compact.allSatisfy { $0 == first }
        }

        static func tableSeparator(_ trimmed: String) -> [String?]? {
            guard trimmed.hasPrefix("|") || trimmed.hasPrefix(":") || trimmed.hasPrefix("-") else { return nil }
            let cells = cells(trimmed)
            guard !cells.isEmpty else { return nil }
            var aligns: [String?] = []
            for cell in cells {
                let c = cell.trimmingCharacters(in: .whitespaces)
                guard c.count >= 3, c.allSatisfy({ $0 == "-" || $0 == ":" }), c.contains("-") else { return nil }
                switch (c.hasPrefix(":"), c.hasSuffix(":")) {
                case (true, true): aligns.append("c")
                case (false, true): aligns.append("r")
                default: aligns.append(nil)
                }
            }
            return aligns
        }

        static func cells(_ row: String) -> [String] {
            var r = row.trimmingCharacters(in: .whitespaces)
            if r.hasPrefix("|") { r.removeFirst() }
            if r.hasSuffix("|") { r.removeLast() }
            return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        static func indent(_ line: String) -> Int {
            var n = 0
            for ch in line {
                if ch == " " { n += 1 } else if ch == "\t" { n += 4 } else { break }
            }
            return n
        }

        static func listMarker(_ line: String) -> (ordered: Bool, text: String)? {
            let t = line.trimmingCharacters(in: .whitespaces)
            for bullet in ["- ", "* ", "+ "] where t.hasPrefix(bullet) {
                return (false, String(t.dropFirst(2)))
            }
            let digits = t.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let rest = t.dropFirst(digits.count)
            guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
            return (true, String(rest.dropFirst(2)))
        }

        /// `[label](target)` starting at `open` (the `[`): the label, the
        /// target, and the index after `)`.
        static func bracketed(_ chars: [Character], from open: Int) -> (String, String, Int)? {
            guard open < chars.count, chars[open] == "[" else { return nil }
            var depth = 0
            var j = open
            let end = min(chars.count, open + scanLimit)
            while j < end {
                if chars[j] == "[" { depth += 1 }
                if chars[j] == "]" { depth -= 1; if depth == 0 { break } }
                j += 1
            }
            guard j < end, j + 1 < chars.count, chars[j + 1] == "(",
                  let close = find(")", in: chars, from: j + 2) else { return nil }
            return (String(chars[(open + 1)..<j]), String(chars[(j + 2)..<close]), close + 1)
        }

        static func imageRef(_ src: String) -> ImageRef? {
            let s = src.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("chart:") {
                let id = String(s.dropFirst(6))
                return id.isEmpty ? nil : .chart(id)
            }
            if s.hasPrefix("project:") {
                let id = String(s.dropFirst(8))
                return id.isEmpty ? nil : .picture(id)
            }
            return nil
        }

        static func find(_ ch: Character, in chars: [Character], from: Int) -> Int? {
            var j = from
            let end = min(chars.count, from + scanLimit)
            while j < end { if chars[j] == ch { return j }; j += 1 }
            return nil
        }

        static func starts(_ chars: [Character], at i: Int, with m: [Character]) -> Bool {
            guard i + m.count <= chars.count else { return false }
            for k in 0..<m.count where chars[i + k] != m[k] { return false }
            return true
        }

        static func findMarker(_ m: [Character], in chars: [Character], from: Int) -> Int? {
            var j = from
            let end = min(chars.count, from + scanLimit)
            while j + m.count <= end {
                if starts(chars, at: j, with: m), !chars[j - 1].isWhitespace {
                    // A single * or _ mustn't close on half of a double one.
                    if m.count == 1, j + 1 < chars.count, chars[j + 1] == m[0] { j += 2; continue }
                    return j
                }
                j += 1
            }
            return nil
        }

        /// Text without the Markdown around it, for headings' entries and
        /// comparing a link's text with its address.
        static func plain(_ text: String) -> String {
            var out = text
            for m in ["**", "__", "~~", "`", "*"] { out = out.replacingOccurrences(of: m, with: "") }
            return out
        }

        static func display(_ href: String) -> String {
            var s = href
            for p in ["mailto:", "https://", "http://"] where s.lowercased().hasPrefix(p) { s = String(s.dropFirst(p.count)); break }
            if s.hasSuffix("/") { s.removeLast() }
            return s
        }

        static func sameAddress(_ shown: String, _ href: String) -> Bool {
            let a = display(shown).lowercased()
            let b = display(href).lowercased()
            return a == b || a == "www." + b || "www." + a == b
        }
    }
}
