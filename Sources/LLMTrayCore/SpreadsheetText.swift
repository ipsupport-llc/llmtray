import Foundation

/// Spreadsheets (xlsx, ods) as searchable text: each sheet as rows of cells
/// ("a | b | c"), cut into pages of rows. Every page starts with the sheet's
/// name, its row numbers and the sheet's header row, so a chunk from row 400
/// still says what its columns are.
///
/// Cells show what the spreadsheet shows where the file stores it: shared
/// and inline strings, a formula's last computed value, dates from date
/// formats (xlsx) or the date value (ods). Read through CappedZip; every
/// part it reads passes XMLPartCheck before it is parsed (the others are
/// never inflated or parsed).
public enum SpreadsheetText {
    /// Rows and text per page: a few chunks' worth.
    static let pageRows = 60
    static let pageBytes = 6_000
    /// Cells read per workbook: an empty-looking sheet can declare millions.
    static let maxCells = 4_000_000
    static let maxColumns = 512

    public static func pages(_ data: Data, kind: DocumentKind, caps: ExtractionCaps) throws -> [String] {
        let zip = try CappedZip(data: data, caps: caps)
        let sheets: [Sheet]
        switch kind {
        case .xlsx: sheets = try XLSX.sheets(zip, caps: caps)
        case .ods: sheets = try ODS.sheets(zip, caps: caps)
        default: throw ExtractionError.unsupported(kind.rawValue)
        }
        var pages: [String] = []
        var bytes = 0
        for sheet in sheets {
            for page in paginate(sheet) {
                bytes += page.utf8.count
                if bytes > caps.maxTextBytes { throw ExtractionError.tooLarge(.text) }
                pages.append(page)
                if pages.count > caps.maxPages { throw ExtractionError.tooLarge(.pages) }
            }
        }
        return pages
    }

    struct Sheet {
        var name: String
        /// (row number, cells by column), empty rows left out.
        var rows: [(Int, [String])] = []
    }

    static func line(_ cells: [String]) -> String {
        var cells = cells
        while cells.last?.isEmpty == true { cells.removeLast() }
        return cells.map { $0.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/") }
            .joined(separator: " | ")
    }

    static func paginate(_ sheet: Sheet) -> [String] {
        guard let header = sheet.rows.first else { return [] }
        let headerLine = line(header.1)
        var pages: [String] = []
        var i = 0
        while i < sheet.rows.count {
            var body: [String] = []
            var size = 0
            let first = sheet.rows[i].0
            var last = first
            while i < sheet.rows.count, body.count < pageRows, size < pageBytes {
                let text = line(sheet.rows[i].1)
                body.append(text)
                size += text.utf8.count + 1
                last = sheet.rows[i].0
                i += 1
            }
            var page = "Sheet \"\(sheet.name)\", rows \(first)–\(last)\n"
            if first != header.0 { page += headerLine + "\n" }
            page += body.joined(separator: "\n")
            pages.append(page)
        }
        return pages
    }

    /// Doubles as Excel shows them: 0.30000000000000004 -> 0.3.
    static func number(_ s: String) -> String {
        guard let d = Double(s), d.isFinite else { return s }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(format: "%.15g", d)
    }

    /// What a row adds to the text, as `line` writes it: the parsers stop at
    /// the text cap while reading, before repeated rows pile up.
    static func lineBytes(_ cells: [String]) -> Int {
        let used = (cells.lastIndex { !$0.isEmpty }).map { $0 + 1 } ?? 0
        return cells.prefix(used).reduce(0) { $0 + $1.utf8.count + 3 }
    }

    static func parse(_ data: Data, part: String, caps: ExtractionCaps, delegate: XMLParserDelegate) throws {
        try XMLPartCheck.check(data, part: part, maxDepth: caps.maxXMLDepth)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        if !parser.parse() {
            if let stop = (delegate as? CellCounting)?.stopped { throw stop }
            throw ExtractionError.unreadable("\(part): \(parser.parserError?.localizedDescription ?? "invalid XML")")
        }
    }
}

/// Parsers that stop on the cell cap.
protocol CellCounting: AnyObject {
    var stopped: ExtractionError? { get }
}

// MARK: - xlsx

enum XLSX {
    static func sheets(_ zip: CappedZip, caps: ExtractionCaps) throws -> [SpreadsheetText.Sheet] {
        let workbook = try zip.read("xl/workbook.xml")
        let book = WorkbookParser()
        try SpreadsheetText.parse(workbook, part: "xl/workbook.xml", caps: caps, delegate: book)
        let rels = RelsParser()
        if zip.entry("xl/_rels/workbook.xml.rels") != nil {
            try SpreadsheetText.parse(try zip.read("xl/_rels/workbook.xml.rels"), part: "xl/_rels/workbook.xml.rels", caps: caps, delegate: rels)
        }
        var strings: [String] = []
        if zip.entry("xl/sharedStrings.xml") != nil {
            let shared = SharedStringsParser()
            try SpreadsheetText.parse(try zip.read("xl/sharedStrings.xml"), part: "xl/sharedStrings.xml", caps: caps, delegate: shared)
            strings = shared.strings
        }
        var dateStyles: Set<Int> = []
        if zip.entry("xl/styles.xml") != nil {
            let styles = StylesParser()
            try SpreadsheetText.parse(try zip.read("xl/styles.xml"), part: "xl/styles.xml", caps: caps, delegate: styles)
            dateStyles = styles.dateStyles
        }
        var cells = 0
        var bytes = 0
        var result: [SpreadsheetText.Sheet] = []
        for (name, rid) in book.sheets {
            guard let target = rels.targets[rid] else { continue }
            let path = partPath(target)
            // Chartsheets and missing parts: nothing to index.
            guard path.contains("worksheets/"), zip.entry(path) != nil else { continue }
            let sheet = SheetParser(strings: strings, dateStyles: dateStyles, date1904: book.date1904,
                                    cellsBefore: cells, bytesBefore: bytes, maxBytes: caps.maxTextBytes)
            try SpreadsheetText.parse(try zip.read(path), part: path, caps: caps, delegate: sheet)
            cells = sheet.cells
            bytes = sheet.bytes
            result.append(SpreadsheetText.Sheet(name: name, rows: sheet.rows))
        }
        return result
    }

    /// A workbook relationship target as a part name: relative to xl/, or
    /// absolute from the package root; "." and ".." resolved.
    static func partPath(_ target: String) -> String {
        let joined = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        var parts: [Substring] = []
        for part in joined.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    /// Column letters of a cell reference: "AB12" -> 27 (0-based); "$" is
    /// skipped. Excel has at most 3 letters (XFD): more is not a reference.
    static func column(_ ref: String) -> Int? {
        var n = 0
        var letters = 0
        for ch in ref.uppercased() where ch != "$" {
            guard let v = ch.asciiValue, v >= 65, v <= 90 else { break }
            letters += 1
            if letters > 3 { return nil }
            n = n * 26 + Int(v - 64)
        }
        return letters > 0 ? n - 1 : nil
    }

    /// An Excel serial date as text: 45000 -> 2023-03-15; with a time part,
    /// "... 13:30:05". The 1900 system counts a 1900-02-29 that never was
    /// (serial 60, shown as Excel shows it); serials before it are a day on.
    static func date(_ serial: Double, date1904: Bool) -> String {
        var serial = serial
        if !date1904, serial >= 1, serial < 61 {
            if serial.rounded(.down) == 60 { return "1900-02-29" }
            serial += 1
        }
        let epoch = date1904 ? -2_082_844_800.0 : -2_209_161_600.0  // 1904-01-01, 1899-12-30 (UTC)
        let date = Date(timeIntervalSince1970: epoch + serial * 86_400)
        let frac = serial - serial.rounded(.down)
        let f = frac < 1e-9 ? dayFormat : (serial < 1 ? timeFormat : dateTimeFormat)
        return f.string(from: date)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }
    private static let dayFormat = formatter("yyyy-MM-dd")
    private static let timeFormat = formatter("HH:mm:ss")
    private static let dateTimeFormat = formatter("yyyy-MM-dd HH:mm:ss")

    final class WorkbookParser: NSObject, XMLParserDelegate {
        var sheets: [(String, String)] = []
        var date1904 = false
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String]) {
            let local = e.split(separator: ":").last.map(String.init) ?? e
            if local == "sheet", let name = a["name"], let rid = a["r:id"] ?? a.first(where: { $0.key.hasSuffix(":id") })?.value {
                sheets.append((name, rid))
            } else if local == "workbookPr", let v = a["date1904"] {
                date1904 = v == "1" || v.lowercased() == "true"
            }
        }
    }

    final class RelsParser: NSObject, XMLParserDelegate {
        var targets: [String: String] = [:]
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String]) {
            if e.hasSuffix("Relationship"), let id = a["Id"], let target = a["Target"] { targets[id] = target }
        }
    }

    final class SharedStringsParser: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var inText = false
        private var phonetic = 0
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String]) {
            switch e {
            case "si": current = ""
            case "rPh": phonetic += 1
            case "t": inText = phonetic == 0
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inText { current += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
            switch e {
            case "si": strings.append(current)
            case "rPh": phonetic -= 1
            case "t": inText = false
            default: break
            }
        }
    }

    /// The cell styles (cellXfs indexes) whose number format is a date or time.
    final class StylesParser: NSObject, XMLParserDelegate {
        var dateStyles: Set<Int> = []
        private var customDate: Set<Int> = []
        private var inXfs = false
        private var xf = 0
        static let builtinDates: Set<Int> = Set(14...22).union(27...36).union(45...47).union(50...58)
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String]) {
            switch e {
            case "numFmt":
                if let id = a["numFmtId"].flatMap(Int.init), let code = a["formatCode"], Self.isDate(code) { customDate.insert(id) }
            case "cellXfs": inXfs = true; xf = 0
            case "xf" where inXfs:
                if let id = a["numFmtId"].flatMap(Int.init), Self.builtinDates.contains(id) || customDate.contains(id) {
                    dateStyles.insert(xf)
                }
                xf += 1
            default: break
            }
        }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
            if e == "cellXfs" { inXfs = false }
        }
        /// A format code with date/time parts outside quotes and [brackets].
        static func isDate(_ code: String) -> Bool {
            var plain = ""
            var quote = false
            var bracket = false
            for ch in code {
                if ch == "\"" { quote.toggle(); continue }
                if !quote && ch == "[" { bracket = true; continue }
                if !quote && ch == "]" { bracket = false; continue }
                if !quote && !bracket { plain.append(ch) }
            }
            let lower = plain.lowercased()
            return lower.contains("y") || lower.contains("d") || lower.contains("h") || (lower.contains("m") && lower.contains("s"))
                || (lower.contains("m") && !lower.contains("0") && !lower.contains("#"))
        }
    }

    final class SheetParser: NSObject, XMLParserDelegate, CellCounting {
        let strings: [String]
        let dateStyles: Set<Int>
        let date1904: Bool
        var rows: [(Int, [String])] = []
        var cells: Int
        var bytes: Int
        let maxBytes: Int
        var stopped: ExtractionError?
        private var phonetic = 0
        private var rowNumber = 0
        private var row: [String] = []
        private var col = 0
        private var type = "n"
        private var style = 0
        private var value = ""
        private var inValue = false
        private var inInline = false

        init(strings: [String], dateStyles: Set<Int>, date1904: Bool, cellsBefore: Int, bytesBefore: Int = 0, maxBytes: Int = .max) {
            self.strings = strings
            self.dateStyles = dateStyles
            self.date1904 = date1904
            self.cells = cellsBefore
            self.bytes = bytesBefore
            self.maxBytes = maxBytes
        }

        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String]) {
            switch e {
            case "row":
                rowNumber = a["r"].flatMap(Int.init) ?? rowNumber + 1
                row = []
                col = 0
            case "c":
                col = a["r"].flatMap(XLSX.column) ?? col
                type = a["t"] ?? "n"
                style = a["s"].flatMap(Int.init) ?? 0
                value = ""
            case "v": inValue = true
            case "is": inInline = true
            case "rPh": phonetic += 1
            case "t" where inInline: inValue = phonetic == 0
            default: break
            }
        }

        func parser(_ p: XMLParser, foundCharacters s: String) { if inValue { value += s } }

        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
            switch e {
            case "v", "t": inValue = false
            case "is": inInline = false
            case "rPh": phonetic -= 1
            case "c":
                cells += 1
                if cells > SpreadsheetText.maxCells { stopped = .tooLarge(.text); p.abortParsing(); return }
                let text = display()
                if !text.isEmpty, col < SpreadsheetText.maxColumns {
                    if row.count <= col { row += Array(repeating: "", count: col - row.count + 1) }
                    row[col] = text
                }
                col += 1
            case "row":
                if row.contains(where: { !$0.isEmpty }) {
                    bytes += SpreadsheetText.lineBytes(row)
                    if bytes > maxBytes { stopped = .tooLarge(.text); p.abortParsing(); return }
                    rows.append((rowNumber, row))
                }
            default: break
            }
        }

        private func display() -> String {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch type {
            case "s": return Int(v).flatMap { strings.indices.contains($0) ? strings[$0] : nil } ?? ""
            case "inlineStr", "str", "e": return value
            case "b": return v == "1" ? "TRUE" : (v.isEmpty ? "" : "FALSE")
            default:
                guard !v.isEmpty else { return "" }
                if dateStyles.contains(style), let d = Double(v) { return XLSX.date(d, date1904: date1904) }
                return SpreadsheetText.number(v)
            }
        }
    }
}

// MARK: - ods

enum ODS {
    /// Repeats of a row or cell are materialized only when it has content:
    /// trailing "1048576 empty rows" cost nothing.
    static let maxRepeat = 10_000

    /// Spaces one text:s gives at most.
    static let maxSpaces = 64

    static func sheets(_ zip: CappedZip, caps: ExtractionCaps) throws -> [SpreadsheetText.Sheet] {
        let parser = ContentParser(maxBytes: caps.maxTextBytes)
        try SpreadsheetText.parse(try zip.read("content.xml"), part: "content.xml", caps: caps, delegate: parser)
        return parser.sheets
    }

    final class ContentParser: NSObject, XMLParserDelegate, CellCounting {
        var sheets: [SpreadsheetText.Sheet] = []
        var stopped: ExtractionError?
        let maxBytes: Int
        private var bytes = 0
        private var cells = 0
        private var sheet: SpreadsheetText.Sheet?
        private var rowNumber = 0
        private var rowRepeat = 1
        private var row: [String] = []
        private var cellRepeat = 1
        private var cellValue: String?
        private var cellText: [String] = []
        private var paragraph = ""
        private var inParagraph = 0
        private var inCell = false
        private var numberValue: String?

        init(maxBytes: Int = .max) { self.maxBytes = maxBytes }

        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String]) {
            switch e {
            case "table:table":
                sheet = SpreadsheetText.Sheet(name: a["table:name"] ?? "Sheet \(sheets.count + 1)")
                rowNumber = 0
            case "table:table-row":
                rowRepeat = max(1, a["table:number-rows-repeated"].flatMap(Int.init) ?? 1)
                row = []
            case "table:table-cell", "table:covered-table-cell":
                inCell = true
                cellRepeat = max(1, a["table:number-columns-repeated"].flatMap(Int.init) ?? 1)
                cellText = []
                numberValue = nil
                switch a["office:value-type"] {
                case "date": cellValue = a["office:date-value"].map { $0.replacingOccurrences(of: "T", with: " ") }
                case "boolean": cellValue = a["office:boolean-value"].map { $0 == "true" ? "TRUE" : "FALSE" }
                case "float", "percentage", "currency":
                    cellValue = nil
                    numberValue = a["office:value"].map(SpreadsheetText.number)
                default: cellValue = nil
                }
            case "text:p", "text:h":
                if inCell { inParagraph += 1; paragraph = "" }
            case "text:s" where inParagraph > 0:
                paragraph += String(repeating: " ", count: min(ODS.maxSpaces, max(1, a["text:c"].flatMap(Int.init) ?? 1)))
            case "text:tab" where inParagraph > 0: paragraph += "\t"
            case "text:line-break" where inParagraph > 0: paragraph += " "
            default: break
            }
        }

        func parser(_ p: XMLParser, foundCharacters s: String) { if inParagraph > 0 { paragraph += s } }

        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
            switch e {
            case "text:p", "text:h":
                if inParagraph > 0 { inParagraph -= 1; cellText.append(paragraph) }
            case "table:table-cell", "table:covered-table-cell":
                inCell = false
                var text = cellValue ?? cellText.joined(separator: " ")
                if text.isEmpty, let numberValue { text = numberValue }
                if text.utf8.count > maxBytes { stopped = .tooLarge(.text); p.abortParsing(); return }
                // Only the columns still in the row's range are built.
                let room = max(0, SpreadsheetText.maxColumns - row.count)
                let n = min(cellRepeat, room)
                cells += text.isEmpty ? 1 : n
                if cells > SpreadsheetText.maxCells { stopped = .tooLarge(.text); p.abortParsing(); return }
                row += Array(repeating: text, count: n)
            case "table:table-row":
                let hasContent = row.contains { !$0.isEmpty }
                if hasContent {
                    let line = SpreadsheetText.lineBytes(row)
                    let filled = row.filter { !$0.isEmpty }.count
                    for k in 0..<min(rowRepeat, ODS.maxRepeat) {
                        bytes += line
                        cells += filled
                        if bytes > maxBytes || cells > SpreadsheetText.maxCells {
                            stopped = .tooLarge(.text); p.abortParsing(); return
                        }
                        sheet?.rows.append((rowNumber + 1 + k, row))
                    }
                }
                rowNumber += rowRepeat
            case "table:table":
                if let sheet { sheets.append(sheet) }
                sheet = nil
            default: break
            }
        }
    }
}
