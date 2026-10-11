import Foundation

/// `make_document` with `changes` (adr/0020, "Changing a document"): an
/// earlier document of the chat made again with only the sections the model
/// sent, the rest taken from that document's call. A small model rewriting
/// a long document drops or changes parts it wasn't asked to; sending one
/// section is faster and leaves the others as they were.
public enum DocumentEdit {
    public struct Problem: Error, Equatable, Sendable {
        public let text: String
    }

    /// A call with `changes` as the whole call it means: the earlier
    /// document it changes (the one of its title, else the latest; `documents`
    /// oldest first, each its title and call as JSON) with those sections.
    /// A call with content too is that content; one without changes is as
    /// it came. Also notes for the answer, and the earlier document's title
    /// and content (what it already had isn't held against the change).
    public static func resolve(_ arguments: [String: Any], documents: [(title: String, arguments: String)])
        -> Result<([String: Any], [String], (title: String, content: String)?), Problem> {
        var values = arguments
        let changes = (values.removeValue(forKey: "changes") as? [[String: Any]]) ?? []
        guard !changes.isEmpty else { return .success((values, [], nil)) }
        if !((values["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .success((values, ["The changes were set aside: the whole content was given."], nil))
        }
        guard let k = pick(title: values["title"] as? String, among: documents.map(\.title)) else {
            return .failure(Problem(text: "make_document: there's no earlier document in this chat to change. Write the whole content."))
        }
        let base = ToolArgumentParser.parse(documents[k].arguments, schema: DocumentSpec.schema).values
        return apply(arguments, to: base).map { ($0.values, $0.adjusted, (documents[k].title, (base["content"] as? String) ?? "")) }
    }

    /// The earlier document a call changes: the latest one whose title is
    /// the call's, else the latest. `titles` oldest first.
    public static func pick(title: String?, among titles: [String]) -> Int? {
        guard !titles.isEmpty else { return nil }
        if let title, case let wanted = normalized(title), !wanted.isEmpty,
           let i = titles.lastIndex(where: { normalized($0) == wanted }) {
            return i
        }
        return titles.count - 1
    }

    /// The whole call to make: `base` (the earlier call's values, as the
    /// parser read them) with `call`'s changes, title, style and charts.
    /// The result has no `changes`: it is what Make again and a later
    /// change start from. A section that isn't there is a problem, the
    /// headings listed, and nothing is made.
    public static func apply(_ call: [String: Any], to base: [String: Any]) -> Result<(values: [String: Any], adjusted: [String]), Problem> {
        var values = base
        values.removeValue(forKey: "changes")
        var adjusted: [String] = []
        let baseTitle = (base["title"] as? String) ?? ""
        if let title = call["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values["title"] = title
        }
        if let style = call["style"] as? String { values["style"] = style }
        if let sent = call["charts"] as? [[String: Any]], !sent.isEmpty {
            // A chart of the same id is replaced, a new one added.
            var charts = (base["charts"] as? [[String: Any]]) ?? []
            for chart in sent {
                let id = (chart["id"] as? String) ?? ""
                if let i = charts.firstIndex(where: { ($0["id"] as? String) == id }) { charts[i] = chart } else { charts.append(chart) }
            }
            values["charts"] = charts
        }
        var lines = DocumentHTML.lines((base["content"] as? String) ?? "")
        let changes = (call["changes"] as? [[String: Any]]) ?? []
        guard changes.count <= DocumentSpec.Limits.changes else {
            return .failure(Problem(text: "make_document: at most \(DocumentSpec.Limits.changes) changes at once; write the whole content instead."))
        }
        for change in changes {
            let text = ((change["content"] as? String) ?? "").trimmingCharacters(in: .newlines)
            let new = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : DocumentHTML.lines(text)
            let sections = Self.sections(lines)
            if let name = nonEmpty(change["section"]) {
                let s: Section
                switch find(name, in: sections) {
                case .one(let found): s = found
                case .none: return .failure(missing(name, baseTitle, sections))
                case .several(let all): return .failure(ambiguous(name, all))
                }
                if new.isEmpty {
                    lines.replaceSubrange(s.start..<s.end, with: [])
                } else if let first = new.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                          DocumentHTML.Converter.heading(first.trimmingCharacters(in: .whitespaces)) != nil {
                    lines.replaceSubrange(s.start..<s.end, with: new + [""])
                } else {
                    // The body only: the section keeps its heading.
                    lines.replaceSubrange(s.start..<s.end, with: [lines[s.start], ""] + new + [""])
                }
            } else if let name = nonEmpty(change["after"]) {
                let s: Section
                switch find(name, in: sections) {
                case .one(let found): s = found
                case .none: return .failure(missing(name, baseTitle, sections))
                case .several(let all): return .failure(ambiguous(name, all))
                }
                guard !new.isEmpty else { continue }
                lines.insert(contentsOf: [""] + new + [""], at: s.end)
            } else if !new.isEmpty {
                lines += [""] + new
            }
        }
        values["content"] = lines.joined(separator: "\n")
        // A chart whose place went with a removed or rewritten section goes
        // too (else it would turn up at the end); one this call sent stays.
        let dropped = placedCharts((base["content"] as? String) ?? "").subtracting(placedCharts(values["content"] as? String ?? ""))
        let sentIDs = Set(((call["charts"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
        if !dropped.isEmpty, let charts = values["charts"] as? [[String: Any]] {
            values["charts"] = charts.filter { c in
                guard let id = c["id"] as? String else { return true }
                return !dropped.contains(id) || sentIDs.contains(id)
            }
        }
        if ((values["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            adjusted.append("Every section was removed.")
        }
        return .success((values, adjusted))
    }

    /// The charts a content places (`![…](chart:<id>)`).
    static func placedCharts(_ content: String) -> Set<String> {
        var ids = Set<String>()
        _ = DocumentHTML.body(markdown: content) { ref in
            if case .chart(let id) = ref { ids.insert(id) }
            return nil
        }
        return ids
    }

    /// A section: its heading's line, its level, and the line after it
    /// (the next heading of its level or above, or the end). Headings in
    /// fenced code aren't headings.
    struct Section {
        var title: String
        var level: Int
        var start: Int
        var end: Int
    }

    static func sections(_ lines: [String]) -> [Section] {
        var heads: [(title: String, level: Int, line: Int)] = []
        var fence: String?
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if t.hasPrefix(open) { fence = nil }
                continue
            }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { fence = String(t.prefix(3)); continue }
            if let (level, text) = DocumentHTML.Converter.heading(t) { heads.append((text, level, i)) }
        }
        return heads.enumerated().map { n, h in
            let end = heads[(n + 1)...].first { $0.level <= h.level }?.line ?? lines.count
            return Section(title: h.title, level: h.level, start: h.line, end: end)
        }
    }

    enum Match {
        case one(Section)
        case none
        /// More than one heading fits: never a guess.
        case several([Section])
    }

    /// The section a name means: the same heading, then the same without
    /// its number ("2. Costs" for "Costs"), then the heading that contains
    /// it -- the first step with any match decides, and two matches there
    /// are a question back, not the first of them.
    static func find(_ name: String, in sections: [Section]) -> Match {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return .none }
        let bare = unnumbered(wanted)
        for step in [{ (s: Section) in normalized(s.title) == wanted },
                     { (s: Section) in unnumbered(normalized(s.title)) == bare },
                     { (s: Section) in normalized(s.title).contains(bare) }] {
            let found = sections.filter(step)
            if found.count == 1 { return .one(found[0]) }
            if found.count > 1 { return .several(found) }
        }
        return .none
    }

    static func ambiguous(_ name: String, _ sections: [Section]) -> Problem {
        let list = sections.prefix(10).map { "\"\($0.title)\"" }.joined(separator: ", ")
        return Problem(text: "make_document: several sections fit \"\(name)\": \(list). Give the heading exactly as written.")
    }

    static func missing(_ name: String, _ title: String, _ sections: [Section]) -> Problem {
        let list = sections.prefix(40).map(\.title).map { "\"\($0)\"" }.joined(separator: ", ")
        return Problem(text: "make_document: there's no section \"\(name)\" in \"\(title)\"."
            + (list.isEmpty ? " It has no headings: give the whole content instead."
                            : " Its sections: \(list). Use one of them, or leave \"section\" out to add one at the end."))
    }

    static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    /// Without the Markdown around it, its case or its extra spaces.
    static func normalized(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t.removeFirst() }
        t = DocumentHTML.Converter.plain(t).replacingOccurrences(of: "_", with: "")
        return t.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "2. costs", "2) costs", "iv. costs" without the number.
    static func unnumbered(_ s: String) -> String {
        guard let space = s.firstIndex(of: " ") else { return s }
        let head = s[..<space]
        let marker = head.dropLast(head.hasSuffix(".") || head.hasSuffix(")") ? 1 : 0)
        let numeric = marker.contains(where: \.isNumber) && marker.allSatisfy { $0.isNumber || $0 == "." }
        let roman = !marker.isEmpty && marker.count < head.count && marker.allSatisfy { "ivxlc".contains($0) }
        guard numeric || roman else { return s }
        return String(s[s.index(after: space)...])
    }
}
