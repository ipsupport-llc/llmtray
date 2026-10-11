import Foundation

/// A Hugging Face README as the model card shows it: the HTML blocks many
/// cards open with (a centered logo, a `<div>` bar of links) turned into
/// what they say -- a link stays a link, pictures and markup go -- since
/// the card renders Markdown only and showed that HTML as text. Only HTML
/// blocks in the CommonMark sense change (a line starting with a tag, up to
/// the next blank line); prose, lists, code and inline HTML stay as written.
public enum ModelCardText {
    /// A block longer than this is left alone (no card needs it).
    static let blockLimit = 20_000

    public static func clean(_ markdown: String) -> String {
        var out: [String] = []
        var block: [String] = []
        var fence: (char: Character, count: Int)?
        // A lone tag can't interrupt a paragraph; after a heading it can.
        var inParagraph = false
        func flush() {
            guard !block.isEmpty else { return }
            let text = block.joined(separator: "\n")
            if text.utf16.count <= blockLimit {
                out.append(contentsOf: convert(text))
            } else {
                out.append(contentsOf: block)
            }
            block.removeAll()
        }
        var comment = false  // the block is a comment: it ends at -->
        for line in markdown.components(separatedBy: "\n") {
            if !block.isEmpty {
                if comment {
                    block.append(line)
                    if line.contains("-->") { flush(); comment = false }
                } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    flush()
                    out.append(line)
                    inParagraph = false
                } else {
                    block.append(line)
                }
                continue
            }
            if let open = fence {
                out.append(line)
                if closes(line, open) { fence = nil }
                continue
            }
            if let open = opens(line) {
                fence = open
                out.append(line)
                inParagraph = false
            } else if let start = htmlBlockStart(line, inParagraph: inParagraph) {
                block.append(line)
                if start == .comment {
                    if line.contains("-->") { flush() } else { comment = true }
                }
            } else {
                out.append(line)
                let t = line.trimmingCharacters(in: .whitespaces)
                inParagraph = !t.isEmpty && !t.hasPrefix("#")
                    && t.range(of: #"^([-*_])(\s*\1){2,}\s*$"#, options: .regularExpression) == nil
            }
        }
        flush()
        return out.joined(separator: "\n")
    }

    /// Three or more ` or ~, after any indent, list marker or quote: a
    /// fence missed would have its code changed, one too many changes nothing.
    static func opens(_ line: String) -> (char: Character, count: Int)? {
        guard let start = line.range(of: #"^(?:\s*(?:[-*+]|\d+[.)]|>)\s+)*\s*"#, options: .regularExpression) else { return nil }
        let rest = line[start.upperBound...]
        guard let c = rest.first, c == "`" || c == "~" else { return nil }
        let count = rest.prefix { $0 == c }.count
        // A backtick fence's info string has no backtick.
        guard count >= 3, c == "~" || !rest.dropFirst(count).contains("`") else { return nil }
        return (c, count)
    }

    /// The same character, at least as many, nothing after but spaces.
    static func closes(_ line: String, _ open: (char: Character, count: Int)) -> Bool {
        guard let start = line.range(of: #"^(?:\s*>)*\s*"#, options: .regularExpression) else { return false }
        let rest = line[start.upperBound...]
        let count = rest.prefix { $0 == open.char }.count
        return count >= open.count && rest.dropFirst(count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    enum BlockStart { case comment, block, tag }

    /// CommonMark's HTML block starts, up to three spaces in: a comment; a
    /// block-level tag; any other complete tag alone on its line, only
    /// outside a paragraph (it can't interrupt one).
    static func htmlBlockStart(_ line: String, inParagraph: Bool) -> BlockStart? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = String(line.dropFirst(indent))
        if rest.hasPrefix("<!--") { return .comment }
        if let r = rest.range(of: #"^</?([A-Za-z][A-Za-z0-9-]*)(?=[\s/>]|$)"#, options: .regularExpression) {
            let name = rest[r].trimmingCharacters(in: CharacterSet(charactersIn: "</")).lowercased()
            if blockStartTags.contains(name) { return .block }
        }
        let alone = "^</?[A-Za-z][A-Za-z0-9-]*" + attributes + #">\s*$"#
        if !inParagraph, rest.range(of: alone, options: .regularExpression) != nil { return .tag }
        return nil
    }

    /// CommonMark's block-level tag names (HTML block type 6).
    static let blockStartTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
        "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
        "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
        "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot",
        "th", "thead", "title", "tr", "track", "ul", "picture"]

    // Attributes may quote '>' -- a tag ends at the first '>' outside quotes.
    static let attributes = #"(?:[^>"']|"[^"]*"|'[^']*')*"#
    static let tag = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->|</?([A-Za-z][A-Za-z0-9-]*)"# + attributes + ">")
    /// One attribute: name, then an optional quoted or bare value.
    static let attribute = try! NSRegularExpression(pattern: #"([^\s"'=<>/]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#)
    static let blockTags: Set<String> = ["div", "p", "center", "h1", "h2", "h3", "h4", "h5", "h6", "table", "tr",
                                         "ul", "ol", "li", "section", "details", "summary", "picture", "figure", "br", "hr"]

    /// One HTML block as Markdown lines: a link's text and address, line
    /// breaks at block tags, every other tag (pictures too) dropped.
    static func convert(_ text: String) -> [String] {
        let ns = text as NSString
        var out = ""
        var link: String?  // the open <a>'s address
        var labelStart: Int?  // utf16 offset: an index wouldn't survive appends
        var position = 0
        for match in tag.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: position, length: match.range.location - position))
            position = match.range.location + match.range.length
            let whole = ns.substring(with: match.range)
            guard match.range(at: 1).location != NSNotFound else { continue }  // a comment
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let closing = whole.hasPrefix("</")
            if name == "a" {
                if !closing, let address = address(whole) {
                    link = address
                    out += "["
                    labelStart = out.utf16.count
                } else if closing, let address = link, let offset = labelStart {
                    let start = String.Index(utf16Offset: offset, in: out)
                    // On one line, with its brackets escaped: the card's renderer
                    // reads a link within a line, and a bracket would end it early.
                    let label = String(out[start...]).components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }.joined(separator: " ")
                        .replacingOccurrences(of: "[", with: "\\[")
                        .replacingOccurrences(of: "]", with: "\\]")
                    out = String(out[..<start]) + label + "](\(address))"
                    link = nil
                    labelStart = nil
                }
            } else if blockTags.contains(name) {
                out += "\n"
            } else if (name == "td" || name == "th"), !closing {
                out += " "  // cells of a row apart
            }
        }
        out += ns.substring(from: position)
        if link != nil, let open = out.lastIndex(of: "[") { out.remove(at: open) }  // never closed
        out = out.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
        // No indent left over (four spaces would make a code block), no
        // lines empty or with only the dots that separated the links.
        return out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !["•", "|", "·"].contains($0) }
    }

    /// The `href` of an `<a ...>` tag, as a Markdown link destination.
    static func address(_ tag: String) -> String? {
        let ns = tag as NSString
        // Past "<a": the attributes, each read whole so a quoted value
        // ("hint href='x'") is never taken for one.
        let from = min(2, ns.length)
        for m in attribute.matches(in: tag, range: NSRange(location: from, length: ns.length - from))
        where ns.substring(with: m.range(at: 1)).lowercased() == "href" {
            for i in 2...4 where m.range(at: i).location != NSNotFound {
                let value = ns.substring(with: m.range(at: i)).trimmingCharacters(in: .whitespaces)
                if value.isEmpty || value.contains(where: { "<>\n".contains($0) }) { return nil }
                // Parentheses or spaces need the <...> form.
                return value.contains(where: { " ()".contains($0) }) ? "<\(value)>" : value
            }
            return nil
        }
        return nil
    }
}
