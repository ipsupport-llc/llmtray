import Foundation

/// A markdown pipe table, parsed for display as a grid. Models write the
/// separator row (|---|:--:|) or leave it out; either way the first row is
/// the header.
public struct MarkdownTable: Equatable {
    public enum Alignment: Equatable { case leading, center, trailing }

    public var header: [String]
    public var rows: [[String]]
    public var alignments: [Alignment]

    public var columnCount: Int { header.count }

    /// nil unless every line is a table row (starts with "|") and there are
    /// at least two of them, separator included.
    public init?(lines: [String]) {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard trimmed.count >= 2, trimmed.allSatisfy({ $0.hasPrefix("|") }) else { return nil }
        var cellRows = trimmed.map(Self.cells)
        var alignments: [Alignment] = []
        if cellRows.count > 1, let parsed = Self.separator(cellRows[1]) {
            alignments = parsed
            cellRows.remove(at: 1)
        }
        // Separator rows elsewhere (a model that repeats one) are dropped.
        cellRows = cellRows.enumerated().filter { $0.offset == 0 || Self.separator($0.element) == nil }.map(\.element)
        let columns = cellRows.map(\.count).max() ?? 0
        guard columns > 0, cellRows.count >= 1 else { return nil }
        func padded(_ row: [String]) -> [String] {
            Array((row + Array(repeating: "", count: max(0, columns - row.count))).prefix(columns))
        }
        header = padded(cellRows[0])
        rows = cellRows.dropFirst().map(padded)
        self.alignments = Array((alignments + Array(repeating: .leading, count: columns)).prefix(columns))
    }

    /// "| a | b \| c |" -> ["a", "b | c"]: the outer pipes dropped, escaped
    /// ones kept in the cell.
    static func cells(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        // The closing pipe, unless escaped (an odd number of backslashes).
        if body.hasSuffix("|"), body.dropLast().reversed().prefix(while: { $0 == "\\" }).count % 2 == 0 {
            body = body.dropLast()
        }
        let chars = Array(body)
        let code = codeSpans(chars)
        var cells: [String] = []
        var current = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\", i + 1 < chars.count, !code[i] {
                // "\|" is a pipe in the cell; other escapes stay as written.
                current += chars[i + 1] == "|" ? "|" : "\\\(chars[i + 1])"
                i += 2
                continue
            }
            if ch == "|", !code[i] {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
            i += 1
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// Which characters are inside a code span: a run of N backticks opens
    /// one, the next run of exactly N closes it (GFM); an escaped backtick
    /// isn't a delimiter, and a run with no closing one is plain text. A
    /// pipe inside one is part of the cell -- models rarely escape it.
    static func codeSpans(_ chars: [Character]) -> [Bool] {
        var inside = [Bool](repeating: false, count: chars.count)
        func run(at i: Int) -> Int {
            var j = i
            while j < chars.count, chars[j] == "`" { j += 1 }
            return j - i
        }
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            guard chars[i] == "`" else { i += 1; continue }
            let length = run(at: i)
            var j = i + length
            var close: Int?
            while j < chars.count {
                if chars[j] == "`" {
                    let other = run(at: j)
                    if other == length { close = j; break }
                    j += other
                } else {
                    j += 1
                }
            }
            if let close {
                for k in i..<(close + length) { inside[k] = true }
                i = close + length
            } else {
                i += length
            }
        }
        return inside
    }

    /// The alignments a separator row gives (---, :--, :-:, --:), or nil if
    /// the row isn't one.
    static func separator(_ cells: [String]) -> [Alignment]? {
        guard !cells.isEmpty else { return nil }
        var out: [Alignment] = []
        for cell in cells {
            let c = cell.replacingOccurrences(of: " ", with: "")
            guard c.count >= 1, c.allSatisfy({ $0 == "-" || $0 == ":" }), c.contains("-") else {
                // An empty trailing cell from "|---|---||" is fine.
                if c.isEmpty { out.append(.leading); continue }
                return nil
            }
            switch (c.hasPrefix(":"), c.hasSuffix(":")) {
            case (true, true): out.append(.center)
            case (false, true): out.append(.trailing)
            default: out.append(.leading)
            }
        }
        return cells.contains(where: { $0.contains("-") }) ? out : nil
    }
}

/// A chat message in the pieces it's drawn as: runs of text (one Text) and
/// tables (a grid). Code fences are text: a table inside one stays code.
public enum MarkdownBlock: Equatable {
    case text(String)
    case table(MarkdownTable)

    public static func split(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var text: [String] = []
        var tableLines: [String] = []
        var inFence = false

        func flushText() {
            if !text.isEmpty { blocks.append(.text(text.joined(separator: "\n"))) }
            text = []
        }
        func flushTable() {
            guard !tableLines.isEmpty else { return }
            if let table = MarkdownTable(lines: tableLines) {
                flushText()
                blocks.append(.table(table))
            } else {
                text += tableLines
            }
            tableLines = []
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushTable()
                inFence.toggle()
                text.append(line)
                continue
            }
            if !inFence, trimmed.hasPrefix("|") {
                tableLines.append(line)
            } else {
                flushTable()
                text.append(line)
            }
        }
        flushTable()
        flushText()
        return blocks
    }
}
