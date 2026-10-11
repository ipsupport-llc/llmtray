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
            info.topMargin = 54
            info.bottomMargin = 54
            info.leftMargin = 54
            info.rightMargin = 54
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
        let series: String
        let value: Double
    }

    private var points: [Point] {
        var out: [Point] = []
        for (s, series) in chart.series.enumerated() {
            for (i, value) in series.values.enumerated() {
                let label = i < chart.labels.count ? chart.labels[i] : String(i + 1)
                out.append(Point(id: s * 10_000 + i, label: label, series: series.name.isEmpty ? "Series \(s + 1)" : series.name, value: value))
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

    @ViewBuilder private var content: some View {
        let unit = chart.unit.isEmpty ? "Value" : chart.unit
        let several = chart.series.count > 1
        switch chart.kind {
        case "line":
            Chart(points) { p in
                LineMark(x: .value("Label", p.label), y: .value(unit, p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                PointMark(x: .value("Label", p.label), y: .value(unit, p.value))
                    .foregroundStyle(by: .value("Series", p.series))
            }
            .chartLegend(several ? .visible : .hidden)
            .chartYAxisLabel(chart.unit)
        case "pie":
            Chart(points) { p in
                SectorMark(angle: .value(unit, p.value), innerRadius: .ratio(0.45), angularInset: 1)
                    .foregroundStyle(by: .value("Label", p.label))
            }
        default:
            Chart(points) { p in
                BarMark(x: .value("Label", p.label), y: .value(unit, p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .position(by: .value("Series", p.series))
            }
            .chartLegend(several ? .visible : .hidden)
            .chartYAxisLabel(chart.unit)
        }
    }
}
