import SwiftUI
import LLMTrayCore

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

        for rawLine in joinDisplayMath(source.components(separatedBy: "\n")) {
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
                var h = inline(baseSize, text)
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
                var body = inline(baseSize, text)
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
                out.append(inline(baseSize, String(trimmed.dropFirst(2))))
                continue
            }

            // Numbered list: "1. x" / "1) x"
            if let (number, text) = numbered(trimmed) {
                out.append(AttributedString(indent + number + " "))
                out.append(inline(baseSize, text))
                continue
            }

            out.append(inline(baseSize, line))
        }
        return out
    }

    /// Inline markdown via Foundation (plain text if it doesn't parse), with
    /// LaTeX math ($...$, \(...\), $$...$$, \[...\]) turned into Unicode in
    /// a serif face. The math is swapped for placeholder characters, the line
    /// is parsed once (so **bold around $x$** still works), then the math goes
    /// back in with the surrounding emphasis. `code` spans are left alone.
    static func inlineMarkdown(_ baseSize: CGFloat, _ text: String) -> AttributedString {
        inline(baseSize, text)
    }

    private static func inline(_ baseSize: CGFloat, _ text: String) -> AttributedString {
        guard text.contains("$") || text.contains("\\(") || text.contains("\\[") else { return markdown(text) }
        var maths: [(latex: String, display: Bool)] = []
        var masked = ""
        // Placeholders from a private-use block the text doesn't contain
        // (so a literal one can't be mistaken for math).
        let used = Set(text.unicodeScalars.map(\.value))
        let base: UInt32 = [0xE000, 0xF0000, 0x100000].first { start in
            !used.contains { $0 >= start && $0 < start + 4096 }
        } ?? 0xE000
        for (isCode, segment) in codeSpans(text) {
            if isCode { masked += segment; continue }
            for piece in MathSpans.split(segment) {
                switch piece {
                case .text(let t):
                    masked += t
                case .math(let latex, let display):
                    guard maths.count < 4096, let scalar = Unicode.Scalar(base + UInt32(maths.count)) else { masked += latex; continue }
                    masked.unicodeScalars.append(scalar)   // private use: never in model text
                    maths.append((latex, display))
                }
            }
        }
        var out = markdown(masked)
        for (n, math) in maths.enumerated() {
            guard let scalar = Unicode.Scalar(base + UInt32(n)), let range = out.range(of: String(Character(scalar))) else { continue }
            let bold = out[range].inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false
            var rendered = AttributedString(LaTeXText.toUnicode(math.latex))
            if let run = out[range].runs.first { rendered.mergeAttributes(run.attributes) }
            rendered.font = .system(size: math.display ? baseSize + 2 : baseSize + 1, weight: bold ? .bold : .regular, design: .serif)
            out.replaceSubrange(range, with: rendered)
        }
        return out
    }

    /// The line split into code spans (a run of N backticks up to the next
    /// run of exactly N, as in CommonMark) and the text between them.
    static func codeSpans(_ text: String) -> [(isCode: Bool, text: String)] {
        let chars = Array(text)
        var out: [(Bool, String)] = []
        var plain = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "`" else { plain.append(chars[i]); i += 1; continue }
            var run = 0
            while i + run < chars.count, chars[i + run] == "`" { run += 1 }
            // Find a closing run of the same length.
            var j = i + run
            var close: Int?
            while j < chars.count {
                if chars[j] == "`" {
                    var k = 0
                    while j + k < chars.count, chars[j + k] == "`" { k += 1 }
                    if k == run { close = j; break }
                    j += k
                } else {
                    j += 1
                }
            }
            guard let end = close else { plain += String(chars[i..<(i + run)]); i += run; continue }
            if !plain.isEmpty { out.append((false, plain)); plain = "" }
            out.append((true, String(chars[i..<(end + run)])))
            i = end + run
        }
        if !plain.isEmpty { out.append((false, plain)) }
        return out
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// A display formula spread over several lines ($$ ... $$ or \[ ... \])
    /// becomes one line, so it's converted as a whole. Code fences untouched.
    private static func joinDisplayMath(_ lines: [String]) -> [String] {
        var out: [String] = []
        var pending: [String]?
        var closer = ""
        var inFence = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if pending == nil, t.hasPrefix("```") { inFence.toggle() }
            if inFence { out.append(line); continue }
            if var open = pending {
                // The first closing delimiter anywhere ends the block; text
                // after it stays a line of its own.
                if let close = t.range(of: closer) {
                    open.append(String(t[..<close.upperBound]))
                    out.append(open.joined(separator: " "))
                    let rest = t[close.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { out.append(rest) }
                    pending = nil
                } else {
                    open.append(t)
                    pending = open
                }
                continue
            }
            for (start, end) in [("$$", "$$"), ("\\[", "\\]")] where t.hasPrefix(start) {
                if !t.dropFirst(start.count).contains(end) {
                    pending = [t]
                    closer = end
                }
                break
            }
            if pending == nil { out.append(line) }
        }
        if let open = pending { out.append(contentsOf: open) }   // never closed: as written
        return out
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

extension ChatMarkdown {
    /// A table cell: inline markdown and math, no block syntax.
    static func cell(_ text: String, baseSize: CGFloat) -> AttributedString {
        inlineMarkdown(baseSize, text)
    }
}

/// A message's markdown as text and, where the model wrote one, a real
/// table (a grid, markdown in its cells). Without a table it's the one Text
/// it always was (whole-message selection).
struct ChatMarkdownView: View {
    let source: String
    let baseSize: CGFloat

    var body: some View {
        let blocks = MarkdownBlock.split(source)
        if blocks.count == 1, case .text = blocks[0] {
            Text(ChatMarkdown.render(source, baseSize: baseSize))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let text):
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(ChatMarkdown.render(text.trimmingCharacters(in: .newlines), baseSize: baseSize))
                        }
                    case .table(let table):
                        MarkdownTableView(table: table, baseSize: baseSize)
                    }
                }
            }
        }
    }
}

/// A markdown table as a grid: a shaded bold header, hairlines between
/// rows, the columns aligned as the separator row says. Scrolls sideways
/// when it's wider than the chat.
struct MarkdownTableView: View {
    let table: MarkdownTable
    let baseSize: CGFloat

    var body: some View {
        // The widest cells that fit (text wraps inside them); sideways
        // scrolling only when even narrow cells don't.
        ViewThatFits(in: .horizontal) {
            grid(cellWidth: 320)
            grid(cellWidth: 200)
            grid(cellWidth: 140)
            grid(cellWidth: 100)
            ScrollView(.horizontal, showsIndicators: false) { grid(cellWidth: 140) }
        }
    }

    private func grid(cellWidth: CGFloat) -> some View {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { c in
                        cell(table.header[c], column: c, header: true, width: cellWidth)
                    }
                }
                .background(Color.primary.opacity(0.07))
                ForEach(Array(table.rows.enumerated()), id: \.offset) { r, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<table.columnCount, id: \.self) { c in
                            cell(row[c], column: c, header: false, width: cellWidth)
                        }
                    }
                    .background(r % 2 == 1 ? Color.primary.opacity(0.03) : Color.clear)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func cell(_ text: String, column: Int, header: Bool, width: CGFloat) -> some View {
        let alignment = table.alignments[column]
        var content = ChatMarkdown.cell(text, baseSize: baseSize)
        if header { content.font = .system(size: baseSize, weight: .semibold) }
        return Text(content)
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: min(60, width), maxWidth: width, alignment: alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .padding(.horizontal, width < 140 ? 6 : 10)
            .padding(.vertical, 6)
            // The whole row's height: its shading is even across the cells.
            .frame(maxHeight: .infinity)
            .gridColumnAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
    }
}
