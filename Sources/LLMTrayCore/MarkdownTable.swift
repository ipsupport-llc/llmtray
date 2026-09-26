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
        if body.hasSuffix("|") && !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for ch in body {
            if escaped {
                current.append(ch == "|" ? "|" : "\\\(ch)")
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "`" {
                // A pipe inside `code` is part of the cell, as in GFM.
                inCode.toggle()
                current.append(ch)
            } else if ch == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
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
