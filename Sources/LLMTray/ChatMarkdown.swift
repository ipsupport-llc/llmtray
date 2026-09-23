import SwiftUI

/// Renders a chat message's markdown into a single AttributedString, so the
/// bubble stays ONE `Text` (whole-message text selection keeps working,
/// unlike a VStack of per-block views).
///
/// Before this, bubbles showed the raw source -- `**bold**`, `*italic*`,
/// `### heading`, list asterisks -- because a SwiftUI `Text` only
/// interprets markdown for string *literals*, never for a runtime String.
///
/// Inline syntax (bold, italic, `code`, ~~strike~~, links) goes through
/// Foundation's own parser in `.inlineOnlyPreservingWhitespace` mode, which
/// keeps the model's single newlines as line breaks. Block syntax (headings,
/// lists, quotes, rules, fenced code, tables) is handled line by line here,
/// since Foundation's full-markdown mode produces presentation intents
/// SwiftUI's Text doesn't lay out. Streaming-safe: an unclosed `**` or
/// ``` fence just renders literally / as code until the rest arrives.
enum ChatMarkdown {
    static func render(_ source: String, baseSize: CGFloat) -> AttributedString {
        var out = AttributedString()
        var inFence = false
        var firstLine = true

        func newline() {
            if !firstLine { out.append(AttributedString("\n")) }
            firstLine = false
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inFence.toggle()
                // The fence line itself (``` or ```swift) isn't shown.
                continue
            }
            if inFence {
                newline()
                var code = AttributedString(line.isEmpty ? " " : line)
                code.font = .system(size: baseSize - 1, design: .monospaced)
                code.backgroundColor = Color.gray.opacity(0.18)
                out.append(code)
                continue
            }

            // Table header/body separator row (|---|:--:|): dropped entirely,
            // before emitting its line break.
            if trimmed.hasPrefix("|") && isTableSeparator(trimmed) { continue }

            newline()

            if trimmed.isEmpty { continue }

            // Horizontal rule: ---, ***, ___
            if isRule(trimmed) {
                var rule = AttributedString("────────────")
                rule.foregroundColor = .secondary
                out.append(rule)
                continue
            }

            // Heading: # .. ######
            if let (level, text) = heading(trimmed) {
                var h = inline(text)
                let bump: CGFloat = [0, 5, 3, 2, 1, 0, 0][min(level, 6)]
                h.font = .system(size: baseSize + bump, weight: .bold)
                out.append(h)
                continue
            }

            // Table row: keep as-is but monospaced so columns roughly line up.
            if trimmed.hasPrefix("|") {
                var row = AttributedString(trimmed)
                row.font = .system(size: baseSize - 1, design: .monospaced)
                out.append(row)
                continue
            }

            let indent = String(repeating: "    ", count: leadingIndentLevel(line))

            // Blockquote
            if trimmed.hasPrefix(">") {
                let text = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                var bar = AttributedString(indent + "▍ ")
                bar.foregroundColor = .secondary
                var body = inline(text)
                body.foregroundColor = .secondary
                out.append(bar)
                out.append(body)
                continue
            }

            // Bullet list: "- x", "* x", "+ x" (a space is required, so
            // "*italic*" at line start is NOT a bullet).
            if let first = trimmed.first, "-*+".contains(first),
               trimmed.dropFirst().first == " " {
                out.append(AttributedString(indent + "•  "))
                out.append(inline(String(trimmed.dropFirst(2))))
                continue
            }

            // Numbered list: "1. x" / "1) x"
            if let (number, text) = numbered(trimmed) {
                out.append(AttributedString(indent + number + " "))
                out.append(inline(text))
                continue
            }

            out.append(inline(line))
        }
        return out
    }

    /// Inline markdown via Foundation; plain text if it doesn't parse.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private static func isRule(_ s: String) -> Bool {
        let compact = s.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let c = compact.first, "-*_".contains(c) else { return false }
        return compact.allSatisfy { $0 == c }
    }

    private static func heading(_ s: String) -> (Int, String)? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = s.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func numbered(_ s: String) -> (String, String)? {
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = s.dropFirst(digits.count)
        guard let delim = rest.first, delim == "." || delim == ")",
              rest.dropFirst().first == " " else { return nil }
        return (digits + ".", String(rest.dropFirst(2)))
    }

    private static func isTableSeparator(_ s: String) -> Bool {
        s.allSatisfy { "|-: ".contains($0) } && s.contains("-")
    }

    /// Nested list depth from leading spaces/tabs (2 spaces or 1 tab per level).
    private static func leadingIndentLevel(_ line: String) -> Int {
        var spaces = 0
        for ch in line {
            if ch == " " { spaces += 1 } else if ch == "\t" { spaces += 4 } else { break }
        }
        return min(spaces / 2, 4)
    }
}
