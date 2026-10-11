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
}

final class DocumentSpecTests: XCTestCase {
    private func read(_ json: String) -> Result<DocumentSpec, DocumentError> {
        let parsed = ToolArgumentParser.parse(json, schema: DocumentSpec.schema)
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
        let spec = try read(#"{"title": "x", "content": "y", "charts": [{"id": "a", "type": "bar", "labels": ["A"], "series": [{"values": [1, 2]}]}, {"id": "b", "type": "pie", "series": [{"values": [1]}, {"values": [2]}]}, {"id": "c", "type": "pie", "series": [{"values": [0, 0]}]}, {"id": "bad id!", "type": "bar", "series": [{"values": [1]}]}, {"id": "ok", "type": "line", "series": [{"values": [1, 2, 3]}]}, {"id": "ok", "type": "line", "series": [{"values": [1]}]}]}"#).get()
        XCTAssertEqual(spec.charts.map(\.id), ["ok"])
        XCTAssertEqual(spec.charts.first?.labels, ["1", "2", "3"])
        XCTAssertEqual(spec.notes.count, 5, "\(spec.notes)")
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
