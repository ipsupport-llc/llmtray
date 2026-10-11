import Foundation

/// A Hugging Face README as the model card shows it: Markdown, with the
/// HTML many cards open with (centered logos, link bars in `<div>`s) turned
/// into what it says -- a link stays a link, a picture and the markup go --
/// since the card renders Markdown only and showed that HTML as text.
/// Fenced code is left as written: an HTML example there is the point.
public enum ModelCardText {
    public static func clean(_ markdown: String) -> String {
        var out: [String] = []
        var prose: [String] = []
        var fence: String?
        func flush() {
            guard !prose.isEmpty else { return }
            out.append(strip(prose.joined(separator: "\n")))
            prose.removeAll()
        }
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                out.append(line)
                if trimmed.hasPrefix(open) { fence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                fence = String(trimmed.prefix(3))
                out.append(line)
            } else {
                prose.append(line)
            }
        }
        flush()
        return out.joined(separator: "\n")
    }

    /// Prose with its HTML turned into Markdown or dropped.
    static func strip(_ text: String) -> String {
        var s = text
        func replace(_ pattern: String, _ template: String) {
            s = s.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        replace(#"<!--[\s\S]*?-->"#, "")
        // A link's text (its own tags dropped below) and address.
        replace(#"<a\s[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a\s*>"#, "[$2]($1)")
        replace(#"<br\s*/?>"#, "\n")
        // Lines that held markup lose their indent: four spaces of a nested
        // <div> would make the rest a code block.
        var lines: [String] = []
        let tag = try! NSRegularExpression(pattern: #"</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>"#)
        for line in s.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            guard tag.firstMatch(in: line, range: range) != nil || line.contains("<img") else {
                lines.append(line)
                continue
            }
            lines.append(line.trimmingCharacters(in: .whitespaces))
        }
        s = lines.joined(separator: "\n")
        // Block tags end a paragraph; the rest, and pictures, just go. A tag
        // may span lines (an <img> with one attribute per line). An autolink
        // (<https://...>) isn't a tag: it has no space-free name then '>'.
        replace(#"</?(?:div|p|center|h[1-6]|table|tr|ul|ol|li|section|details|summary|picture|figure)(?:\s[^<>]*)?/?>"#, "\n")
        replace(#"</?(?!https?:)[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>"#, "")
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        // Lines left empty or with only the dots that separated links.
        s = s.components(separatedBy: "\n").map {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == "•" || t == "|" || t == "·" ? "" : $0
        }.joined(separator: "\n")
        replace(#"\n{3,}"#, "\n\n")
        return s.trimmingCharacters(in: .newlines)
    }
}
