import AppKit
import Charts
import LLMTrayCore
import PDFKit
import SwiftUI
import WebKit

/// `LLMTray --render-document <dir> [--parent <pid>]` (see LLMTrayApp.init):
/// the child that turns a `DocumentJob` into a PDF (adr/0020), supervised by
/// the app -- its own process group, 60 s, a memory limit, a file-size limit
/// -- so a page that makes WebKit's printing run away ends only this child.
/// Draws the charts, loads the page in a web view that runs no script and
/// loads nothing but `llmtray-doc:`, prints it in an offscreen window,
/// stamps the header and footer with PDFKit, writes a thumbnail, and prints
/// one JSON line: `{"pages": N}` or `{"error": "..."}`.
@MainActor
enum DocumentRenderCLI {
    static func run(arguments: [String]) -> Never {
        guard let i = arguments.firstIndex(of: "--render-document"), i + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: LLMTray --render-document <dir>\n".utf8))
            exit(64)
        }
        ExtractorCLI.exitWithParent(expected: arguments.firstIndex(of: "--parent").flatMap { j in
            j + 1 < arguments.count ? pid_t(arguments[j + 1]) : nil
        })
        // A runaway print stops at the file-size limit (SIGXFSZ) before
        // the parent's own check of the result.
        var limit = rlimit(rlim_cur: rlim_t(DocumentJob.Limits.pdfBytes * 2), rlim_max: rlim_t(DocumentJob.Limits.pdfBytes * 2))
        setrlimit(RLIMIT_FSIZE, &limit)
        let dir = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(DocumentJob.fileName)),
              let job = try? JSONDecoder().decode(DocumentJob.self, from: data) else { finish(error: "no job") }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let renderer = Renderer(job: job, dir: dir)
        renderer.start()
        app.run()
        finish(error: "the app loop ended")
    }

    static func finish(pages: Int) -> Never {
        print("{\"pages\":\(pages)}")
        exit(0)
    }

    static func finish(error: String) -> Never {
        let text = String(data: (try? JSONSerialization.data(withJSONObject: ["error": error])) ?? Data(), encoding: .utf8) ?? "{\"error\":\"?\"}"
        print(text)
        exit(1)
    }

    /// The only resources the page can have, by address: the style, the
    /// charts, the pictures -- built before the page loads.
    final class Resources: NSObject, WKURLSchemeHandler {
        var table: [String: (Data, String)] = [:]

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard let url = task.request.url, let (data, mime) = table[url.absoluteString] else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "*"])!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    /// Every resource load blocked but our scheme's (WebKit's rule regexes
    /// have no `|`: a deny-all with exceptions).
    static let blockRules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^llmtray-doc:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
    """

    final class Renderer: NSObject, WKNavigationDelegate {
        let job: DocumentJob
        let dir: URL
        let resources = Resources()
        var web: WKWebView?
        var window: NSWindow?
        var loaded = false

        init(job: DocumentJob, dir: URL) {
            self.job = job
            self.dir = dir
        }

        func start() {
            resources.table["llmtray-doc://style/\(DocumentHTML.styleName(job.style)).css"] = (Data(DocumentStyles.css(job.style).utf8), "text/css")
            for chart in job.charts {
                guard let png = DocumentRenderCLI.chartPNG(chart) else { continue }
                resources.table["llmtray-doc://chart/\(chart.id)"] = (png, "image/png")
            }
            for (key, file) in job.pictures {
                // Already decoded and re-encoded by the app; a name only.
                guard !file.contains("/"), let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else { continue }
                resources.table["llmtray-doc://image/\(key)"] = (data, file.hasSuffix(".png") ? "image/png" : "image/jpeg")
            }
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "llmtray-doc-render",
                                                                     encodedContentRuleList: DocumentRenderCLI.blockRules) { list, error in
                MainActor.assumeIsolated {
                    guard let list else { DocumentRenderCLI.finish(error: "rules: \(error?.localizedDescription ?? "?")") }
                    self.load(rules: list)
                }
            }
        }

        func load(rules: WKContentRuleList) {
            let config = WKWebViewConfiguration()
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            config.websiteDataStore = .nonPersistent()
            config.setURLSchemeHandler(resources, forURLScheme: "llmtray-doc")
            config.userContentController.add(rules)
            let size = DocumentRenderCLI.paper
            let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
            web.navigationDelegate = self
            self.web = web
            web.loadHTMLString(job.html, baseURL: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            // The initial load only; every other navigation (a frame, a
            // refresh, a click) is refused.
            decisionHandler(!loaded && action.targetFrame?.isMainFrame == true && action.request.url?.scheme == "about" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !loaded else { return }
            loaded = true
            // The charts and pictures decode after the load event: printed
            // before, they're blank. The app's own script waits for them
            // (the page's scripts stay off: this is not one of them).
            webView.callAsyncJavaScript(
                "await Promise.all(Array.from(document.images).map(i => i.decode().catch(() => null))); return document.images.length;",
                arguments: [:], in: nil, in: .defaultClient) { _ in
                    MainActor.assumeIsolated { self.repeatTableHeaders() }
                }
        }

        /// WebKit's print doesn't repeat a table's header on the next page:
        /// a table that runs over is cut where the page ends and goes on as
        /// a table of its own, the header again, from a new page. Where the
        /// pages end is measured with the page laid out as columns a page
        /// high -- the same fragmentation, break rules and all. The app's
        /// own script, as above; if it fails, the page prints as it is.
        func repeatTableHeaders() {
            guard let web else { return }
            // The page is laid out as wide as the view and printed scaled
            // to the paper's width less the margins: a page is that much
            // taller in the layout.
            let size = DocumentRenderCLI.printable
            let width = Double(web.bounds.width)
            web.callAsyncJavaScript(DocumentRenderCLI.tableHeaderScript,
                                    arguments: ["width": width, "height": width * Double(size.height / size.width)],
                                    in: nil, in: .defaultClient) { _ in
                MainActor.assumeIsolated { self.print() }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DocumentRenderCLI.finish(error: "load: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DocumentRenderCLI.finish(error: "load: \(error.localizedDescription)")
        }

        /// WebKit's content process crashed (on this page): no other
        /// callback comes, so say so now rather than at the time limit.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            DocumentRenderCLI.finish(error: "the page crashed the renderer")
        }

        func print() {
            guard let web else { return }
            let raw = dir.appendingPathComponent("raw.pdf")
            let info = NSPrintInfo()
            info.paperSize = DocumentRenderCLI.paper
            info.topMargin = DocumentRenderCLI.margin
            info.bottomMargin = DocumentRenderCLI.margin
            info.leftMargin = DocumentRenderCLI.margin
            info.rightMargin = DocumentRenderCLI.margin
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = raw
            let op = web.printOperation(with: info)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            // In a window, never `run()` on a lone view: that ran away
            // (adr/0020, "Spike and measurement").
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: info.paperSize.width, height: info.paperSize.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = web
            self.window = window
            op.view?.frame = web.bounds
            op.runModal(for: window, delegate: self, didRun: #selector(printed(_:success:contextInfo:)), contextInfo: nil)
        }

        @objc func printed(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            guard success else { DocumentRenderCLI.finish(error: "printing failed") }
            let raw = dir.appendingPathComponent("raw.pdf")
            let out = dir.appendingPathComponent(DocumentJob.output)
            guard let pages = DocumentRenderCLI.stamp(raw, out, title: job.title) else { DocumentRenderCLI.finish(error: "no pages") }
            try? FileManager.default.removeItem(at: raw)
            guard pages <= DocumentJob.Limits.pages else { DocumentRenderCLI.finish(error: "over \(DocumentJob.Limits.pages) pages") }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            guard bytes > 0, bytes <= DocumentJob.Limits.pdfBytes else { DocumentRenderCLI.finish(error: "over 50 MB") }
            DocumentRenderCLI.thumbnail(out, to: dir.appendingPathComponent(DocumentJob.thumbnail))
            DocumentRenderCLI.finish(pages: pages)
        }
    }

    /// The page's margins (the header and footer are stamped into them).
    static let margin: CGFloat = 54

    /// What WebKit lays a page out in: the paper less the margins.
    static var printable: NSSize {
        NSSize(width: paper.width - 2 * margin, height: paper.height - 2 * margin)
    }

    /// Cuts each table where a page ends (`repeatTableHeaders`): the body
    /// as columns of the page's size, each row's column its page; a table
    /// whose rows reach the next page is cut before the first such row, the
    /// rest a new table with the header again that starts a page. One cut
    /// at a time (the layout moves after it), at most a page's worth.
    static let tableHeaderScript = """
    const body = document.body, style = body.getAttribute("style");
    // Columns break at a column, where print breaks at a page.
    const columns = document.createElement("style");
    columns.textContent = "table.cont, table.newpage { break-before: column !important; }";
    document.head.appendChild(columns);
    Object.assign(body.style, { width: width + "px", height: height + "px", columnWidth: width + "px",
                                columnGap: "0px", columnFill: "auto" });
    const origin = body.getBoundingClientRect();
    const page = el => Math.floor((el.getBoundingClientRect().left - origin.left + 1) / width);
    const bottom = el => el.getBoundingClientRect().bottom - origin.top;
    let cuts = 0;
    for (; cuts < 400; cuts++) {
        let cut = false;
        for (const table of document.querySelectorAll("table")) {
            const head = table.tHead, rows = table.tBodies.length ? Array.from(table.tBodies[0].rows) : [];
            if (!head || !head.rows.length || !rows.length) continue;
            // Print lays pages out a little unlike columns (margins at a
            // break): a page is taken as shorter, more so where the page
            // didn't start with a cut of ours.
            const room = height * (table.classList.contains("cont") ? 0.985 : 0.94);
            const first = page(head.rows[0]);
            const k = rows.findIndex(r => page(r) !== first || bottom(r) > room);
            if (k < 0) continue;
            if (k === 0) {
                // The header alone at a page's foot: the table starts the next page.
                if (table.classList.contains("cont") || table.classList.contains("newpage")) continue;
                table.classList.add("newpage");
                cut = true;
                break;
            }
            // The columns as wide as the whole table had them, in both parts.
            const widths = Array.from(head.rows[0].cells).map(c => c.getBoundingClientRect().width);
            Array.from(head.rows[0].cells).forEach((c, i) => { c.style.boxSizing = "border-box"; c.style.width = widths[i] + "px"; });
            const rest = table.cloneNode(false), tbody = document.createElement("tbody");
            rest.appendChild(head.cloneNode(true));
            rest.appendChild(tbody);
            for (const r of rows.slice(k)) tbody.appendChild(r);
            table.classList.add("cut");
            rest.classList.remove("cut", "newpage");
            rest.classList.add("cont");
            table.after(rest);
            cut = true;
            break;
        }
        if (!cut) break;
    }
    columns.remove();
    if (style === null) body.removeAttribute("style"); else body.setAttribute("style", style);
    return cuts;
    """

    /// US Letter or A4 by the Mac's region.
    static var paper: NSSize {
        let metric = Locale.current.measurementSystem != .us
        return metric ? NSSize(width: 595, height: 842) : NSSize(width: 612, height: 792)
    }

    // MARK: Header and footer

    /// Draws the title above and "N / M" below every page, as part of the
    /// page, keeping the link annotations (a CGContext redraw drops them).
    final class StampedPage: PDFPage {
        nonisolated(unsafe) static var title = ""
        nonisolated(unsafe) static var total = 0

        override func draw(with box: PDFDisplayBox, to context: CGContext) {
            super.draw(with: box, to: context)
            let bounds = self.bounds(for: box)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor(white: 0.45, alpha: 1)]
            let number = (document?.index(for: self) ?? 0) + 1
            if number > 1 {
                let title = Self.title.count > 90 ? String(Self.title.prefix(89)) + "…" : Self.title
                (title as NSString).draw(at: CGPoint(x: 54, y: bounds.height - 34), withAttributes: attrs)
            }
            let footer = "\(number) / \(Self.total)" as NSString
            let width = footer.size(withAttributes: attrs).width
            footer.draw(at: CGPoint(x: bounds.width - 54 - width, y: 26), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    final class StampDelegate: NSObject, PDFDocumentDelegate {
        func classForPage() -> AnyClass { StampedPage.self }
    }

    static func stamp(_ raw: URL, _ out: URL, title: String) -> Int? {
        guard let data = try? Data(contentsOf: raw), let count = PDFDocument(data: data)?.pageCount, count > 0 else { return nil }
        StampedPage.title = title
        StampedPage.total = count
        let delegate = StampDelegate()
        guard let doc = PDFDocument(data: data) else { return nil }
        doc.delegate = delegate
        doc.documentAttributes = [PDFDocumentAttribute.titleAttribute: title, PDFDocumentAttribute.creatorAttribute: "LLMTray"]
        guard doc.write(to: out) else { return nil }
        return count
    }

    static func thumbnail(_ pdf: URL, to url: URL) {
        guard let page = PDFDocument(url: pdf)?.page(at: 0) else { return }
        let side = CGFloat(DocumentJob.Limits.thumbnailSide)
        let image = page.thumbnail(of: NSSize(width: side, height: side), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    // MARK: Charts

    static func chartPNG(_ chart: DocumentJob.ChartJob) -> Data? {
        let view = DocumentChartView(chart: chart)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage, image.width <= DocumentJob.Limits.chartPixels.width,
              image.height <= DocumentJob.Limits.chartPixels.height else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}

/// A chart as the document shows it: Swift Charts, light, 500×300 pt.
struct DocumentChartView: View {
    let chart: DocumentJob.ChartJob

    private struct Point: Identifiable {
        let id: Int
        let label: String
        /// A formula's x; nil at a label.
        let x: Double?
        /// A formula's line: its series and piece (not joined across a pole);
        /// by index, so two series of one name stay two lines.
        var line = ""
        let series: String
        let value: Double
    }

    private var points: [Point] {
        var out: [Point] = []
        for (s, series) in chart.series.enumerated() {
            for (i, value) in series.values.enumerated() {
                let label = i < chart.labels.count ? chart.labels[i] : String(i + 1)
                let x = series.xs.flatMap { i < $0.count ? $0[i] : nil }
                var point = Point(id: s * 10_000 + i, label: label, x: x, series: series.name.isEmpty ? "Series \(s + 1)" : series.name, value: value)
                point.line = "\(s)/\(series.pieces.flatMap { i < $0.count ? $0[i] : nil } ?? 0)"
                out.append(point)
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chart.title.isEmpty {
                Text(chart.title).font(.system(size: 13, weight: .semibold))
            }
            content
        }
        .padding(14)
        .frame(width: 500, height: 300)
        .background(Color.white)
    }

    /// Values printed on the marks when there are few enough to read.
    private static let labelledMarks = 24

    private func label(_ value: Double) -> Text {
        Text(DocumentJob.valueLabel(value)).font(.system(size: 9))
    }

    @ViewBuilder private var content: some View {
        let unit = chart.unit.isEmpty ? "Value" : chart.unit
        let several = chart.series.count > 1
        let all = points
        let labelled = all.count <= Self.labelledMarks
        switch chart.kind {
        case "line" where chart.series.contains { $0.xs != nil }:
            // A formula: a smooth line over a number axis, no dots.
            let line = all.filter { $0.x != nil }
            let range = chart.range ?? []
            Chart(line) { p in
                LineMark(x: .value("x", p.x ?? 0), y: .value(unit, p.value),
                         series: .value("Line", p.line))
                    .foregroundStyle(by: .value("Series", p.series))
            }
            // The range the formula was asked for, not rounded out past it;
            // values on the left, where long negative numbers have room.
            .chartXScale(domain: range.count == 2 && range[0] < range[1] ? range[0]...range[1] : 0...1)
            .chartYAxis { AxisMarks(position: .leading) }
            .chartLegend(several ? .visible : .hidden)
            .chartYAxisLabel(chart.unit)
        case "scatter":
            Chart(all.filter { $0.x != nil }) { p in
                PointMark(x: .value("x", p.x ?? 0), y: .value(unit, p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .symbolSize(28)
            }
            // Measurements far from zero: the axes span the points.
            .chartXScale(domain: .automatic(includesZero: false))
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis { AxisMarks(position: .leading) }
            .chartLegend(several ? .visible : .hidden)
            .chartYAxisLabel(chart.unit)
        case "line":
            // Values over the dots of one short line; more would overlap.
            let dots = labelled && !several
            Chart(all) { p in
                LineMark(x: .value("Label", p.label), y: .value(unit, p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                PointMark(x: .value("Label", p.label), y: .value(unit, p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .annotation(position: .top, spacing: 3) { if dots { label(p.value).foregroundStyle(.secondary) } }
            }
            .chartLegend(several ? .visible : .hidden)
            .chartYAxisLabel(chart.unit)
        case "pie":
            // Each slice's share on it, when it's wide enough to hold it.
            let total = all.reduce(0) { $0 + $1.value }
            Chart(all) { p in
                SectorMark(angle: .value(unit, p.value), innerRadius: .ratio(0.45), angularInset: 1)
                    .foregroundStyle(by: .value("Label", p.label))
                    .annotation(position: .overlay) {
                        if total > 0, p.value / total >= 0.05 {
                            Text("\(Int((p.value / total * 100).rounded()))%")
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        }
                    }
            }
        case "stacked":
            // Each part's value inside it, when it's tall enough to hold it.
            let tallest = Dictionary(grouping: all, by: \.label).values.map { $0.reduce(0) { $0 + max($1.value, 0) } }.max() ?? 0
            Chart(all) { p in
                BarMark(x: .value("Label", p.label), y: .value(unit, p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .annotation(position: .overlay) {
                        if labelled, tallest > 0, abs(p.value) / tallest >= 0.08 {
                            label(p.value).foregroundStyle(.white)
                        }
                    }
            }
            .chartLegend(several ? .visible : .hidden)
            .chartYAxisLabel(chart.unit)
        default:
            Chart(all) { p in
                BarMark(x: .value("Label", p.label), y: .value(unit, p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .position(by: .value("Series", p.series))
                    .annotation(position: p.value < 0 ? .bottom : .top, spacing: 2) {
                        if labelled { label(p.value).foregroundStyle(.secondary) }
                    }
            }
            .chartLegend(several ? .visible : .hidden)
            .chartYAxisLabel(chart.unit)
        }
    }
}
