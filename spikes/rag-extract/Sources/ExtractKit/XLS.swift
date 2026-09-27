import Foundation

/// Legacy .xls: the Workbook (BIFF8) or Book (BIFF5/7) stream of a CFB,
/// read record by record the way xlrd does -- shared strings (SST +
/// CONTINUE), LABELSST, LABEL, NUMBER, RK, MULRK, FORMULA cached results
/// (+ STRING), BOOLERR; XF/FORMAT/DATEMODE for dates; CODEPAGE for BIFF5.
/// Formulas are not evaluated (the cached value is what Excel last saw).
public enum XLS {
    struct Rec { let type: Int; let data: Data; let offset: Int }

    /// Iterates records from `start`; stops at the end or a malformed length.
    static func records(_ s: Data, from start: Int) -> AnyIterator<Rec> {
        var p = start
        return AnyIterator {
            guard p + 4 <= s.count else { return nil }
            let t = CFB.u16(s, p), l = CFB.u16(s, p + 2)
            guard p + 4 + l <= s.count else { return nil }
            let r = Rec(type: t, data: s.subdata(in: (s.startIndex + p + 4)..<(s.startIndex + p + 4 + l)), offset: p)
            p += 4 + l
            return r
        }
    }

    /// A reader over a record and its CONTINUE records, for strings that span
    /// them (each continuation of a string's characters starts with a fresh
    /// option byte saying whether the rest is 8- or 16-bit).
    struct Segmented {
        var segs: [Data]
        var si = 0, off = 0
        var atEnd: Bool { si >= segs.count || (si == segs.count - 1 && off >= segs[si].count) }

        mutating func normalize() { while si < segs.count, off >= segs[si].count, si < segs.count - 1 { si += 1; off = 0 } }

        mutating func byte() throws -> UInt8 {
            normalize()
            guard si < segs.count, off < segs[si].count else { throw ExtractError("xls: record overrun") }
            let b = segs[si][segs[si].startIndex + off]
            off += 1
            return b
        }

        mutating func u16() throws -> Int { let a = Int(try byte()); let b = Int(try byte()); return a | b << 8 }
        mutating func u32() throws -> Int { let a = try u16(); let b = try u16(); return a | b << 16 }

        mutating func skip(_ n: Int) throws {
            var n = n
            while n > 0 {
                normalize()
                guard si < segs.count else { throw ExtractError("xls: skip past end") }
                let avail = segs[si].count - off
                if avail == 0 { throw ExtractError("xls: skip past end") }
                let k = min(avail, n)
                off += k
                n -= k
            }
        }

        /// XLUnicodeRichExtendedString (BIFF8 SST form) or plain XLUnicodeString.
        mutating func unicodeString(lengthBytes: Int = 2, richExt: Bool = true) throws -> String {
            let cch = lengthBytes == 2 ? try u16() : Int(try byte())
            var flags = try byte()
            var runs = 0, ext = 0
            if richExt {
                if flags & 0x08 != 0 { runs = try u16() }
                if flags & 0x04 != 0 { ext = try u32() }
            }
            var units: [UInt16] = []
            units.reserveCapacity(cch)
            var left = cch
            while left > 0 {
                if si < segs.count, off >= segs[si].count {
                    // Characters continue in the next CONTINUE record, after a new option byte.
                    guard si + 1 < segs.count else { throw ExtractError("xls: string past end") }
                    si += 1; off = 0
                    flags = try byte()
                }
                let wide = flags & 0x01 != 0
                let seg = segs[si]
                let avail = (seg.count - off) / (wide ? 2 : 1)
                if avail == 0 { throw ExtractError("xls: string cut mid-character") }
                let k = min(avail, left)
                let base = seg.startIndex + off
                if wide {
                    for j in 0..<k { units.append(UInt16(seg[base + 2 * j]) | UInt16(seg[base + 2 * j + 1]) << 8) }
                    off += 2 * k
                } else {
                    for j in 0..<k { units.append(UInt16(seg[base + j])) }
                    off += k
                }
                left -= k
            }
            if runs > 0 { try skip(4 * runs) }
            if ext > 0 { try skip(ext) }
            return String(decoding: units, as: UTF16.self)
        }
    }

    static func rk(_ v: UInt32) -> Double {
        var d: Double
        if v & 2 != 0 {
            d = Double(Int32(bitPattern: v) >> 2)
        } else {
            d = Double(bitPattern: UInt64(v & 0xFFFF_FFFC) << 32)
        }
        if v & 1 != 0 { d /= 100 }
        return d
    }

    static func double(_ d: Data, _ o: Int) -> Double {
        guard o + 8 <= d.count else { return .nan }
        return d.withUnsafeBytes { Double(bitPattern: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self).littleEndian) }
    }

    public static func extract(_ data: Data, limits: Limits, emitter: Emitter) throws {
        let cfb = try CFB(data: data)
        guard let s = try cfb.stream("Workbook") ?? cfb.stream("Book") else { throw ExtractError("xls: no Workbook stream") }

        // Globals.
        var biff8 = true
        var sst: [String] = []
        var sheets: [(name: String, offset: Int, type: Int, hidden: Bool)] = []
        var formats: [Int: String] = [:]
        var xfFormat: [Int] = []
        var date1904 = false
        var encoding: String.Encoding = .windowsCP1252
        var it = records(s, from: 0)
        var pendingSST: [Data]? = nil
        var first = true
        func flushSST() throws {
            guard let segs = pendingSST else { return }
            pendingSST = nil
            var r = Segmented(segs: segs)
            _ = try r.u32()  // total refs
            let unique = try r.u32()
            sst.reserveCapacity(min(unique, 1_000_000))
            for _ in 0..<min(unique, 10_000_000) {
                if r.atEnd { break }
                sst.append(try r.unicodeString())
            }
        }
        while let rec = it.next() {
            if first {
                guard rec.type == 0x0809 || rec.type == 0x0409 || rec.type == 0x0209 else { throw ExtractError("xls: no BOF (not BIFF5/8)") }
                let vers = CFB.u16(rec.data, 0)
                biff8 = vers == 0x0600
                if vers != 0x0600 && vers != 0x0500 { throw ExtractError("xls: BIFF version \(String(vers, radix: 16)) not supported") }
                first = false
                continue
            }
            if rec.type == 0x003C, pendingSST != nil { pendingSST!.append(rec.data); continue }
            try flushSST()
            switch rec.type {
            case 0x002F: throw ExtractError("xls: password-protected (FILEPASS)")
            case 0x0042:
                let cp = CFB.u16(rec.data, 0)
                if cp == 1251 { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue))) }
                else if cp == 1200 || cp == 0x8000 || cp == 1252 { encoding = .windowsCP1252 }
                else {
                    let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(cp))
                    if cf != kCFStringEncodingInvalidId { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
                }
            case 0x0022: date1904 = CFB.u16(rec.data, 0) == 1
            case 0x00FC: pendingSST = [rec.data]
            case 0x041E:
                let id = CFB.u16(rec.data, 0)
                var r = Segmented(segs: [rec.data.subdata(in: rec.data.startIndex + 2..<rec.data.endIndex)])
                if biff8 { formats[id] = try? r.unicodeString(richExt: false) }
                else if let n = try? r.byte() { formats[id] = String(data: rec.data.dropFirst(3).prefix(Int(n)), encoding: encoding) }
            case 0x00E0: xfFormat.append(CFB.u16(rec.data, 2))
            case 0x0085:
                let off = CFB.u32(rec.data, 0)
                let hidden = rec.data.count > 4 && rec.data[rec.data.startIndex + 4] & 3 != 0
                let type = rec.data.count > 5 ? Int(rec.data[rec.data.startIndex + 5]) : 0
                var name = ""
                if biff8 {
                    var r = Segmented(segs: [rec.data.subdata(in: rec.data.startIndex + 6..<rec.data.endIndex)])
                    name = (try? r.unicodeString(lengthBytes: 1, richExt: false)) ?? ""
                } else if rec.data.count > 6 {
                    let n = Int(rec.data[rec.data.startIndex + 6])
                    name = String(data: rec.data.dropFirst(7).prefix(n), encoding: encoding) ?? ""
                }
                sheets.append((name, off, type, hidden))
            case 0x000A: break
            default: break
            }
            if rec.type == 0x000A { break }
        }
        try flushSST()
        func isDate(_ xf: Int) -> Bool {
            guard xf < xfFormat.count else { return false }
            let f = xfFormat[xf]
            return Sheet.builtinDateFormats.contains(f) || (formats[f].map(Sheet.isDateFormat) ?? false)
        }
        func num(_ d: Double, _ xf: Int) -> String { isDate(xf) ? Sheet.date(d, date1904: date1904) : Sheet.number(d) }
        func label(_ d: Data, at o: Int) -> String {
            guard o < d.count else { return "" }
            if biff8 {
                var r = Segmented(segs: [d.subdata(in: d.startIndex + o..<d.endIndex)])
                return (try? r.unicodeString(richExt: false)) ?? ""
            }
            let n = CFB.u16(d, o)
            return String(data: d.dropFirst(o + 2).prefix(n), encoding: encoding) ?? ""
        }

        var page = 0
        for sh in sheets {
            page += 1
            guard sh.type == 0 else { continue }   // charts, VB modules, macro sheets
            var cells: [Int: [Int: String]] = [:]
            var count = 0
            var pendingFormula: (Int, Int)? = nil
            it = records(s, from: sh.offset)
            var firstRec = true
            var stringSegs: [Data]? = nil
            func put(_ r: Int, _ c: Int, _ v: String) {
                guard r < limits.maxSheetRows, c < 16_384 else { return }
                count += 1
                cells[r, default: [:]][c] = v.replacingOccurrences(of: "\n", with: " ")
            }
            func flushString() {
                if let segs = stringSegs, let (r, c) = pendingFormula {
                    var rd = Segmented(segs: segs)
                    put(r, c, (try? rd.unicodeString(richExt: false)) ?? "")
                }
                stringSegs = nil
                pendingFormula = nil
            }
            while let rec = it.next() {
                if firstRec { firstRec = false; if rec.type != 0x0809 && rec.type != 0x0409 && rec.type != 0x0209 { break }; continue }
                let d = rec.data
                if rec.type == 0x003C, stringSegs != nil { stringSegs!.append(d); continue }
                if stringSegs != nil { flushString() }
                let row = CFB.u16(d, 0), col = CFB.u16(d, 2), xf = CFB.u16(d, 4)
                switch rec.type {
                case 0x00FD: let i = CFB.u32(d, 6); put(row, col, i < sst.count ? sst[i] : "")
                case 0x0204, 0x00D6: put(row, col, label(d, at: 6))
                case 0x0203: put(row, col, num(double(d, 6), xf))
                case 0x027E: put(row, col, num(rk(UInt32(CFB.u32(d, 6))), xf))
                case 0x00BD:
                    var o = 4
                    var c = col
                    while o + 6 <= d.count - 2 {
                        put(row, c, num(rk(UInt32(CFB.u32(d, o + 2))), CFB.u16(d, o)))
                        o += 6; c += 1
                    }
                case 0x0006:
                    if d.count >= 14, CFB.u16(d, 12) == 0xFFFF {
                        switch d[d.startIndex + 6] {
                        case 0: pendingFormula = (row, col)          // STRING record follows
                        case 1: put(row, col, d[d.startIndex + 8] != 0 ? "TRUE" : "FALSE")
                        case 2: put(row, col, "#ERR")
                        default: break
                        }
                    } else {
                        put(row, col, num(double(d, 6), xf))
                    }
                case 0x0207: if pendingFormula != nil { stringSegs = [d] }
                case 0x0205:
                    if d.count >= 8 {
                        let v = d[d.startIndex + 6], isErr = d[d.startIndex + 7] != 0
                        put(row, col, isErr ? "#ERR" : (v != 0 ? "TRUE" : "FALSE"))
                    }
                default: break
                }
                if rec.type == 0x000A { break }
            }
            if stringSegs != nil { flushString() }
            let rows = cells.keys.sorted().map { r -> [String] in
                let rc = cells[r]!
                let maxC = rc.keys.max() ?? -1
                return (0...max(0, maxC)).map { rc[$0] ?? "" }
            }
            var p = PageOut(page: page, text: Sheet.render(rows, limits: limits), name: sh.name)
            if count == 0 { p.text = "" }
            if !emitter.emit(p) { return }
        }
    }
}
