import XCTest
@testable import LLMTrayCore

final class DocumentJobTests: XCTestCase {
    private func spec(_ content: String, style: String = "report", charts: [DocumentSpec.Chart] = []) -> DocumentSpec {
        DocumentSpec(title: "T", content: content, style: style, charts: charts, notes: [])
    }

    private let chart = DocumentSpec.Chart(id: "c1", kind: .bar, title: "Costs", labels: ["A"],
                                           series: [.init(name: "", values: [1])], unit: "")

    func testChartsTheContentDidntPlaceGoAtTheEnd() {
        let placed = DocumentJob.make(spec("Text\n![x](chart:c1)", charts: [chart])).job
        XCTAssertEqual(placed.html.components(separatedBy: "llmtray-doc://chart/c1").count - 1, 1)
        let unplaced = DocumentJob.make(spec("Text", charts: [chart])).job
        XCTAssertTrue(unplaced.html.hasSuffix("<p class=\"figure\"><img src=\"llmtray-doc://chart/c1\" alt=\"Costs\"></p><p class=\"caption\">Costs</p></body></html>"))
        XCTAssertEqual(unplaced.charts.first?.kind, "bar")
    }

    func testTableOfContentsAfterTheTitleOfALongReport() {
        let long = "# Title\nIntro\n## A\n## B\n## C\n## D"
        let html = DocumentJob.make(spec(long)).job.html
        let title = html.range(of: "<h1>Title</h1>")!, nav = html.range(of: "<nav class=\"toc\">")!
        XCTAssertLessThan(title.lowerBound, nav.lowerBound)
        XCTAssertFalse(DocumentJob.make(spec("# T\n## A\n## B")).job.html.contains("<nav"), "short: none")
        XCTAssertFalse(DocumentJob.make(spec(long, style: "letter")).job.html.contains("<nav"), "a letter: none")
    }

    func testProjectPicturesAreLeftOutWithANoteForNow() {
        let made = DocumentJob.make(spec("![a](project:p1) and ![b](project:p1) ![c](project:p2)"))
        XCTAssertEqual(made.notes, ["Picture p1 couldn't be used.", "Picture p2 couldn't be used."])
        XCTAssertFalse(made.job.html.contains("<img"))
        XCTAssertTrue(made.job.pictures.isEmpty)
    }

    func testTooLargeIsSaid() {
        let huge = String(repeating: "|a|b|\n|---|---|\n" + String(repeating: "|x|y|\n", count: 2), count: 1)
        XCTAssertFalse(DocumentJob.make(spec(huge)).tooLarge)
    }

    func testStylesheetsAndTheJobRoundTrip() throws {
        XCTAssertEqual(DocumentStyles.css("nonsense"), DocumentStyles.css("report"))
        XCTAssertTrue(DocumentStyles.css("letter").contains("Georgia"))
        for style in DocumentHTML.styles {
            XCTAssertFalse(DocumentStyles.css(style).contains("url("), "\(style): nothing loaded by CSS")
        }
        let job = DocumentJob.make(spec("Text", charts: [chart])).job
        XCTAssertEqual(try JSONDecoder().decode(DocumentJob.self, from: JSONEncoder().encode(job)), job)
    }
}
