import Foundation

/// Legacy .ppt ([MS-PPT]): text from the "PowerPoint Document" stream.
/// The live objects are found through Current User -> UserEditAtom chain ->
/// PersistDirectoryAtom (a .ppt saved with fast-save keeps stale copies of
/// slides; a linear scan would index them too). Per slide: the placeholder
/// text in SlideListWithText after its SlidePersistAtom, plus text boxes
/// inside the slide's drawing (TextCharsAtom / TextBytesAtom); notes from
/// the NotesContainer whose NotesAtom points back at the slide id.
/// If the persist chain is unusable, a linear scan is the fallback.
public enum PPT {
    struct Rec { let ver: Int; let inst: Int; let type: Int; let start: Int; let len: Int }

    static func header(_ s: Data, _ p: Int) -> Rec? {
        guard p >= 0, p + 8 <= s.count else { return nil }
        let vi = CFB.u16(s, p)
        let len = CFB.u32(s, p + 4)
        guard p + 8 + len <= s.count else { return nil }
        return Rec(ver: vi & 0xF, inst: vi >> 4, type: CFB.u16(s, p + 2), start: p + 8, len: len)
    }

    /// Children of a container.
    static func children(_ s: Data, _ r: Rec) -> [Rec] {
        var out: [Rec] = []
        var p = r.start
        while p + 8 <= r.start + r.len, let c = header(s, p), c.start + c.len <= r.start + r.len {
            out.append(c)
            p = c.start + c.len
            if out.count > 1_000_000 { break }
        }
        return out
    }

    static func text(_ s: Data, _ r: Rec) -> String? {
        let d = s.subdata(in: (s.startIndex + r.start)..<(s.startIndex + r.start + r.len))
        var t: String
        switch r.type {
        case 0x0FA0: // TextCharsAtom, UTF-16LE
            let units = stride(from: 0, to: d.count - 1, by: 2).map { UInt16(d[d.startIndex + $0]) | UInt16(d[d.startIndex + $0 + 1]) << 8 }
            t = String(decoding: units, as: UTF16.self)
        case 0x0FA8: // TextBytesAtom: the low bytes of UTF-16 code units, i.e. Latin-1
            t = String(d.map { Character(Unicode.Scalar($0)) })
        default: return nil
        }
        t = t.replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{0B}", with: "\n")
        // "*" alone is a slide-number / date field placeholder.
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "*" ? nil : trimmed
    }

    /// All text atoms under a record, depth-first, bounded.
    static func texts(in s: Data, _ r: Rec, depth: Int = 0) -> [String] {
        if depth > 64 { return [] }
        if let t = text(s, r) { return [t] }
        guard r.ver == 0xF else { return [] }
        return children(s, r).flatMap { texts(in: s, $0, depth: depth + 1) }
    }

    public static func extract(_ data: Data, limits: Limits, emitter: Emitter) throws {
        let cfb = try CFB(data: data)
        guard let s = try cfb.stream("PowerPoint Document") else { throw ExtractError("ppt: no PowerPoint Document stream") }
        if let cu = try cfb.stream("Current User"), cu.count >= 20 {
            let token = CFB.u32(cu, 12)
            if token == 0xF3D1_C4DF { throw ExtractError("ppt: password-protected") }
            if let persist = persistDirectory(s, offsetToCurrentEdit: CFB.u32(cu, 16)) {
                if try structured(s, persist: persist.map, docRef: persist.docRef, limits: limits, emitter: emitter) { return }
            }
        }
        FileHandle.standardError.write("ppt: persist chain unusable, linear scan\n".data(using: .utf8)!)
        try linear(s, limits: limits, emitter: emitter)
    }

    static func persistDirectory(_ s: Data, offsetToCurrentEdit: Int) -> (map: [Int: Int], docRef: Int)? {
        var map: [Int: Int] = [:]
        var edit = offsetToCurrentEdit
        var docRef = -1
        var seen = Set<Int>()
        while edit > 0 || (edit == 0 && seen.isEmpty) {
            guard !seen.contains(edit), seen.count < 10_000, let ue = header(s, edit), ue.type == 0x0FF5, ue.len >= 28 else { break }
            seen.insert(edit)
            if docRef < 0 { docRef = CFB.u32(s, ue.start + 16) }
            let lastEdit = CFB.u32(s, ue.start + 8)
            let pdOff = CFB.u32(s, ue.start + 12)
            if let pd = header(s, pdOff), pd.type == 0x1772 {
                var p = pd.start
                let end = pd.start + pd.len
                while p + 4 <= end {
                    let v = CFB.u32(s, p)
                    let id = v & 0xFFFFF, n = v >> 20
                    p += 4
                    for k in 0..<n where p + 4 <= end {
                        if map[id + k] == nil { map[id + k] = CFB.u32(s, p) }   // newest edit wins
                        p += 4
                    }
                }
            }
            if lastEdit == 0 || lastEdit == edit { break }
            edit = lastEdit
        }
        return map.isEmpty || docRef < 0 ? nil : (map, docRef)
    }

    struct SlideRef { var persist: Int; var slideId: Int; var placeholderTexts: [String] }

    static func slideList(_ s: Data, doc: Rec, instance: Int) -> [SlideRef] {
        var out: [SlideRef] = []
        for c in children(s, doc) where c.type == 0x0FF0 && c.inst == instance {
            for a in children(s, c) {
                if a.type == 0x03F3 {
                    out.append(SlideRef(persist: CFB.u32(s, a.start), slideId: CFB.u32(s, a.start + 12), placeholderTexts: []))
                } else if let t = text(s, a), !out.isEmpty {
                    out[out.count - 1].placeholderTexts.append(t)
                }
            }
        }
        return out
    }

    static func structured(_ s: Data, persist: [Int: Int], docRef: Int, limits: Limits, emitter: Emitter) throws -> Bool {
        guard let docOff = persist[docRef], let doc = header(s, docOff), doc.type == 0x03E8 else { return false }
        let slides = slideList(s, doc: doc, instance: 0)
        let notesRefs = slideList(s, doc: doc, instance: 2)
        // notes by the slide id their NotesAtom names
        var notesBySlide: [Int: [String]] = [:]
        for n in notesRefs {
            guard let off = persist[n.persist], let nc = header(s, off), nc.type == 0x03F0 else { continue }
            let kids = children(s, nc)
            guard let atom = kids.first(where: { $0.type == 0x03F1 }) else { continue }
            let slideId = CFB.u32(s, atom.start)
            var t = n.placeholderTexts
            for k in kids where k.type != 0x03F1 { t += texts(in: s, k) }
            notesBySlide[slideId, default: []] += t
        }
        // An empty presentation is a success with no pages.
        for (i, sl) in slides.enumerated() {
            guard i < limits.maxPages else { break }
            var parts = sl.placeholderTexts
            var notesId = -1
            if let off = persist[sl.persist], let sc = header(s, off), sc.type == 0x03EE {
                for k in children(s, sc) {
                    if k.type == 0x03EF, k.len >= 24 { notesId = CFB.u32(s, k.start + 16) }
                    for t in texts(in: s, k) where !parts.contains(t) { parts.append(t) }
                }
            }
            var text = parts.joined(separator: "\n")
            let notes = (notesBySlide[sl.slideId] ?? []).filter { !$0.isEmpty }
            _ = notesId
            if !notes.isEmpty { text += "\n\nNotes:\n" + notes.joined(separator: "\n") }
            if !emitter.emit(PageOut(page: i + 1, text: text)) { return true }
        }
        return true
    }

    /// Fallback: every SlideContainer in stream order (may include stale copies).
    static func linear(_ s: Data, limits: Limits, emitter: Emitter) throws {
        var p = 0
        var page = 0
        while p + 8 <= s.count, let r = header(s, p) {
            if r.type == 0x03EE {
                page += 1
                if !emitter.emit(PageOut(page: page, text: texts(in: s, r).joined(separator: "\n"))) { return }
            } else if r.type == 0x03E8 {
                // SlideListWithText inside the document container holds placeholder text.
                for c in children(s, r) where c.type == 0x0FF0 && c.inst == 0 {
                    let t = texts(in: s, c).joined(separator: "\n")
                    if !t.isEmpty { page += 1; emitter.emit(PageOut(page: page, text: t, name: "slide list text")) }
                }
            }
            p = r.start + r.len
        }
        if page == 0 { throw ExtractError("ppt: no slides found") }
    }
}
