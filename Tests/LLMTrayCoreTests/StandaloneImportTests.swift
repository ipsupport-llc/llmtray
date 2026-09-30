import XCTest
@testable import LLMTrayCore

final class StandaloneImportTests: XCTestCase {
    private var root: URL!
    private var source: URL { root.appendingPathComponent("source") }
    private var destination: URL { root.appendingPathComponent("destination") }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("StandaloneImportTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ text: String, _ path: String, in base: URL) throws {
        let url = base.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) -> String? {
        fm.contents(atPath: destination.appendingPathComponent(path).path).map { String(decoding: $0, as: UTF8.self) }
    }

    func testMissingItemsAreCopiedWhole() throws {
        try write("chat", "sessions/A.json", in: source)
        try write("w", "voice_models/m/model.safetensors", in: source)
        try write("stats", "tool_call_stats.json", in: source)
        let summary = try StandaloneImport.run(from: source, to: destination)
        XCTAssertEqual(read("sessions/A.json"), "chat")
        XCTAssertEqual(read("voice_models/m/model.safetensors"), "w")
        XCTAssertEqual(read("tool_call_stats.json"), "stats")
        XCTAssertEqual(Set(summary.imported), ["sessions", "voice_models", "tool_call_stats.json"])
    }

    func testNothingHereIsOverwritten() throws {
        try write("theirs", "sessions/A.json", in: source)
        try write("theirs B", "sessions/B.json", in: source)
        try write("ours", "sessions/A.json", in: destination)
        try write("their stats", "tool_call_stats.json", in: source)
        try write("our stats", "tool_call_stats.json", in: destination)
        _ = try StandaloneImport.run(from: source, to: destination)
        XCTAssertEqual(read("sessions/A.json"), "ours")
        XCTAssertEqual(read("sessions/B.json"), "theirs B")
        XCTAssertEqual(read("tool_call_stats.json"), "our stats")
    }

    func testUnfinishedDownloadsAndRuntimesAreLeftOut() throws {
        try write("x", "mflux_models/klein4b.partial-1234/a", in: source)
        try write("x", "mflux_models/.DS_Store", in: source)
        try write("x", "mflux_models/klein4b/a", in: destination)
        try write("x", "mflux_venv/bin/python3", in: source)
        try write("x", "telemetry.json", in: source)
        try write("x", "folder_grants.json", in: source)
        let plan = StandaloneImport.plan(from: source, to: destination)
        XCTAssertTrue(plan.isEmpty, "\(plan)")
    }

    func testAssignmentsAreMergedOursWinning() throws {
        try write(#"{"/m/a": "P1", "/m/b": "P2"}"#, "profiles/assignments.json", in: source)
        try write(#"{"id": "P1"}"#, "profiles/P1.json", in: source)
        try write(#"{"/m/a": "OURS"}"#, "profiles/assignments.json", in: destination)
        let summary = try StandaloneImport.run(from: source, to: destination)
        let merged = try JSONDecoder().decode([String: String].self, from: Data(read("profiles/assignments.json")!.utf8))
        XCTAssertEqual(merged, ["/m/a": "OURS", "/m/b": "P2"])
        XCTAssertEqual(summary.assignmentsMerged, 1)
        XCTAssertEqual(read("profiles/P1.json"), #"{"id": "P1"}"#)
    }

    func testRecognisesTheDataFolder() throws {
        XCTAssertFalse(StandaloneImport.looksLikeDataFolder(source))
        try write("x", "sessions/A.json", in: source)
        XCTAssertTrue(StandaloneImport.looksLikeDataFolder(source))
    }

    func testRunningTwiceCopiesNothingMore() throws {
        try write("chat", "sessions/A.json", in: source)
        _ = try StandaloneImport.run(from: source, to: destination)
        XCTAssertTrue(StandaloneImport.plan(from: source, to: destination).isEmpty)
        XCTAssertEqual(try StandaloneImport.run(from: source, to: destination).imported, [])
    }
}
