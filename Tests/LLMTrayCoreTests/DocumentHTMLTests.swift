import XCTest
@testable import LLMTrayCore

final class DocumentHTMLTests: XCTestCase {
    private func body(_ md: String, charts: Set<String> = [], pictures: Set<String> = []) -> DocumentHTML.Body {
        DocumentHTML.body(markdown: md) { ref in
            switch ref {
            case .chart(let id): return charts.contains(id) ? "llmtray-doc://chart/\(id)" : nil
            case .picture(let id): return pictures.contains(id) ? "llmtray-doc://image/\(id)" : nil
            }
        }
    }

    /// Every tag the page has is on the allowlist, and every attribute is
    /// one the converter may write.
    private func assertOnlyAllowedMarkup(_ html: String, file: StaticString = #filePath, line: UInt = #line) {
        let tag = try! NSRegularExpression(pattern: "<\\s*/?\\s*([a-zA-Z0-9]+)([^>]*)>")
        let attr = try! NSRegularExpression(pattern: "([a-zA-Z-]+)\\s*=\\s*\"([^\"]*)\"")
        for m in tag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let name = String(html[Range(m.range(at: 1), in: html)!]).lowercased()
            XCTAssertTrue(DocumentHTML.allowedTags.contains(name), "tag <\(name)>", file: file, line: line)
            let rest = String(html[Range(m.range(at: 2), in: html)!])
            for a in attr.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
                let key = String(rest[Range(a.range(at: 1), in: rest)!]).lowercased()
                let value = String(rest[Range(a.range(at: 2), in: rest)!])
                switch (name, key) {
                case (_, "class"), ("meta", "charset"), ("link", "rel"), ("img", "alt"): break
                case ("a", "href"):
                    XCTAssertTrue(value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("mailto:"), value, file: file, line: line)
                case ("img", "src"), ("link", "href"):
                    XCTAssertTrue(value.hasPrefix("llmtray-doc://"), value, file: file, line: line)
                // Math's own, fixed values only.
                case ("math", "display"): XCTAssertEqual(value, "block", file: file, line: line)
                case ("mi", "mathvariant"): XCTAssertEqual(value, "normal", file: file, line: line)
                case ("mo", "stretchy"): XCTAssertEqual(value, "false", file: file, line: line)
                case ("mover", "accent"): XCTAssertEqual(value, "true", file: file, line: line)
                case ("mfrac", "linethickness"): XCTAssertEqual(value, "0", file: file, line: line)
                default: XCTFail("attribute \(key) on <\(name)>", file: file, line: line)
                }
            }
        }
    }

    func testBlocks() {
        let html = body("""
        # Report
        Intro with **bold**, *italic*, ~~old~~ and `code`.

        ## Costs
        - one
        - two
          - nested
        1. first
        2. second

        > quoted
        > more

        | Item | Cost |
        |:-----|-----:|
        | A | 10 |

        ---
        ```
        <b>not bold</b>
        ```
        """).html
        XCTAssertTrue(html.contains("<h1>Report</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>") && html.contains("<em>italic</em>") && html.contains("<del>old</del>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
        XCTAssertTrue(html.contains("<ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>"), html)
        XCTAssertTrue(html.contains("<ol><li>first</li><li>second</li></ol>"))
        XCTAssertTrue(html.contains("<blockquote><p>quoted more</p></blockquote>"))
        XCTAssertTrue(html.contains("<th>Item</th><th class=\"r\">Cost</th>"), html)
        XCTAssertTrue(html.contains("<hr>"))
        XCTAssertTrue(html.contains("<pre><code>&lt;b&gt;not bold&lt;/b&gt;</code></pre>"))
        assertOnlyAllowedMarkup(html)
    }

    func testHostileContentNeverBecomesMarkup() {
        let md = """
        <script>alert(1)</script>
        <img src=x onerror=alert(1)> <iframe src="http://evil"></iframe> <style>body{}</style>
        <meta http-equiv="refresh" content="0;url=http://evil"> <base href="http://evil/">
        [click](javascript:alert(1)) [file](file:///etc/passwd) [data](data:text/html,<b>x</b>)
        ![x](http://evil/x.png) ![y](data:image/svg+xml;base64,AAAA) ![z](file:///etc/hosts)
        [ok](https://example.com/"onmouseover="x) "><img src=x>
        <svg onload=alert(1)><video src=x><audio src=x><form action=x><embed src=x><object data=x>
        """
        let html = body(md).html
        assertOnlyAllowedMarkup(html)
        for bad in ["<script", "<iframe", "<style", "<meta", "<base", "<svg", "<video", "<audio", "<form", "<embed", "<object",
                    "javascript:", "file:", "data:", "evil/x.png\"", "onerror=\""] {
            XCTAssertFalse(html.lowercased().contains(bad.lowercased()) && !html.contains("&lt;" + bad.dropFirst()), bad)
        }
        XCTAssertFalse(html.contains("<a href=\"javascript"))
        XCTAssertFalse(html.contains("src=\"http"))
        // The link with a quote in it isn't a link (whitespace-free, but a quote
        // inside an attribute is escaped anyway).
        XCTAssertFalse(html.contains("onmouseover=\""))
    }

    func testLinksShowWhereTheyGo() {
        let html = body("See [our site](https://example.com) and [https://example.com/a](https://example.com/a), mail [me](mailto:a@b.c).").html
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">our site</a> <span class=\"addr\">(example.com)</span>"), html)
        XCTAssertTrue(html.contains("<a href=\"https://example.com/a\">https://example.com/a</a>,"), html)
        XCTAssertTrue(html.contains("<span class=\"addr\">(a@b.c)</span>"))
        assertOnlyAllowedMarkup(html)
    }

    func testChartsAndPicturesOnlyByReference() {
        let b = body("""
        Text
        ![Costs](chart:c1)
        Inline ![p](project:p2) and ![gone](project:p9) and ![nochart](chart:zz).
        """, charts: ["c1"], pictures: ["p2"])
        XCTAssertEqual(b.placed, [.chart("c1"), .picture("p2")])
        XCTAssertTrue(b.html.contains("<p class=\"figure\"><img src=\"llmtray-doc://chart/c1\" alt=\"Costs\"></p><p class=\"caption\">Costs</p>"), b.html)
        XCTAssertTrue(b.html.contains("<img src=\"llmtray-doc://image/p2\" alt=\"p\">"))
        XCTAssertTrue(b.html.contains("and gone and nochart."), b.html)
        assertOnlyAllowedMarkup(b.html)
    }

    func testPageAndTableOfContents() {
        let b = body("# T\n## One\n## Two")
        let page = DocumentHTML.page(title: "T <x>", style: "../../etc", body: b.html, toc: b.headings.filter { $0.level == 2 })
        XCTAssertTrue(page.contains("href=\"llmtray-doc://style/report.css\""))
        XCTAssertTrue(page.contains("<title>T &lt;x&gt;</title>"))
        XCTAssertTrue(page.contains("<li class=\"toc2\">One</li><li class=\"toc2\">Two</li>"))
        assertOnlyAllowedMarkup(page)
    }

    func testPathologicalInputStaysFast() {
        let stars = String(repeating: "*a", count: 100_000)
        let brackets = String(repeating: "[", count: 50_000)
        let quotes = String(repeating: "> ", count: 5_000) + "deep"
        let start = Date()
        for md in [stars, brackets, quotes, String(repeating: "- ", count: 2_000) + "x"] {
            assertOnlyAllowedMarkup(body(md).html)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testTablesAreBounded() {
        let wide = "|" + String(repeating: "x|", count: 25_000) + "\n|---|\n" + String(repeating: "|\n", count: 70_000)
        let html = body(wide).html
        XCTAssertFalse(html.contains("<table>"), "a separator that doesn't match the header isn't a table")
        let header = "|" + String(repeating: "h|", count: 50) + "\n|" + String(repeating: "---|", count: 50) + "\n"
        let tall = body(header + String(repeating: "|a|\n", count: 1_000)).html
        XCTAssertLessThanOrEqual(tall.components(separatedBy: "<td").count - 1, 20_000)
        // The budget is the document's, not each table's.
        let one = "|" + String(repeating: "|", count: 50) + "\n|" + String(repeating: ":--:|", count: 50) + "\n" + String(repeating: "|\n", count: 399) + "\n"
        let many = body(String(repeating: one, count: 181))
        let cells = try! NSRegularExpression(pattern: "<t[dh][ >]").numberOfMatches(in: many.html, range: NSRange(many.html.startIndex..., in: many.html))
        XCTAssertLessThanOrEqual(cells, 20_000)
        XCTAssertLessThan(many.html.utf8.count, DocumentHTML.maxBodyBytes)
    }

    func testEscapesControlCharacters() {
        XCTAssertEqual(DocumentHTML.escape("a\u{0}b\u{7F}c<&>\"'"), "abc&lt;&amp;&gt;&quot;&#39;")
    }

    func testMathInText() {
        let html = body(#"""
        Area $\pi r^2$ and \(x_1\), money $5 and $10, a price \$3, cost $5.

        $$\sum_{i=1}^{n} i = \frac{n(n+1)}{2}$$

        \[
        \begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}
        \]

        $<script>alert(1)</script>$ and $\frac{1}{$ and `$x$`
        """#).html
        assertOnlyAllowedMarkup(html)
        XCTAssertEqual(html.components(separatedBy: "<math display=\"block\">").count - 1, 2, html)
        XCTAssertEqual(html.components(separatedBy: "<math>").count - 1, 3, html)
        XCTAssertTrue(html.contains("money $5 and $10, a price $3, cost $5."), html)
        XCTAssertTrue(html.contains("<mtable>"), html)
        // Markup inside math is text; what can't be read stays as written.
        XCTAssertTrue(html.contains("<mo>&lt;</mo><mi>s</mi>"), html)
        XCTAssertFalse(html.contains("<script"), html)
        XCTAssertTrue(html.contains("$\\frac{1}{$"), html)
        XCTAssertTrue(html.contains("<code>$x$</code>"), html)
    }

    func testMathStaysBounded() {
        for hostile in [String(repeating: "\\sqrt", count: 5000) + "x", String(repeating: "{", count: 5000),
                        String(repeating: "x^", count: 3000) + "y", String(repeating: "\\left(", count: 2000)] {
            let started = Date()
            _ = body("$$" + hostile + "$$")
            _ = DocumentMath.mathML(hostile, display: false)
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        }
    }
}

final class DocumentSpecTests: XCTestCase {
    private func read(_ json: String) -> Result<DocumentSpec, DocumentError> {
        let parsed = ToolArgumentParser.parse(json, schema: DocumentSpec.schema)
        // As the app runs it: a call the schema rejects never gets here.
        XCTAssertTrue(parsed.problems.isEmpty, "\(parsed.problems)")
        return DocumentSpec.read(parsed.values)
    }

    func testReadsADocumentWithCharts() throws {
        let spec = try read(##"{"title": "Q3", "content": "# Q3\n![c](chart:c1)", "style": "memo", "charts": [{"id": "c1", "type": "column", "labels": ["A", "B"], "series": [{"name": "Cost", "values": [1, 2]}]}]}"##).get()
        XCTAssertEqual(spec.style, "notes")
        XCTAssertEqual(spec.charts.first?.kind, .bar)
        XCTAssertEqual(spec.charts.first?.series.first?.values, [1, 2])
        XCTAssertTrue(spec.notes.isEmpty)
    }

    func testBadChartsAreLeftOutWithANote() throws {
        let spec = try read(#"{"title": "x", "content": "y", "charts": [{"id": "a", "type": "bar", "labels": ["A"], "series": [{"values": [1, 2]}]}, {"id": "b", "type": "pie", "series": [{"values": [1, 2]}, {"values": [2, 3]}]}, {"id": "c", "type": "pie", "series": [{"values": [0, 0]}]}, {"id": "bad id!", "type": "bar", "series": [{"values": [1]}]}, {"id": "ok", "type": "line", "series": [{"values": [1, 2, 3]}]}, {"id": "ok", "type": "line", "series": [{"values": [1]}]}]}"#).get()
        // "a": its labels don't match its values -- drawn, points numbered.
        XCTAssertEqual(spec.charts.map(\.id), ["a", "ok"])
        XCTAssertEqual(spec.charts.map(\.labels), [["1", "2"], ["1", "2", "3"]])
        XCTAssertEqual(spec.notes.count, 4, "\(spec.notes)")
        XCTAssertEqual(spec.adjusted.count, 1, "drawn, with a note of its own")
        XCTAssertTrue(spec.adjusted[0].contains("numbered"), spec.adjusted[0])
    }

    /// A pie given as one series per slice is one series.
    func testPieOfOneValueSeries() throws {
        let spec = try read(#"{"title": "x", "content": "y", "charts": [{"id": "p", "type": "pie", "series": [{"name": "A", "values": [40]}, {"name": "B", "values": [30]}, {"values": [30]}]}, {"id": "q", "type": "pie", "labels": ["x", "y"], "series": [{"name": "A", "values": [1]}, {"name": "B", "values": [2]}]}]}"#).get()
        XCTAssertEqual(spec.charts.map(\.labels), [["A", "B", "3"], ["x", "y"]])
        XCTAssertEqual(spec.charts.map { $0.series.map(\.values) }, [[[40, 30, 30]], [[1, 2]]])
        XCTAssertTrue(spec.notes.isEmpty, "\(spec.notes)")
        // Labels that don't fit the slices are set aside -- and said.
        let odd = try read(#"{"title": "x", "content": "y", "charts": [{"id": "p", "type": "pie", "labels": ["Alpha"], "series": [{"values": [40]}, {"values": [60]}]}]}"#).get()
        XCTAssertEqual(odd.charts.first?.labels, ["1", "2"])
        XCTAssertEqual(odd.adjusted.count, 1, "\(odd.adjusted)")
        XCTAssertTrue(odd.notes.isEmpty)
    }

    /// A function plot is computed by the app, not written out by the model.
    func testFormulaCharts() throws {
        let spec = try read(#"{"title": "x", "content": "![s](chart:s)", "charts": [{"id": "s", "type": "bar", "range": ["0", "2*pi"], "series": [{"formula": "sin(x)"}, {"name": "cos", "function": "cos(x)"}]}]}"#).get()
        let chart = try XCTUnwrap(spec.charts.first)
        XCTAssertEqual(chart.kind, .line)
        XCTAssertEqual(chart.series.map(\.name), ["sin(x)", "cos"])
        let sine = chart.series[0]
        XCTAssertEqual(sine.values.count, DocumentSpec.Limits.formulaPoints)
        XCTAssertEqual(sine.xs.first, 0)
        XCTAssertEqual(sine.xs.last ?? 0, 2 * .pi, accuracy: 1e-9)
        XCTAssertEqual(sine.values[25], 1, accuracy: 1e-9)  // sin(pi/2)
        XCTAssertTrue(spec.notes.isEmpty, "\(spec.notes)")
        // Points without a value are left out; no range is -10...10.
        let log = try read(#"{"title": "x", "content": "y", "charts": [{"id": "l", "series": [{"formula": "log(x)"}]}]}"#).get()
        XCTAssertEqual(log.charts.first?.series.first?.xs.allSatisfy { $0 > 0 }, true)
        XCTAssertEqual(log.charts.first?.series.first?.xs.last, 10)
        XCTAssertEqual(log.charts.first?.range, [-10, 10], "the axis is the asked range, gaps and all")
        // A pole between two points, or at one: no line across it.
        let pole = try read(#"{"title": "x", "content": "y", "charts": [{"id": "p", "range": [-1, 2], "series": [{"formula": "1/x"}, {"name": "sin", "formula": "sin(x)"}]}]}"#).get()
        let inverse = try XCTUnwrap(pole.charts.first?.series.first)
        XCTAssertEqual(Set(inverse.pieces), [0, 1])
        XCTAssertTrue(zip(inverse.xs, inverse.pieces).allSatisfy { ($0 < 0) == ($1 == 0) })
        XCTAssertEqual(Set(pole.charts.first?.series.last?.pieces ?? []), [0], "a smooth line is one piece")
        // Limits count scalars: one letter with a thousand marks is too long.
        let marks = "x" + String(repeating: "\u{301}", count: 1000)
        let long = try read(#"{"title": "x", "content": "y", "charts": [{"id": "m", "series": [{"formula": "\#(marks)"}]}]}"#).get()
        XCTAssertEqual(long.charts.count, 0)
        // A typo, a mix with plain values, a bad range: left out with a note.
        let bad = try read(#"{"title": "x", "content": "y", "charts": [{"id": "a", "series": [{"formula": "sinn(x)"}]}, {"id": "b", "series": [{"formula": "x"}, {"values": [1]}]}, {"id": "c", "range": [5, 1], "series": [{"formula": "x"}]}, {"id": "d", "range": ["-1", "1"], "series": [{"formula": "sqrt(x - 5)"}]}]}"#).get()
        XCTAssertEqual(bad.charts.count, 0)
        XCTAssertEqual(bad.notes.count, 4, "\(bad.notes)")
        XCTAssertTrue(bad.notes[0].contains("unknown name"), bad.notes[0])
    }

    func testStackedAndScatterCharts() throws {
        let spec = try read(#"{"title": "x", "content": "y", "charts": [{"id": "s", "type": "stacked bar", "labels": ["A", "B"], "series": [{"values": [1, 2]}, {"values": [3, 4]}]}, {"id": "p", "type": "scatter", "series": [{"name": "m", "x": [170, 180], "values": [70, 80]}, {"name": "f", "x": [160, 165, 170], "values": [55, 58, 61]}]}, {"id": "l", "type": "points", "labels": ["1.5", "2.5"], "series": [{"values": [3, 4]}]}, {"id": "n", "type": "scatter", "series": [{"values": [3, 4, 5]}]}]}"#).get()
        XCTAssertEqual(spec.charts.map(\.kind), [.stacked, .scatter, .scatter, .scatter])
        XCTAssertEqual(spec.charts[1].series.map(\.xs), [[170, 180], [160, 165, 170]], "each series its own points")
        XCTAssertEqual(spec.charts[2].series[0].xs, [1.5, 2.5], "numbers for labels are the x")
        XCTAssertEqual(spec.charts[3].series[0].xs, [1, 2, 3])
        let extra = try read(#"{"title": "x", "content": "y", "charts": [{"id": "c", "type": "scatter", "series": [{"values": [1, 2], "x": [10, 20, 30]}]}]}"#).get()
        XCTAssertEqual(extra.charts.first?.series.first?.xs, [10, 20], "one x for each value")
        XCTAssertTrue(extra.adjusted.isEmpty, "\(extra.adjusted)")
        // An x on a line or bars is ignored: they're at their labels.
        let line = try read(#"{"title": "x", "content": "y", "charts": [{"id": "c", "type": "line", "series": [{"values": [1, 2], "x": [10, 20]}]}]}"#).get()
        XCTAssertEqual(line.charts.first?.series.first?.xs, [])
        XCTAssertEqual(spec.adjusted.count, 1, "\(spec.adjusted)")
        XCTAssertTrue(spec.notes.isEmpty, "\(spec.notes)")
        let job = DocumentJob.make(spec).job
        XCTAssertEqual(job.charts.map(\.kind), ["stacked", "scatter", "scatter", "scatter"])
        XCTAssertEqual(job.charts[1].series[1].xs, [160, 165, 170])
    }

    func testValueLabels() {
        let cases: [(Double, String)] = [(0, "0"), (12, "12"), (12.5, "12.5"), (340.26, "340.3"), (1234, "1234"),
                                         (12_500, "12500"), (125_000, "125K"), (1_500_000, "1.5M"), (2.5e9, "2.5B"),
                                         (0.0042, "0.0042"), (0.5, "0.5"), (-50, "-50"), (1.0, "1"), (1e-9, "1e-09")]
        for (v, text) in cases { XCTAssertEqual(DocumentJob.valueLabel(v), text, "\(v)") }
    }

    /// A chart given as image data, or placed but never given: nothing is
    /// made, and the answer says how a chart is given.
    func testBrokenChartsAreAnsweredNotMade() {
        guard case .failure(let data) = read(#"{"title": "Sine", "content": "'![Sine Wave](data:image/png;base64", "label": "chart", "unit": ""}"#) else {
            return XCTFail("made")
        }
        XCTAssertEqual(data, .imageData)
        XCTAssertTrue(data.text.contains("\"formula\": \"sin(x)\""), data.text)
        guard case .failure(let missing) = read(#"{"title": "x", "content": "![s](chart:sine)\n![t](chart:ok)", "charts": [{"id": "ok", "type": "bar", "series": [{"values": [1]}]}]}"#) else {
            return XCTFail("made")
        }
        XCTAssertEqual(missing, .missingCharts(["sine"]))
        XCTAssertTrue(missing.text.contains("chart:sine") && missing.text.contains("\"id\": \"sine\""), missing.text)
        // Given but left out (bad numbers): made, with its note.
        let bad = try? read(#"{"title": "x", "content": "![s](chart:s)", "charts": [{"id": "s", "type": "pie", "series": [{"values": [0, 0]}]}]}"#).get()
        XCTAssertEqual(bad?.notes.count, 1)
        // A data: address in prose or code, or a link to data, isn't an image.
        for ok in [#"Data URLs look like `data:image/png;base64,...`."#, #"See `![x](data:image/png;base64,AA)`."#,
                   "```\n![x](data:image/png;base64,AA)\n```", #"[download](data:text/plain,hello)"#,
                   #"`![s](chart:nope)` places a chart."#] {
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: ["title": "x", "content": ok]), as: UTF8.self)
            XCTAssertNotNil(try? read(json).get(), ok)
        }
        // A ninth chart is given (past the cap: its note), not missing.
        let nine = (1...9).map { #"{"id": "c\#($0)", "type": "bar", "series": [{"values": [1]}]}"# }.joined(separator: ",")
        let capped = try? read(#"{"title": "x", "content": "![n](chart:c9)", "charts": [\#(nine)]}"#).get()
        XCTAssertEqual(capped?.notes.first?.contains("first 8"), true)
    }

    /// What the earlier document already had (a change, Make again) isn't
    /// held against the call; a new one is.
    func testEarlierProblemsArentRefused() throws {
        let old = "## Costs\n![c](chart:c)\n![p](data:image/png;base64\n## Risks\nOld."
        let values: [String: Any] = ["title": "x", "content": old + "\nNew line."]
        XCTAssertNoThrow(try DocumentSpec.read(values, earlier: old).get())
        XCTAssertEqual(DocumentSpec.read(["title": "x", "content": old + "\n![d](chart:d)"], earlier: old).failure, .missingCharts(["d"]))
        XCTAssertEqual(DocumentSpec.read(["title": "x", "content": old + "\n![q](data:image/png"], earlier: old).failure, .imageData)
        // A new one in place of an old one is new.
        let swapped = old.replacingOccurrences(of: "![p](data:image/png;base64", with: "![p](data:image/png;base64,BB")
        XCTAssertEqual(DocumentSpec.read(["title": "x", "content": swapped], earlier: old).failure, .imageData)
        // An open link or image before one doesn't hide it.
        XCTAssertEqual(DocumentSpec.imagesAsData("[download](data:text/plain,hello ![x](data:image/png;base64,AA)"), ["![x](data:image/png;base64,AA)"])
        XCTAssertEqual(DocumentSpec.imagesAsData("![a](data:AAA ![b](data:BBB"), ["![a](data:AAA ", "![b](data:BBB"])
        XCTAssertEqual(DocumentSpec.imagesAsData("`open ![x](data:A)"), ["![x](data:A)"], "an open backtick is text")
        XCTAssertEqual(DocumentSpec.imagesAsData("![a[b](data:A)"), ["![a[b](data:A)"])
        XCTAssertEqual(DocumentSpec.imagesAsData("![Plot of `sin(x)`](data:A)"), ["![Plot of `sin(x)`](data:A)"], "code in a caption")
        XCTAssertEqual(DocumentSpec.imagesAsData("> ```markdown\n> ![Logo](data:image/png;base64,...)\n> ```"), [], "a quoted fence")
        XCTAssertEqual(DocumentSpec.imagesAsData("![y](p.png) [x](data:A)"), [], "a link after an image")
        // The same image twice is one more; the text around it may change.
        XCTAssertEqual(DocumentSpec.read(["title": "x", "content": old + "\n![p](data:image/png;base64"], earlier: old).failure, .imageData)
        let reworded = old.replacingOccurrences(of: "![p](data:image/png;base64", with: "See ![p](data:image/png;base64")
        XCTAssertNoThrow(try DocumentSpec.read(["title": "x", "content": reworded], earlier: old).get())
    }

    func testLimits() {
        XCTAssertEqual(try? read(#"{"title": "x", "content": "  "}"#).get(), nil)
        let long = String(repeating: "a", count: DocumentSpec.Limits.contentCharacters + 1)
        if case .failure(.tooLong) = read("{\"title\": \"x\", \"content\": \"\(long)\"}") {} else { XCTFail() }
        let many = (0..<501).map(String.init).joined(separator: ",")
        let spec = try? read("{\"title\": \"x\", \"content\": \"y\", \"charts\": [{\"id\": \"a\", \"type\": \"bar\", \"series\": [{\"values\": [\(many)]}]}]}").get()
        XCTAssertEqual(spec?.charts.count, 0)
    }

    func testLimitsCountScalars() {
        let marks = "a" + String(repeating: "\u{301}", count: DocumentSpec.Limits.contentCharacters)
        if case .failure(.tooLong) = DocumentSpec.read(["title": "x", "content": marks]) {} else { XCTFail() }
        XCTAssertEqual(DocumentSpec.clip("e" + String(repeating: "\u{301}", count: 500), 10).unicodeScalars.count, 10)
    }

    func testFileNames() throws {
        XCTAssertEqual(DocumentFileName.base("../../etc/passwd"), "etcpasswd")
        XCTAssertEqual(DocumentFileName.base(".hidden"), "hidden")
        XCTAssertEqual(DocumentFileName.base("  \n\u{0}  "), "Document")
        XCTAssertEqual(DocumentFileName.base("Cafe\u{301}: plan"), "Café plan")
        XCTAssertEqual(DocumentFileName.base(String(repeating: "x", count: 200)).count, 80)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try DocumentFileName.create(in: dir, title: "Report")
        let b = try DocumentFileName.create(in: dir, title: "Report")
        close(a.fd); close(b.fd)
        XCTAssertEqual([a.name, b.name], ["Report.pdf", "Report 2.pdf"])
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(a.name).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}
