import Foundation

/// What a `make_document` call asks for, read and bounded (adr/0020,
/// Hardening 3): the model's numbers are hostile, so every list is capped
/// and every value checked before anything is drawn. A bad chart is left
/// out with a note; the rest of the document is made.
public struct DocumentSpec: Equatable, Sendable {
    public struct Chart: Equatable, Sendable {
        public enum Kind: String, Sendable, CaseIterable { case bar, line, pie }
        public struct Series: Equatable, Sendable {
            public var name: String
            public var values: [Double]
            /// Each value's x, for a series drawn from a formula; empty for
            /// values placed at the labels.
            public var xs: [Double] = []
        }
        public var id: String
        public var kind: Kind
        public var title: String
        public var labels: [String]
        public var series: [Series]
        public var unit: String
        /// The x range a formula was asked for: the axis, gaps and all.
        public var range: [Double] = []
    }

    public var title: String
    public var content: String
    public var style: String
    public var charts: [Chart]
    /// What was left out and why, for the tool's answer.
    public var notes: [String]

    public enum Limits {
        public static let contentCharacters = 200_000
        public static let charts = 8
        public static let series = 12
        public static let points = 500
        /// Points a formula is computed at across its range.
        public static let formulaPoints = 101
        public static let formulaCharacters = 200
        public static let titleCharacters = 200
        public static let labelCharacters = 80
        public static let idCharacters = 40
        public static let pictures = 30
    }

    /// The tool's declaration (adr/0020, "One tool").
    public static let schema = ToolSchema(
        "make_document",
        "Make a PDF document from Markdown the user asked for (a report, letter, notes, invoice). The app lays it out; the user sees it in the chat.",
        [
            .init("title", .string, required: true, aliases: ["name"]),
            .init("content", .string, "Markdown. Place a chart with ![caption](chart:<id>).", required: true,
                  aliases: ["markdown", "text", "body"]),
            .init("style", .oneOf(DocumentHTML.styles), valueAliases: ["memo": "notes", "bill": "invoice", "cover letter": "letter"]),
            .init("charts", .objects([
                .init("id", .string, required: true),
                // Not required: a formula is a line whatever it's called.
                .init("type", .oneOf(Chart.Kind.allCases.map(\.rawValue)),
                      aliases: ["kind"], valueAliases: ["column": "bar", "bars": "bar", "lines": "line", "donut": "pie"]),
                .init("title", .string),
                .init("labels", .list(.string), aliases: ["categories", "x"]),
                .init("series", .objects([
                    .init("name", .string),
                    .init("values", .list(.number), aliases: ["data", "y"]),
                    .init("formula", .string, "In x, e.g. sin(x): the app computes the line, instead of values.",
                          aliases: ["function", "expression"]),
                ]), required: true, aliases: ["data"]),
                .init("range", .list(.string), "x from and to for a formula, e.g. [\"0\", \"2*pi\"].",
                      aliases: ["x_range", "domain"]),
                .init("unit", .string),
            ])),
        ])

    /// From a call's arguments as `ToolArgumentParser` read them; nil with
    /// the reason when there's nothing to make.
    public static func read(_ values: [String: Any]) -> Result<DocumentSpec, DocumentError> {
        let title = clip(((values["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), Limits.titleCharacters)
        let content = (values["content"] as? String) ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.noContent) }
        // Unicode scalars, not characters: a letter with a million combining
        // marks is one character.
        let scalars = content.unicodeScalars.count
        guard scalars <= Limits.contentCharacters else { return .failure(.tooLong(scalars)) }
        var notes: [String] = []
        var charts: [Chart] = []
        var seen = Set<String>()
        let raw = (values["charts"] as? [[String: Any]]) ?? []
        if raw.count > Limits.charts { notes.append("Only the first \(Limits.charts) charts were used.") }
        for (n, item) in raw.prefix(Limits.charts).enumerated() {
            switch chart(item) {
            case .success(let (c, note)):
                if let note { notes.append("Chart \(n + 1): \(note).") }
                if seen.contains(c.id) {
                    notes.append("Chart \(n + 1) left out: the id \"\(c.id)\" is used twice.")
                } else {
                    seen.insert(c.id)
                    charts.append(c)
                }
            case .failure(let reason):
                notes.append("Chart \(n + 1) left out: \(reason.text).")
            }
        }
        return .success(DocumentSpec(title: title.isEmpty ? "Document" : title, content: content,
                                     style: (values["style"] as? String).map(DocumentHTML.styleName) ?? "report",
                                     charts: charts, notes: notes))
    }

    struct ChartProblem: Error { let text: String }

    /// A chart, with a note when something was set aside to draw it.
    static func chart(_ item: [String: Any]) -> Result<(Chart, String?), ChartProblem> {
        let id = ((item["id"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id.count <= Limits.idCharacters,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            // ASCII: the id is part of an llmtray-doc: address, matched as written.
            return .failure(ChartProblem(text: "its id must be ASCII letters, digits, - or _"))
        }
        let rawSeries = (item["series"] as? [[String: Any]]) ?? []
        let formulas = rawSeries.contains { $0["formula"] is String }
        // A formula is a line; a model may well call it a plot of any type.
        guard let kind = formulas ? .line : (item["type"] as? String).flatMap(Chart.Kind.init(rawValue:)) else {
            return .failure(ChartProblem(text: "its type must be bar, line or pie"))
        }
        var labels = ((item["labels"] as? [Any]) ?? []).map { clip(String(describing: $0), Limits.labelCharacters) }
        guard !rawSeries.isEmpty else { return .failure(ChartProblem(text: "it has no series")) }
        guard rawSeries.count <= Limits.series else { return .failure(ChartProblem(text: "more than \(Limits.series) series")) }
        var series: [Chart.Series] = []
        if formulas {
            guard rawSeries.allSatisfy({ $0["formula"] is String }) else {
                return .failure(ChartProblem(text: "every series needs a formula once one has"))
            }
            let range: (Double, Double)
            switch formulaRange(item["range"]) {
            case .success(let r): range = r
            case .failure(let problem): return .failure(problem)
            }
            for s in rawSeries {
                switch formulaSeries((s["formula"] as? String) ?? "", range) {
                case .success(let (xs, values)):
                    series.append(Chart.Series(name: clip((s["name"] as? String) ?? (s["formula"] as? String) ?? "", Limits.labelCharacters),
                                               values: values, xs: xs))
                case .failure(let problem): return .failure(problem)
                }
            }
            return .success((Chart(id: id, kind: kind, title: clip((item["title"] as? String) ?? "", Limits.titleCharacters),
                                   labels: [], series: series, unit: clip((item["unit"] as? String) ?? "", 20),
                                   range: [range.0, range.1]), nil))
        }
        for s in rawSeries {
            let values = ((s["values"] as? [Any]) ?? []).compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) }
            guard !values.isEmpty else { return .failure(ChartProblem(text: "a series has no values")) }
            guard values.count <= Limits.points else { return .failure(ChartProblem(text: "more than \(Limits.points) points")) }
            guard values.allSatisfy({ $0.isFinite && abs($0) < 1e15 }) else {
                return .failure(ChartProblem(text: "a value isn't a finite number"))
            }
            series.append(Chart.Series(name: clip((s["name"] as? String) ?? "", Limits.labelCharacters), values: values))
        }
        let count = series[0].values.count
        guard series.allSatisfy({ $0.values.count == count }) else {
            return .failure(ChartProblem(text: "its series have different lengths"))
        }
        // The numbers are what the chart is for: labels that don't match
        // them give way to point numbers rather than losing the chart.
        var note: String?
        if !labels.isEmpty, labels.count != count {
            note = "its \(labels.count) labels didn't match \(count) values, so the points are numbered"
            labels = []
        }
        if kind == .pie {
            guard series.count == 1 else { return .failure(ChartProblem(text: "a pie has one series")) }
            guard series[0].values.allSatisfy({ $0 >= 0 }), series[0].values.contains(where: { $0 > 0 }) else {
                return .failure(ChartProblem(text: "a pie needs values of zero or more, not all zero"))
            }
        }
        return .success((Chart(id: id, kind: kind, title: clip((item["title"] as? String) ?? "", Limits.titleCharacters),
                               labels: labels.isEmpty ? (1...count).map(String.init) : labels,
                               series: series, unit: clip((item["unit"] as? String) ?? "", 20)), note))
    }

    /// A formula's x range: two numbers or expressions ("2*pi"), -10...10
    /// when not given.
    static func formulaRange(_ raw: Any?) -> Result<(Double, Double), ChartProblem> {
        guard let list = raw as? [Any], !list.isEmpty else { return .success((-10, 10)) }
        let ends = list.prefix(3).map { v -> Double? in
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            // Scalars: a letter with a million combining marks is one character.
            guard let text = v as? String, text.unicodeScalars.count <= Limits.formulaCharacters else { return nil }
            return try? Calculator.evaluate(text)
        }
        guard ends.count == 2, let from = ends[0], let to = ends[1], from.isFinite, to.isFinite, from < to,
              to - from < 1e12 else {
            return .failure(ChartProblem(text: "its range must be two numbers, from less than to"))
        }
        return .success((from, to))
    }

    /// The formula at evenly spaced x across the range; the points where it
    /// has no value (a log below zero, tan at its pole) are left out.
    static func formulaSeries(_ formula: String, _ range: (Double, Double)) -> Result<([Double], [Double]), ChartProblem> {
        guard !formula.trimmingCharacters(in: .whitespaces).isEmpty, formula.unicodeScalars.count <= Limits.formulaCharacters else {
            return .failure(ChartProblem(text: "a formula is empty or too long"))
        }
        // The formula's own mistakes (a typo, an unknown name) show at any x.
        do { _ = try Calculator.evaluate(formula, variables: ["x": (range.0 + range.1) / 2]) }
        catch let failure as Calculator.Failure {
            if case .domain = failure {} else { return .failure(ChartProblem(text: "its formula: \(failure.localizedDescription)")) }
        } catch { return .failure(ChartProblem(text: "its formula can't be read")) }
        var xs: [Double] = [], values: [Double] = []
        let n = Limits.formulaPoints
        for i in 0..<n {
            let x = range.0 + (range.1 - range.0) * Double(i) / Double(n - 1)
            guard let y = try? Calculator.evaluate(formula, variables: ["x": x]), abs(y) < 1e15 else { continue }
            xs.append(x)
            values.append(y)
        }
        guard values.count >= 2 else { return .failure(ChartProblem(text: "its formula has no values in the range")) }
        return .success((xs, values))
    }

    /// At most `n` Unicode scalars (not characters: see `read`).
    static func clip(_ s: String, _ n: Int) -> String {
        s.unicodeScalars.count <= n ? s : String(String.UnicodeScalarView(s.unicodeScalars.prefix(n)))
    }
}

public enum DocumentError: Error, Equatable, Sendable {
    case noContent
    case tooLong(Int)

    public var text: String {
        switch self {
        case .noContent: return "make_document: \"content\" is empty. Write the document in Markdown and call again."
        case .tooLong(let n):
            return "make_document: the content is \(n) characters, over the \(DocumentSpec.Limits.contentCharacters) a document can have. Shorten it."
        }
    }
}

/// The PDF's file name from the document's title (adr/0020, Hardening 4):
/// one sanitizer, never a path.
public enum DocumentFileName {
    public static func base(_ title: String) -> String {
        var s = title.precomposedStringWithCanonicalMapping
        s = String(s.unicodeScalars.filter { scalar in
            !(scalar.value < 0x20 || scalar.value == 0x7F || "/:\\".unicodeScalars.contains(scalar))
                && !CharacterSet.newlines.contains(scalar)
        }.map(Character.init))
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.unicodeScalars.count > 80 { s = DocumentSpec.clip(s, 80).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? "Document" : s
    }

    /// The n-th name to try: "Title.pdf", "Title 2.pdf", "Title 3.pdf"…
    public static func candidate(_ base: String, attempt: Int) -> String {
        attempt <= 1 ? "\(base).pdf" : "\(base) \(attempt).pdf"
    }

    /// Creates the file in `directory` under the first free name, never over
    /// anything (`O_CREAT | O_EXCL | O_NOFOLLOW`), mode 0600; the open
    /// descriptor and the name.
    public static func create(in directory: URL, title: String) throws -> (fd: Int32, name: String) {
        let base = base(title)
        for attempt in 1...200 {
            let name = candidate(base, attempt: attempt)
            let path = directory.appendingPathComponent(name).path
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 { return (fd, name) }
            if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw POSIXError(.EEXIST)
    }
}
