import Foundation

/// The documents' looks (adr/0020): fixed CSS in the app, picked by name;
/// the model never sends CSS. System fonts only, so nothing is loaded for
/// them. Page size and margins are the print's (`DocumentJob`); the header
/// and footer are drawn onto the pages afterwards.
public enum DocumentStyles {
    static let base = """
    html { -webkit-print-color-adjust: exact; }
    body { margin: 0; color: #1d1d1f; font: 10.5pt/1.5 -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif;
           -webkit-hyphens: auto; hyphens: auto; overflow-wrap: anywhere; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.1em 0 0.45em; page-break-after: avoid; break-after: avoid; }
    h1 { font-size: 20pt; } h2 { font-size: 15pt; } h3 { font-size: 12.5pt; } h4, h5, h6 { font-size: 11pt; }
    p { margin: 0 0 0.7em; orphans: 3; widows: 3; }
    ul, ol { margin: 0 0 0.7em; padding-left: 1.4em; } li { margin: 0.15em 0; }
    blockquote { margin: 0 0 0.8em; padding: 0.1em 0 0.1em 0.9em; border-left: 3px solid #c7c7cc; color: #3a3a3c; }
    pre { background: #f5f5f7; border-radius: 4px; padding: 0.6em 0.8em; white-space: pre-wrap; font-size: 9pt;
          page-break-inside: avoid; break-inside: avoid; }
    code { font: 9pt ui-monospace, "SF Mono", Menlo, monospace; }
    p code, li code, td code { background: #f5f5f7; border-radius: 3px; padding: 0 0.25em; }
    table { border-collapse: collapse; width: 100%; margin: 0 0 0.9em; font-size: 9.5pt; page-break-inside: auto; }
    tr { page-break-inside: avoid; break-inside: avoid; }
    th, td { border-bottom: 1px solid #d2d2d7; padding: 0.3em 0.5em; text-align: left; vertical-align: top; }
    th { border-bottom: 1.5px solid #86868b; font-weight: 600; }
    th.c, td.c { text-align: center; } th.r, td.r { text-align: right; }
    hr { border: 0; border-top: 1px solid #d2d2d7; margin: 1.2em 0; }
    a { color: #0a58ca; text-decoration: none; }
    .addr { color: #6e6e73; font-size: 8pt; }
    img { max-width: 100%; height: auto; }
    p.figure img { max-height: 8in; width: auto; }
    p.figure { text-align: center; margin: 0.6em 0 0.2em; page-break-inside: avoid; break-inside: avoid; }
    p.caption { text-align: center; color: #6e6e73; font-size: 9pt; margin-bottom: 1em; }
    nav.toc { margin: 0 0 1.5em; padding: 0.6em 0 0.6em; border-top: 1px solid #d2d2d7; border-bottom: 1px solid #d2d2d7; }
    nav.toc ul { list-style: none; padding: 0; margin: 0; } nav.toc li { margin: 0.1em 0; }
    nav.toc li.toc3 { padding-left: 1.2em; font-size: 9.5pt; color: #3a3a3c; }
    """

    static let report = base + """
    h1:first-child { font-size: 24pt; margin-top: 0; }
    h2 { margin-top: 1.6em; border-bottom: 1px solid #d2d2d7; padding-bottom: 0.2em; }
    """

    static let letter = base + """
    body { font: 11pt/1.55 "New York", Georgia, "Times New Roman", serif; }
    h1 { font-size: 16pt; } h2 { font-size: 13pt; }
    p { margin-bottom: 0.9em; }
    """

    static let notes = base + """
    body { font-size: 10pt; line-height: 1.45; }
    h1 { font-size: 17pt; margin-top: 0; } h2 { font-size: 13pt; color: #0a58ca; }
    """

    static let invoice = base + """
    h1 { font-size: 22pt; letter-spacing: 0.02em; margin-top: 0; }
    table { font-size: 10pt; }
    th { background: #f5f5f7; }
    td.r, th.r { font-variant-numeric: tabular-nums; }
    tbody tr:last-child td { font-weight: 600; border-bottom: 1.5px solid #86868b; }
    """

    /// The stylesheet for a style name (the report for any other).
    public static func css(_ style: String) -> String {
        switch DocumentHTML.styleName(style) {
        case "letter": return letter
        case "notes": return notes
        case "invoice": return invoice
        default: return report
        }
    }

    /// A table of contents for a report with at least this many chapters.
    public static let tocFromChapters = 4
}

/// What the render child (`LLMTray --render-document <dir>`) gets: the page
/// already built (our converter's output), the charts to draw, the pictures
/// already decoded into the job folder, and the header text. Written by the
/// app into a fresh folder of its own; the child writes `out.pdf` and
/// `thumb.png` back there.
public struct DocumentJob: Codable, Equatable, Sendable {
    public struct ChartJob: Codable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var title: String
        public var labels: [String]
        public var series: [SeriesJob]
        public var unit: String
        /// A formula's x range [from, to]: the axis.
        public var range: [Double]?
    }
    public struct SeriesJob: Codable, Equatable, Sendable {
        public var name: String
        public var values: [Double]
        /// The values' x for a formula's line; nil: at the labels.
        public var xs: [Double]?
        /// Each point's piece of that line (not joined across).
        public var pieces: [Int]?
    }

    public var title: String
    public var style: String
    public var html: String
    public var charts: [ChartJob]
    /// Picture key (`llmtray-doc://image/<key>`) → file in the job folder.
    public var pictures: [String: String]

    public static let fileName = "job.json"
    public static let output = "out.pdf"
    public static let thumbnail = "thumb.png"

    public enum Limits {
        public static let pages = 200
        public static let pdfBytes = 50 * 1024 * 1024
        public static let seconds = 60.0
        public static let memoryBytes = 1536 * 1024 * 1024
        /// The chart PNG's size in pixels at most (2x of the drawn size).
        public static let chartPixels = (width: 2400, height: 1600)
        public static let thumbnailSide = 400
    }

    public init(title: String, style: String, html: String, charts: [ChartJob], pictures: [String: String]) {
        self.title = title
        self.style = style
        self.html = html
        self.charts = charts
        self.pictures = pictures
    }

    /// The job for a read spec: the page with its charts placed, the ones
    /// the content didn't name at the end, a table of contents for a long
    /// report. `pictureAddress` resolves a project picture's id to its key
    /// in `pictures` (none in this version: every picture is left out).
    public static func make(_ spec: DocumentSpec, pictureKeys: [String: String] = [:]) -> (job: DocumentJob, notes: [String], tooLarge: Bool) {
        let chartIDs = Set(spec.charts.map(\.id))
        var notes: [String] = []
        let body = DocumentHTML.body(markdown: spec.content) { ref in
            switch ref {
            case .chart(let id): return chartIDs.contains(id) ? "llmtray-doc://chart/\(id)" : nil
            case .picture(let id): return pictureKeys[id].map { "llmtray-doc://image/\($0)" }
            }
        }
        var html = body.html
        let placed = Set(body.placed.compactMap { if case .chart(let id) = $0 { return id } else { return nil } })
        for chart in spec.charts where !placed.contains(chart.id) {
            html += DocumentHTML.figure(src: "llmtray-doc://chart/\(chart.id)", caption: chart.title)
        }
        for ref in Self.pictureRefs(spec.content) where pictureKeys[ref] == nil {
            notes.append("Picture \(ref) couldn't be used.")
        }
        let chapters = body.headings.filter { $0.level == 2 }
        let toc = spec.style == "report" && chapters.count >= DocumentStyles.tocFromChapters
            ? body.headings.filter { $0.level == 2 || $0.level == 3 } : []
        let page = DocumentHTML.page(title: spec.title, style: spec.style, body: html, toc: toc)
        let charts = spec.charts.map { c in
            ChartJob(id: c.id, kind: c.kind.rawValue, title: c.title, labels: c.labels,
                     series: c.series.map { SeriesJob(name: $0.name, values: $0.values, xs: $0.xs.isEmpty ? nil : $0.xs,
                                                       pieces: $0.pieces.isEmpty ? nil : $0.pieces) }, unit: c.unit,
                     range: c.range.count == 2 ? c.range : nil)
        }
        let files = Dictionary(uniqueKeysWithValues: pictureKeys.map { ($0.value, $0.value) })
        return (DocumentJob(title: spec.title, style: spec.style, html: page, charts: charts, pictures: files), notes, body.tooLarge)
    }

    /// The project picture ids the content places as images
    /// (`![…](project:<id>)`), once each, in order -- not a mention in code
    /// or a plain link, which placement never resolves.
    public static func pictureRefs(_ content: String) -> [String] {
        var out: [String] = []
        _ = DocumentHTML.body(markdown: content) { ref in
            if case .picture(let id) = ref, !out.contains(id), out.count < DocumentSpec.Limits.pictures * 2 { out.append(id) }
            return nil
        }
        return out
    }
}
