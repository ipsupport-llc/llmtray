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
        for line in markdown.components(separatedBy: "\n") {
            if !block.isEmpty {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    flush()
                    out.append(line)
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
            } else if startsHTMLBlock(line) {
                block.append(line)
            } else {
                out.append(line)
            }
        }
        flush()
        return out.joined(separator: "\n")
    }

    /// Up to three spaces, then three or more ` or ~.
    static func opens(_ line: String) -> (char: Character, count: Int)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let c = rest.first, c == "`" || c == "~" else { return nil }
        let count = rest.prefix { $0 == c }.count
        // A backtick fence's info string has no backtick.
        guard count >= 3, c == "~" || !rest.dropFirst(count).contains("`") else { return nil }
        return (c, count)
    }

    /// The same character, at least as many, nothing after but spaces.
    static func closes(_ line: String, _ open: (char: Character, count: Int)) -> Bool {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        let count = rest.prefix { $0 == open.char }.count
        return count >= open.count && rest.dropFirst(count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Up to three spaces, then a tag (open or close) or a comment.
    static func startsHTMLBlock(_ line: String) -> Bool {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        if rest.hasPrefix("<!--") { return true }
        return rest.range(of: #"^</?[A-Za-z][A-Za-z0-9-]*(?=[\s/>]|$)"#, options: .regularExpression) != nil
    }

    // Attributes may quote '>' -- a tag ends at the first '>' outside quotes.
    static let attributes = #"(?:[^>"']|"[^"]*"|'[^']*')*"#
    static let tag = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->|</?([A-Za-z][A-Za-z0-9-]*)"# + attributes + ">")
    static let href = try! NSRegularExpression(pattern: #"(?:^|\s)href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#, options: .caseInsensitive)
    static let blockTags: Set<String> = ["div", "p", "center", "h1", "h2", "h3", "h4", "h5", "h6", "table", "tr",
                                         "ul", "ol", "li", "section", "details", "summary", "picture", "figure", "br", "hr"]

    /// One HTML block as Markdown lines: a link's text and address, line
    /// breaks at block tags, every other tag (pictures too) dropped.
    static func convert(_ text: String) -> [String] {
        let ns = text as NSString
        var out = ""
        var link: String?  // the open <a>'s address
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
                } else if closing, let address = link {
                    out += "](\(address))"
                    link = nil
                }
            } else if blockTags.contains(name) {
                out += "\n"
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

    static func address(_ tag: String) -> String? {
        let ns = tag as NSString
        guard let m = href.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for i in 1...3 where m.range(at: i).location != NSNotFound {
            let value = ns.substring(with: m.range(at: i)).trimmingCharacters(in: .whitespaces)
            // Markdown's own link syntax can't carry these.
            return value.isEmpty || value.contains(where: { " ()<>".contains($0) }) ? nil : value
        }
        return nil
    }
}
