import Foundation

/// Sheets as rows, the header row repeated at the top of every block of
/// `rowsPerBlock` rows, so a chunker can cut at block boundaries ("\n\n")
/// and each chunk still says what its columns are.
public enum Sheet {
    public static func render(_ rows: [[String]], limits: Limits) -> String {
        let rows = rows.map { r -> [String] in
            var r = r
            while let l = r.last, l.isEmpty { r.removeLast() }
            return r
        }.filter { !$0.isEmpty }
        guard let header = rows.first else { return "" }
        let headerLine = header.joined(separator: " | ")
        var out = headerLine
        var inBlock = 0
        for r in rows.dropFirst() {
            if inBlock == limits.rowsPerBlock {
                out += "\n\n" + headerLine
                inBlock = 0
            }
            out += "\n" + r.joined(separator: " | ")
            inBlock += 1
        }
        return out
    }

    /// "C12" -> column 2 (0-based).
    static func column(_ ref: String) -> Int? {
        var col = 0
        var any = false
        for u in ref.utf8 {
            if u >= 0x41 && u <= 0x5A { col = col * 26 + Int(u - 0x40); any = true } else if u >= 0x61 && u <= 0x7A { col = col * 26 + Int(u - 0x60); any = true } else { break }
            if col > 16_384 { return nil }
        }
        return any ? col - 1 : nil
    }

    static func number(_ d: Double) -> String {
        if d.isFinite, d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        var s = String(format: "%.10g", d)
        if s.contains("e") { return s }
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        return s
    }

    /// Excel serial -> ISO date (time kept when not midnight).
    static func date(_ serial: Double, date1904: Bool) -> String {
        guard serial.isFinite, serial > -1, serial < 2_958_466 else { return number(serial) }
        // 1900 system: day 0 = 1899-12-31, with the fake 1900-02-29 (serial 60).
        let base: TimeInterval = date1904 ? -2_082_844_800 : -2_209_161_600  // 1904-01-01 / 1899-12-30 UTC
        let adj = (!date1904 && serial < 61) ? serial + 1 : serial
        let secs = base + (adj * 86_400).rounded()
        let d = Date(timeIntervalSince1970: secs)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        let day = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        if c.hour == 0 && c.minute == 0 && c.second == 0 { return day }
        if serial < 1 { return String(format: "%02d:%02d:%02d", c.hour!, c.minute!, c.second!) }
        return day + String(format: " %02d:%02d", c.hour!, c.minute!)
    }

    static let builtinDateFormats: Set<Int> = [14, 15, 16, 17, 18, 19, 20, 21, 22, 27, 30, 36, 45, 46, 47, 50, 57, 58]

    /// A custom format code is a date if it has d/m/y/h/s outside quotes and brackets.
    static func isDateFormat(_ code: String) -> Bool {
        if code.lowercased().hasPrefix("general") { return false }
        var inQuote = false, inBracket = false, prevBackslash = false
        for ch in code.lowercased() {
            if prevBackslash { prevBackslash = false; continue }
            switch ch {
            case "\\": prevBackslash = true
            case "\"": inQuote.toggle()
            case "[": if !inQuote { inBracket = true }
            case "]": if !inQuote { inBracket = false }
            case "d", "m", "y", "h", "s": if !inQuote && !inBracket { return true }
            case "0", "#", "?": if !inQuote && !inBracket { return false }
            default: break
            }
        }
        return false
    }
}

public enum XLSX {
    public static func extract(_ data: Data, limits: Limits, emitter: Emitter) throws {
        let zip = try ZipArchive(data: data, limits: limits)
        let wbName = "xl/workbook.xml"
        let wb = try zip.read(wbName)
        var sheets: [(name: String, rid: String, hidden: Bool)] = []
        var date1904 = false
        try XMLWalk.walk(wb, part: wbName, limits: limits) { w in
            w.onStart = { name, a in
                if name == "sheet", let n = a["name"] {
                    let rid = a["r:id"] ?? a.first(where: { $0.key.hasSuffix(":id") || $0.key == "id" })?.value ?? ""
                    sheets.append((n, rid, a["state"] == "hidden" || a["state"] == "veryHidden"))
                }
                if name == "workbookPr", let d = a["date1904"] { date1904 = d == "1" || d == "true" }
            }
        }
        let rels = Rels.load(zip, for: wbName, limits: limits)

        // Shared strings: <si> with <t> or rich runs <r><t>; phonetic <rPh> skipped.
        var shared: [String] = []
        if let ssName = rels.values.first(where: { $0.type.hasSuffix("/sharedStrings") })?.target ?? (zip.has("xl/sharedStrings.xml") ? "xl/sharedStrings.xml" : nil) {
            let ss = try zip.read(ssName)
            var cur = "", inT = false, inPh = false
            try XMLWalk.walk(ss, part: ssName, limits: limits) { w in
                w.onStart = { n, _ in if n == "si" { cur = "" } else if n == "t" { inT = true } else if n == "rPh" { inPh = true } }
                w.onEnd = { n in if n == "si" { shared.append(cur) } else if n == "t" { inT = false } else if n == "rPh" { inPh = false } }
                w.onText = { s in if inT && !inPh { cur += s } }
            }
        }

        // Styles: which cellXfs index is a date.
        var dateXf: [Bool] = []
        if zip.has("xl/styles.xml") {
            let st = try zip.read("xl/styles.xml")
            var custom: [Int: String] = [:]
            var inCellXfs = false
            try XMLWalk.walk(st, part: "xl/styles.xml", limits: limits) { w in
                w.onStart = { n, a in
                    if n == "numFmt", let id = a["numFmtId"].flatMap(Int.init), let code = a["formatCode"] { custom[id] = code }
                    if n == "cellXfs" { inCellXfs = true }
                    if n == "xf" && inCellXfs {
                        let id = a["numFmtId"].flatMap(Int.init) ?? 0
                        dateXf.append(Sheet.builtinDateFormats.contains(id) || (custom[id].map(Sheet.isDateFormat) ?? false))
                    }
                }
                w.onEnd = { n in if n == "cellXfs" { inCellXfs = false } }
            }
        }

        for (idx, sh) in sheets.enumerated() {
            guard let part = rels[sh.rid]?.target, !(rels[sh.rid]?.external ?? true) else {
                emitter.emit(PageOut(page: idx + 1, text: "", name: sh.name, error: "xlsx: sheet part not found"))
                continue
            }
            do {
                let xml = try zip.read(part)
                var rows: [[String]] = []
                var row: [String] = []
                var cellCol = 0, nextCol = 0
                var cellType = "n", cellStyle = 0
                var value = "", inV = false, inIsT = false, inIs = false
                var tooMany = false
                try XMLWalk.walk(xml, part: part, limits: limits) { w in
                    w.onStart = { n, a in
                        switch n {
                        case "row": row = []; nextCol = 0
                        case "c":
                            cellCol = a["r"].flatMap(Sheet.column) ?? nextCol
                            cellType = a["t"] ?? "n"
                            cellStyle = a["s"].flatMap(Int.init) ?? 0
                            value = ""
                        case "v": inV = true
                        case "is": inIs = true
                        case "t": if inIs { inIsT = true }
                        default: break
                        }
                    }
                    w.onText = { s in if inV || inIsT { value += s } }
                    w.onEnd = { n in
                        switch n {
                        case "v": inV = false
                        case "t": inIsT = false
                        case "is": inIs = false
                        case "c":
                            var text: String
                            switch cellType {
                            case "s": text = Int(value).flatMap { $0 >= 0 && $0 < shared.count ? shared[$0] : nil } ?? ""
                            case "b": text = value == "1" ? "TRUE" : "FALSE"
                            case "str", "inlineStr", "e": text = value
                            default:
                                if let d = Double(value) {
                                    let isDate = cellStyle < dateXf.count && dateXf[cellStyle]
                                    text = isDate ? Sheet.date(d, date1904: date1904) : Sheet.number(d)
                                } else { text = value }
                            }
                            text = text.replacingOccurrences(of: "\n", with: " ")
                            if cellCol < 16_384 {
                                while row.count < cellCol { row.append("") }
                                if row.count == cellCol { row.append(text) } else { row[cellCol] = text }
                            }
                            nextCol = cellCol + 1
                        case "row":
                            if rows.count < limits.maxSheetRows { rows.append(row) } else { tooMany = true }
                        default: break
                        }
                    }
                }
                var p = PageOut(page: idx + 1, text: Sheet.render(rows, limits: limits), name: sh.name)
                if tooMany { p.truncated = true }
                if !emitter.emit(p) { return }
            } catch {
                emitter.emit(PageOut(page: idx + 1, text: "", name: sh.name, error: "\(error)"))
            }
        }
    }
}

public enum PPTX {
    public static func extract(_ data: Data, limits: Limits, emitter: Emitter) throws {
        let zip = try ZipArchive(data: data, limits: limits)
        let presName = "ppt/presentation.xml"
        let pres = try zip.read(presName)
        var ids: [String] = []
        try XMLWalk.walk(pres, part: presName, limits: limits) { w in
            w.onStart = { n, a in
                if n == "sldId", let rid = a["r:id"] ?? a.first(where: { $0.key.hasSuffix(":id") })?.value { ids.append(rid) }
            }
        }
        let rels = Rels.load(zip, for: presName, limits: limits)
        for (i, rid) in ids.enumerated() {
            guard i < limits.maxPages else { break }
            guard let part = rels[rid]?.target else { continue }
            do {
                var text = try shapesText(zip.read(part), part: part, limits: limits, notes: false)
                let srels = Rels.load(zip, for: part, limits: limits)
                if let np = srels.values.first(where: { $0.type.hasSuffix("/notesSlide") && !$0.external })?.target,
                   let nd = try? zip.read(np) {
                    let notes = try shapesText(nd, part: np, limits: limits, notes: true)
                    if !notes.isEmpty { text += "\n\nNotes:\n" + notes }
                }
                if !emitter.emit(PageOut(page: i + 1, text: text)) { return }
            } catch {
                emitter.emit(PageOut(page: i + 1, text: "", error: "\(error)"))
            }
        }
    }

    /// Paragraph text of every shape (and table cell); in notes, the slide
    /// image, number, header/footer and date placeholders are skipped.
    static func shapesText(_ data: Data, part: String, limits: Limits, notes: Bool) throws -> String {
        var paras: [String] = []
        var shapeParas: [String] = []
        var para = "", inT = false, skipShape = false, spDepth = 0
        try XMLWalk.walk(data, part: part, limits: limits) { w in
            w.onStart = { n, a in
                switch n {
                case "sp", "graphicFrame": spDepth += 1; if spDepth == 1 { shapeParas = []; skipShape = false }
                case "ph": if notes, let t = a["type"], ["sldNum", "sldImg", "hdr", "ftr", "dt"].contains(t) { skipShape = true }
                case "p": para = ""
                case "t": inT = true
                case "br": para += "\n"
                case "tab": para += "\t"
                default: break
                }
            }
            w.onText = { s in if inT { para += s } }
            w.onEnd = { n in
                switch n {
                case "t": inT = false
                case "p":
                    let t = para.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { if spDepth > 0 { shapeParas.append(t) } else { paras.append(t) } }
                case "sp", "graphicFrame":
                    spDepth -= 1
                    if spDepth == 0 && !skipShape { paras += shapeParas }
                default: break
                }
            }
        }
        return paras.joined(separator: "\n")
    }
}
