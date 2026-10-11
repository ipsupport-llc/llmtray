import XCTest
@testable import LLMTrayCore

final class ToolSchemaListTests: XCTestCase {
    private let chart = ToolSchema("make_document", "Doc.", [
        .init("labels", .list(.string)),
        .init("series", .objects([.init("name", .string), .init("values", .list(.number), required: true)])),
    ])

    private func parse(_ raw: String) -> ParsedToolArguments { ToolArgumentParser.parse(raw, schema: chart) }

    func testDeclaresArraysOfTheElementType() {
        let params = ((chart.definition["function"] as? [String: Any])?["parameters"] as? [String: Any])?["properties"] as? [String: Any]
        let labels = params?["labels"] as? [String: Any]
        XCTAssertEqual(labels?["type"] as? String, "array")
        XCTAssertEqual((labels?["items"] as? [String: Any])?["type"] as? String, "string")
        let series = (params?["series"] as? [String: Any])?["items"] as? [String: Any]
        let values = (series?["properties"] as? [String: Any])?["values"] as? [String: Any]
        XCTAssertEqual((values?["items"] as? [String: Any])?["type"] as? String, "number")
    }

    func testReadsListsLeniently() {
        let p = parse(#"{"labels": ["Q1", 2024], "series": [{"name": "Cost", "values": [1, "2.5", 3]}]}"#)
        XCTAssertTrue(p.isValid, "\(p.problems)")
        XCTAssertEqual(p.values["labels"] as? [String], ["Q1", "2024"])
        let values = ((p.values["series"] as? [[String: Any]])?.first?["values"]) as? [Double]
        XCTAssertEqual(values, [1, 2.5, 3])
        // One value for a list of one; a list sent as a JSON string.
        let one = parse(#"{"labels": "Only", "series": {"values": "[4, 5]"}}"#)
        XCTAssertTrue(one.isValid, "\(one.problems)")
        XCTAssertEqual(one.values["labels"] as? [String], ["Only"])
        XCTAssertEqual(((one.values["series"] as? [[String: Any]])?.first?["values"]) as? [Double], [4, 5])
        XCTAssertTrue(one.repairs.contains(.listWrapped))
    }

    func testABadItemIsNamedWithARetry() {
        let p = parse(#"{"series": [{"values": [1, "a lot", 3]}]}"#)
        XCTAssertEqual(p.problems, [.wrongType("series[0].values[1]", "\"a lot\"")])
        let bad = parse(#"{"labels": [{"x": 1}]}"#)
        XCTAssertEqual(bad.problems.count, 1)
        XCTAssertNotNil(bad.errorMessage(tool: chart))
        let nan = parse(#"{"series": [{"values": ["nan"]}]}"#)
        XCTAssertFalse(nan.isValid)
    }
}
