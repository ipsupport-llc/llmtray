import XCTest
@testable import LLMTrayCore

final class DocumentEditTests: XCTestCase {
    private let base = """
    # Plan

    Intro.

    ## 1. Costs

    Old costs.

    ![c](chart:costs)

    ### Detail

    Old detail.

    ## Risks

    ```
    ## not a heading
    ```

    Old risks.
    """

    private func call(_ json: String) -> [String: Any] {
        let parsed = ToolArgumentParser.parse(json, schema: DocumentSpec.schema)
        XCTAssertTrue(parsed.problems.isEmpty, "\(parsed.problems)")
        return parsed.values
    }

    private var baseValues: [String: Any] {
        ["title": "Plan", "content": base, "style": "notes",
         "charts": [["id": "costs", "type": "bar", "series": [["values": [1.0, 2.0]]]],
                    ["id": "end", "type": "pie", "series": [["values": [1.0]]]]]]
    }

    private func content(_ values: [String: Any]) -> String { (values["content"] as? String) ?? "" }

    func testReplacesASectionsBodyKeepingItsHeading() throws {
        let out = try DocumentEdit.apply(call(#"{"title": "Plan", "changes": [{"section": "Costs", "content": "New costs."}]}"#), to: baseValues).get()
        let text = content(out.values)
        XCTAssertTrue(text.contains("## 1. Costs\n\nNew costs."), text)
        XCTAssertFalse(text.contains("Old costs") || text.contains("Old detail"), "the subsection went with it: \(text)")
        XCTAssertTrue(text.contains("Intro.") && text.contains("Old risks."), text)
        XCTAssertEqual(out.values["style"] as? String, "notes", "kept")
        // Its chart's place went with it: the chart too, not at the end.
        XCTAssertEqual((out.values["charts"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["end"])
    }

    func testReplacesWithAHeadingRemovesAddsAndAppends() throws {
        let out = try DocumentEdit.apply(call(#"""
        {"title": "Plan v2", "changes": [
          {"section": "## Risks", "content": "## Dangers\n\nNew risks."},
          {"section": "detail", "content": ""},
          {"after": "Intro", "content": "## Notes\n\nA note."},
          {"after": "Plan", "content": ""},
          {"content": "## Ending\n\nBye."}
        ], "charts": [{"id": "costs", "type": "line", "series": [{"values": [3, 4]}]}]}
        """#), to: baseValues)
        // After "Intro", no heading: at the end, said.
        let appended = try out.get()
        XCTAssertTrue(content(appended.values).hasSuffix("## Ending\n\nBye."), content(appended.values))
        XCTAssertTrue(content(appended.values).contains("## Notes\n\nA note."))
        XCTAssertTrue(appended.adjusted.contains { $0.contains("no section \"Intro\"") }, "\(appended.adjusted)")
        let ok = try DocumentEdit.apply(call(#"""
        {"title": "Plan v2", "changes": [
          {"section": "## Risks", "content": "## Dangers\n\nNew risks."},
          {"section": "detail", "content": ""},
          {"content": "## Ending\n\nBye."}
        ], "charts": [{"id": "costs", "type": "line", "series": [{"values": [3, 4]}]}]}
        """#), to: baseValues).get()
        let text = content(ok.values)
        XCTAssertTrue(text.contains("## Dangers\n\nNew risks.") && !text.contains("Old risks") && !text.contains("## Risks"), text)
        XCTAssertFalse(text.contains("Detail"), text)
        XCTAssertTrue(text.hasSuffix("## Ending\n\nBye."), text)
        XCTAssertFalse(text.contains("not a heading"), "a heading in code is part of its section, replaced with it: \(text)")
        XCTAssertEqual(ok.values["title"] as? String, "Plan v2")
        let charts = ok.values["charts"] as? [[String: Any]] ?? []
        XCTAssertEqual(charts.compactMap { $0["id"] as? String }, ["costs", "end"])
        XCTAssertEqual(charts.first?["type"] as? String, "line", "replaced by id")
        XCTAssertNil(ok.values["changes"])
    }

    func testFindsSectionsByNumberCaseAndPart() {
        let sections = DocumentEdit.sections(DocumentHTML.lines(base))
        XCTAssertEqual(sections.map(\.title), ["Plan", "1. Costs", "Detail", "Risks"], "not the heading in code")
        func title(_ name: String, _ list: [DocumentEdit.Section] = sections) -> String? {
            if case .one(let s) = DocumentEdit.find(name, in: list) { return s.title }
            return nil
        }
        XCTAssertEqual(title("costs"), "1. Costs")
        XCTAssertEqual(title("2. Costs"), "1. Costs")
        XCTAssertEqual(title("**RISKS**"), "Risks")
        XCTAssertEqual(title("Cost"), "1. Costs", "the one heading containing it")
        XCTAssertNil(title("Budget"))
        // Two that fit are a question back, never the first of them.
        let twice = DocumentEdit.sections(DocumentHTML.lines("# T\n## 1. Costs\nA\n## 2. Costs\nB\n## Summary\n## Summary"))
        XCTAssertEqual(title("2. Costs", twice), "2. Costs")
        for name in ["Costs", "Summary"] {
            guard case .several(let all) = DocumentEdit.find(name, in: twice) else { return XCTFail(name) }
            XCTAssertEqual(all.count, 2)
        }
        let out = DocumentEdit.apply(call(#"{"title": "x", "changes": [{"section": "Costs", "content": "y"}]}"#),
                                     to: ["title": "T", "content": "# T\n## 1. Costs\nA\n## 2. Costs\nB"])
        guard case .failure(let problem) = out else { return XCTFail() }
        XCTAssertTrue(problem.text.contains("\"1. Costs\", \"2. Costs\""), problem.text)
    }

    /// A heading alone renames the section; the document stays.
    func testAHeadingAloneRenames() throws {
        let out = try DocumentEdit.apply(call(##"{"title": "Plan", "changes": [{"section": "Plan", "content": "# New plan"}]}"##), to: baseValues).get()
        let text = content(out.values)
        XCTAssertTrue(text.hasPrefix("# New plan\n"), text)
        XCTAssertTrue(text.contains("Old costs.") && text.contains("Old risks."), text)
        XCTAssertTrue(out.adjusted.isEmpty, "\(out.adjusted)")
        let sub = try DocumentEdit.apply(call(#"{"title": "Plan", "changes": [{"section": "Costs", "content": "\n## 1. Budget\n"}]}"#), to: baseValues).get()
        XCTAssertTrue(content(sub.values).contains("## 1. Budget\n\nOld costs."), content(sub.values))
    }

    /// Most of the document removed: the answer says so.
    func testRemovingMostIsSaid() throws {
        let out = try DocumentEdit.apply(call(##"{"title": "Plan", "changes": [{"section": "Plan", "content": "# Plan\n\nShort."}]}"##), to: baseValues).get()
        XCTAssertEqual(out.adjusted.count, 1)
        XCTAssertTrue(out.adjusted[0].contains("removed most of the document"), out.adjusted[0])
    }

    func testChangesAreBounded() {
        let many = (0..<(DocumentSpec.Limits.changes + 1)).map { _ in #"{"content": "x"}"# }.joined(separator: ",")
        XCTAssertNil(try? DocumentEdit.apply(call(#"{"title": "x", "changes": [\#(many)]}"#), to: baseValues).get())
    }

    func testAMissingSectionListsTheHeadings() {
        guard case .failure(let problem) = DocumentEdit.apply(call(#"{"title": "x", "changes": [{"section": "Budget", "content": "y"}]}"#), to: baseValues) else {
            return XCTFail()
        }
        XCTAssertTrue(problem.text.contains("\"Budget\"") && problem.text.contains("\"1. Costs\", \"Detail\", \"Risks\""), problem.text)
    }

    func testResolvePicksTheDocumentAndPrefersContent() throws {
        let earlier = MakeJSON.string(baseValues)
        let other = MakeJSON.string(["title": "Other", "content": "# Other\n\n## Costs\n\nOther costs."])
        let docs = [(title: "Plan", arguments: earlier), (title: "Other", arguments: other)]
        // Its title picks it; else the latest.
        let byTitle = try DocumentEdit.resolve(call(#"{"title": "plan", "changes": [{"section": "Costs", "content": "X"}]}"#), documents: docs).get()
        XCTAssertTrue(content(byTitle.0).contains("Intro."))
        XCTAssertEqual(byTitle.2?.title, "Plan")
        let latest = try DocumentEdit.resolve(call(#"{"title": "New", "changes": [{"section": "Costs", "content": "X"}]}"#), documents: docs).get()
        XCTAssertTrue(content(latest.0).contains("# Other"))
        // The whole content wins over changes; no changes, as it came.
        let whole = try DocumentEdit.resolve(call(#"{"title": "N", "content": "All new.", "changes": [{"section": "Costs", "content": "X"}]}"#), documents: docs).get()
        XCTAssertEqual(content(whole.0), "All new.")
        XCTAssertEqual(whole.1.count, 1)
        XCTAssertNil(whole.0["changes"])
        let plain = try DocumentEdit.resolve(call(#"{"title": "N", "content": "Hi"}"#), documents: []).get()
        XCTAssertEqual(content(plain.0), "Hi")
        XCTAssertNil(plain.2?.title)
        // Nothing to change.
        XCTAssertNil(try? DocumentEdit.resolve(call(#"{"title": "N", "changes": [{"content": "X"}]}"#), documents: []).get())
        // The result reads as a document.
        XCTAssertNotNil(try? DocumentSpec.read(byTitle.0).get())
    }

    func testPick() {
        XCTAssertNil(DocumentEdit.pick(title: "x", among: []))
        XCTAssertEqual(DocumentEdit.pick(title: "A", among: ["A", "B", "a"]), 2, "the latest of that title")
        XCTAssertEqual(DocumentEdit.pick(title: "Z", among: ["A", "B"]), 1)
        XCTAssertEqual(DocumentEdit.pick(title: nil, among: ["A", "B"]), 1)
    }
}

private enum MakeJSON {
    static func string(_ value: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}
