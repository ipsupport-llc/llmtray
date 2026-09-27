import XCTest
@testable import LLMTrayCore

final class ToolCallStatsTests: XCTestCase {
    func testCountsPerToolAndVersion() throws {
        var stats = ToolCallStats()
        stats.record(tool: "calculate", known: true, version: "1.0", repairs: [], outcome: .success)
        stats.record(tool: "calculate", known: true, version: "1.0", repairs: [.fenced, .fieldAlias, .fenced], outcome: .success)
        stats.record(tool: "calculate", known: true, version: "1.0", repairs: [], outcome: .error("missing_field"))
        stats.record(tool: "web_search", known: true, version: "1.0", repairs: [], outcome: .refused)
        stats.record(tool: "made_up", known: false, version: "1.0", repairs: [], outcome: .error("unknown_tool"))
        stats.record(tool: "calculate", known: true, version: "1.1", repairs: [], outcome: .error("something odd"))
        let c = try XCTUnwrap(stats.versions["1.0"]?.tools["calculate"])
        XCTAssertEqual(c.calls, 3)
        XCTAssertEqual(c.successes, 2)
        XCTAssertEqual(c.repairedCalls, 1)
        XCTAssertEqual(c.repairs, ["fenced": 1, "fieldAlias": 1], "a repair counts once per call")
        XCTAssertEqual(c.errors, ["missing_field": 1])
        XCTAssertEqual(stats.versions["1.0"]?.tools["web_search"]?.refusals, 1)
        XCTAssertEqual(stats.versions["1.0"]?.tools[ToolCallStats.unknownTool]?.errors, ["unknown_tool": 1], "the model's name isn't kept")
        XCTAssertNil(stats.versions["1.0"]?.tools["made_up"])
        XCTAssertEqual(stats.versions["1.1"]?.tools["calculate"]?.errors, ["failed": 1], "unlisted kinds are failures")
    }

    func testBounded() {
        var stats = ToolCallStats()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for v in 0..<8 {
            stats.record(tool: "calculate", known: true, version: "0.\(v)", repairs: [], outcome: .success, now: start.addingTimeInterval(Double(v)))
        }
        XCTAssertEqual(stats.versions.count, ToolCallStats.maxVersions)
        XCTAssertNil(stats.versions["0.0"], "oldest dropped")
        XCTAssertNotNil(stats.versions["0.7"])
        for t in 0..<(ToolCallStats.maxTools + 10) {
            stats.record(tool: "tool\(t)", known: true, version: "0.7", repairs: [], outcome: .success)
        }
        XCTAssertLessThanOrEqual(stats.versions["0.7"]?.tools.count ?? 0, ToolCallStats.maxTools + 1)
        XCTAssertGreaterThan(stats.versions["0.7"]?.tools[ToolCallStats.unknownTool]?.calls ?? 0, 0)
    }

    func testFileRoundTripAndBrokenFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stats.json")
        var stats = ToolCallStats()
        stats.record(tool: "calculate", known: true, version: "1.0", repairs: [.typeCoerced], outcome: .success,
                     now: Date(timeIntervalSince1970: 1_700_000_000))
        try stats.save(to: url)
        XCTAssertEqual(ToolCallStats.load(from: url), stats)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(ToolCallStats.load(from: url), ToolCallStats(), "a broken file starts over")
        XCTAssertEqual(ToolCallStats.load(from: dir.appendingPathComponent("missing.json")), ToolCallStats())
    }

    func testReportLines() {
        var stats = ToolCallStats()
        XCTAssertEqual(stats.reportLines(version: "1.0").map(\.1), ["none recorded"])
        stats.record(tool: "web_search", known: true, version: "1.0", repairs: [], outcome: .success)
        stats.record(tool: "calculate", known: true, version: "1.0", repairs: [.fenced], outcome: .success)
        stats.record(tool: "calculate", known: true, version: "1.0", repairs: [], outcome: .error("bad_json"))
        let lines = stats.reportLines(version: "1.0")
        XCTAssertEqual(lines.map(\.0), ["calculate", "web_search"])
        XCTAssertEqual(lines[0].1, "2 calls, 1 ok, 1 repaired (fenced 1), 1 errors (bad_json 1), 0 refused")
    }
}
