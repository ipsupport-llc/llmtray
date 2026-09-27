import Foundation

/// One chunk to index: where it is in its page's raw text (Unicode scalar
/// offsets -- what SQLite's substr() counts on TEXT), its heading path and
/// the normalized body both FTS tables index.
public struct ChunkDraft: Equatable, Sendable {
    public var page: Int
    public var ord: Int
    /// The heading path ("Договор › 2. Оплата"), nil outside any heading.
    public var heading: String?
    /// Normalized: the heading path as prefix, then the chunk's text (a
    /// table chunk after the first repeats the header row).
    public var body: String
    public var start: Int
    public var length: Int
    public var isTable: Bool
    /// The estimate the size was decided by.
    public var tokens: Int
}

/// Splits pages into chunks by structure (adr/0012): 300-500 tokens, no
/// overlap, never across a page (the page is what a citation names);
/// Markdown headings start a chunk and give the following ones their path;
/// a table (pipe or tab-separated rows) is its own chunk, split by rows with
/// its header row repeated when it is long. Sizes are estimates
/// (`IndexText.estimatedTokens`), not the embedder's tokenizer.
public struct IndexChunker: Sendable {
    public var minTokens = 300
    public var maxTokens = 500

    public init(minTokens: Int = 300, maxTokens: Int = 500) {
        self.minTokens = minTokens
        self.maxTokens = maxTokens
    }

    /// `pages`: (page number, raw text), in order. The heading path carries
    /// from page to page.
    public func chunk(pages: [(page: Int, text: String)]) -> [ChunkDraft] {
        var state = State()
        var out: [ChunkDraft] = []
        for (number, text) in pages {
            chunk(page: number, text: text, state: &state, into: &out)
        }
        return out
    }

    // MARK: - lines and blocks

    private enum LineKind { case blank, heading(level: Int, title: String), table, text }

    private struct Block {
        enum Kind: Equatable { case heading, table, text }
        var kind: Kind
        var start: Int
        var end: Int
        var headingLevel = 0
        var headingTitle = ""
        /// For a table: the end of its header (row + Markdown separator).
        var headerEnd = 0
        var rowEnds: [Int] = []
    }

    private struct State {
        var headings: [(level: Int, title: String)] = []
        var ord = 0
        var path: String? { headings.isEmpty ? nil : headings.map(\.title).joined(separator: " › ") }
    }

    private static func classify(_ line: ArraySlice<Unicode.Scalar>) -> LineKind {
        var i = line.startIndex
        while i < line.endIndex, line[i] == " " || line[i] == "\t" { i += 1 }
        if i == line.endIndex || line[i...].allSatisfy({ $0.properties.isWhitespace }) { return .blank }
        // "# Title" .. "###### Title", at most 3 spaces of indent.
        if line[i] == "#", i - line.startIndex <= 3 {
            var j = i, level = 0
            while j < line.endIndex, line[j] == "#" { level += 1; j += 1 }
            if level <= 6, j < line.endIndex, line[j] == " " || line[j] == "\t" {
                var title = String(String.UnicodeScalarView(line[j...])).trimmingCharacters(in: .whitespaces)
                while title.hasSuffix("#") { title.removeLast() }
                title = title.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return .heading(level: level, title: title) }
            }
        }
        let pipes = line.reduce(0) { $0 + ($1 == "|" ? 1 : 0) }
        let tabs = line[i...].reduce(0) { $0 + ($1 == "\t" ? 1 : 0) }
        if (line[i] == "|" && pipes >= 2) || pipes >= 3 || tabs >= 2 { return .table }
        return .text
    }

    private static func isMarkdownSeparator(_ line: ArraySlice<Unicode.Scalar>) -> Bool {
        line.contains("-") && line.allSatisfy { "|-: \t".unicodeScalars.contains($0) }
    }

    private func blocks(_ s: [Unicode.Scalar]) -> [Block] {
        var lines: [(start: Int, end: Int)] = []   // end excludes the newline
        var lineStart = 0
        for (i, u) in s.enumerated() where u == "\n" {
            lines.append((lineStart, i))
            lineStart = i + 1
        }
        lines.append((lineStart, s.count))

        var out: [Block] = []
        func extend(_ kind: Block.Kind, _ line: (start: Int, end: Int)) -> Bool {
            guard var last = out.last, last.kind == kind else { return false }
            last.end = line.end
            if kind == .table { last.rowEnds.append(line.end) }
            out[out.count - 1] = last
            return true
        }
        var previousBlank = true
        for line in lines {
            switch Self.classify(s[line.start..<line.end]) {
            case .blank:
                previousBlank = true
                continue
            case .heading(let level, let title):
                out.append(Block(kind: .heading, start: line.start, end: line.end, headingLevel: level, headingTitle: title))
            case .table:
                if previousBlank || !extend(.table, line) {
                    out.append(Block(kind: .table, start: line.start, end: line.end, headerEnd: line.end, rowEnds: [line.end]))
                }
            case .text:
                if previousBlank || !extend(.text, line) {
                    out.append(Block(kind: .text, start: line.start, end: line.end))
                }
            }
            previousBlank = false
        }
        // A table's Markdown separator line (row 2) belongs to its header.
        for k in out.indices where out[k].kind == .table && out[k].rowEnds.count >= 2 {
            let second = (out[k].rowEnds[0] + 1)..<out[k].rowEnds[1]
            if Self.isMarkdownSeparator(s[second]) { out[k].headerEnd = out[k].rowEnds[1] }
        }
        return out
    }

    // MARK: - assembling chunks

    private func chunk(page: Int, text: String, state: inout State, into out: inout [ChunkDraft]) {
        let s = Array(text.unicodeScalars)
        func tokens(_ a: Int, _ b: Int) -> Int {
            IndexText.estimatedTokens(Substring(String(String.UnicodeScalarView(s[a..<b]))).unicodeScalars)
        }
        var current: (start: Int, end: Int, tokens: Int, startsAtHeading: Bool)?

        func emit(start: Int, end: Int, tokens: Int, isTable: Bool, startsAtHeading: Bool, extraPrefix: String? = nil) {
            var a = start, b = end
            while a < b, s[a].properties.isWhitespace { a += 1 }
            while b > a, s[b - 1].properties.isWhitespace { b -= 1 }
            guard a < b else { return }
            // A chunk that starts with its own heading line doesn't repeat it.
            let path = startsAtHeading
                ? (state.headings.count > 1 ? state.headings.dropLast().map(\.title).joined(separator: " › ") : nil)
                : state.path
            let raw = String(String.UnicodeScalarView(s[a..<b]))
            let body = [path, extraPrefix, raw].compactMap { $0 }.map(IndexText.normalize).filter { !$0.isEmpty }
                .joined(separator: "\n")
            out.append(ChunkDraft(page: page, ord: state.ord, heading: state.path, body: body, start: a, length: b - a,
                                  isTable: isTable, tokens: tokens))
            state.ord += 1
        }
        func flush() {
            if let c = current { emit(start: c.start, end: c.end, tokens: c.tokens, isTable: false, startsAtHeading: c.startsAtHeading) }
            current = nil
        }
        func add(start: Int, end: Int, tokens t: Int, isHeading: Bool = false) {
            if var c = current {
                if c.tokens + t > maxTokens {
                    flush()
                } else {
                    c.end = end
                    c.tokens += t
                    current = c
                    return
                }
            }
            current = (start, end, t, isHeading)
        }

        for block in blocks(s) {
            switch block.kind {
            case .heading:
                flush()
                while let last = state.headings.last, last.level >= block.headingLevel { state.headings.removeLast() }
                state.headings.append((block.headingLevel, block.headingTitle))
                add(start: block.start, end: block.end, tokens: tokens(block.start, block.end), isHeading: true)
            case .table:
                // Its own chunk; a heading line just before it stays with it.
                if let c = current, !c.startsAtHeading || c.tokens > 32 { flush() }
                let leadStart = current?.start ?? block.start
                let lead = current?.startsAtHeading ?? false
                current = nil
                let total = tokens(block.start, block.end)
                if total <= maxTokens {
                    emit(start: leadStart, end: block.end, tokens: total, isTable: true, startsAtHeading: lead)
                    continue
                }
                let headerText = String(String.UnicodeScalarView(s[block.start..<block.headerEnd]))
                let headerTokens = tokens(block.start, block.headerEnd)
                // The first group's range holds the header; later ones repeat it in the body.
                var groupStart = leadStart, groupTokens = headerTokens, first = true
                var rowStart = block.headerEnd
                for rowEnd in block.rowEnds where rowEnd > block.headerEnd {
                    let t = tokens(rowStart, rowEnd)
                    let hasRows = groupTokens > (first ? headerTokens : 0)
                    if hasRows, groupTokens + t + (first ? 0 : headerTokens) > maxTokens {
                        emit(start: groupStart, end: rowStart, tokens: groupTokens + (first ? 0 : headerTokens), isTable: true,
                             startsAtHeading: first && lead, extraPrefix: first ? nil : headerText)
                        first = false
                        groupStart = rowStart
                        groupTokens = 0
                    }
                    groupTokens += t
                    rowStart = rowEnd
                }
                emit(start: groupStart, end: block.end, tokens: groupTokens + (first ? 0 : headerTokens), isTable: true,
                     startsAtHeading: first && lead, extraPrefix: first ? nil : headerText)
            case .text:
                let t = tokens(block.start, block.end)
                if t > maxTokens {
                    // A paragraph longer than a chunk: cut at sentence ends
                    // near the target, else at whitespace.
                    for piece in split(s, block.start, block.end) {
                        add(start: piece.start, end: piece.end, tokens: piece.tokens)
                    }
                } else {
                    // End the current chunk when it is big enough and this
                    // paragraph would take it past the middle of the range.
                    if let c = current, c.tokens >= minTokens, c.tokens + t > (minTokens + maxTokens) / 2 { flush() }
                    add(start: block.start, end: block.end, tokens: t)
                }
            }
        }
        flush()
    }

    /// Pieces of at most `maxTokens`, cut after a sentence end once past
    /// `minTokens`, else at the last whitespace, else hard.
    private func split(_ s: [Unicode.Scalar], _ start: Int, _ end: Int) -> [(start: Int, end: Int, tokens: Int)] {
        var out: [(start: Int, end: Int, tokens: Int)] = []
        var a = start
        while a < end {
            var words = 0, inWord = false, cyrillic = 0, latin = 0
            var i = a, lastSentence = -1, lastSpace = -1
            while i < end {
                let u = s[i]
                let space = u.properties.isWhitespace
                if !space && !inWord { words += 1 }
                inWord = !space
                if (0x0400...0x04FF).contains(u.value) { cyrillic += 1 } else { latin += 1 }
                let tokens = max(words, (latin + 3) / 4 + (cyrillic + 2) / 3)
                if tokens > maxTokens { break }
                if space {
                    lastSpace = i
                    if i > a, ".!?;…".unicodeScalars.contains(s[i - 1]), tokens >= minTokens { lastSentence = i }
                }
                i += 1
            }
            let cut: Int
            if i >= end {
                cut = end
            } else if lastSentence > a {
                cut = lastSentence
            } else if lastSpace > a {
                cut = lastSpace
            } else {
                cut = max(i, a + 1)
            }
            out.append((a, cut, IndexText.estimatedTokens(Substring(String(String.UnicodeScalarView(s[a..<cut]))).unicodeScalars)))
            a = cut
            while a < end, s[a].properties.isWhitespace { a += 1 }
        }
        return out
    }
}
