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
        let summary = try StandaloneImport.run(from: source, to: destination, untouchedDefault: nil)
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
        _ = try StandaloneImport.run(from: source, to: destination, untouchedDefault: nil)
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
        let summary = try StandaloneImport.run(from: source, to: destination, untouchedDefault: nil)
        let merged = try JSONDecoder().decode([String: String].self, from: Data(read("profiles/assignments.json")!.utf8))
        XCTAssertEqual(merged, ["/m/a": "OURS", "/m/b": "P2"])
        XCTAssertEqual(summary.assignmentsAdded, 1)
        XCTAssertEqual(read("profiles/P1.json"), #"{"id": "P1"}"#)
    }

    func testRecognisesTheDataFolder() throws {
        XCTAssertFalse(StandaloneImport.looksLikeDataFolder(source))
        try write("x", "sessions/A.json", in: source)
        XCTAssertTrue(StandaloneImport.looksLikeDataFolder(source))
    }

    func testRunningTwiceCopiesNothingMore() throws {
        try write("chat", "sessions/A.json", in: source)
        _ = try StandaloneImport.run(from: source, to: destination, untouchedDefault: nil)
        XCTAssertTrue(StandaloneImport.plan(from: source, to: destination).isEmpty)
        XCTAssertEqual(try StandaloneImport.run(from: source, to: destination, untouchedDefault: nil).imported, [])
    }

    private func iso(_ library: ChatLibrary) throws -> String {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        return String(decoding: try e.encode(library), as: UTF8.self)
    }

    private func readLibrary() throws -> ChatLibrary {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(ChatLibrary.self, from: Data(read("sessions/library.json")!.utf8))
    }

    func testTheChatLibraryIsMergedOursWinning() throws {
        let shared = UUID(), theirsOnly = UUID(), chatA = UUID(), chatB = UUID()
        var theirs = ChatLibrary()
        theirs.projects = [.init(id: shared, name: "theirs"), .init(id: theirsOnly, name: "Research")]
        theirs.pinned = [chatA]
        theirs.projectOfChat = [chatA: shared, chatB: theirsOnly]
        var ours = ChatLibrary()
        ours.projects = [.init(id: shared, name: "ours")]
        ours.projectOfChat = [chatA: UUID()]
        try write(try iso(theirs), "sessions/library.json", in: source)
        try write(try iso(ours), "sessions/library.json", in: destination)
        let summary = try StandaloneImport.run(from: source, to: destination, untouchedDefault: nil)
        let merged = try readLibrary()
        XCTAssertEqual(summary.projectsAdded, 1)
        XCTAssertEqual(merged.projects.map(\.name), ["ours", "Research"])
        XCTAssertEqual(merged.pinned, [chatA])
        XCTAssertEqual(merged.projectOfChat[chatA], ours.projectOfChat[chatA])   // ours wins
        XCTAssertEqual(merged.projectOfChat[chatB], theirsOnly)
    }

    private func profileJSON(_ p: Profile) throws -> String {
        String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
    }

    func testTheirDefaultReplacesAnUntouchedOne() throws {
        var untouched = Profile.builtIn; untouched.id = Profile.defaultID; untouched.name = "Default"
        var theirs = untouched; theirs.request.systemPrompt = "Be terse."
        try write(try profileJSON(theirs), "profiles/default.json", in: source)
        try write(try profileJSON(untouched), "profiles/default.json", in: destination)
        let summary = try StandaloneImport.run(from: source, to: destination, untouchedDefault: untouched)
        XCTAssertEqual(summary.defaultProfile, .replaced)
        let now = try JSONDecoder().decode(Profile.self, from: Data(read("profiles/default.json")!.utf8))
        XCTAssertEqual(now.request.systemPrompt, "Be terse.")
        XCTAssertNil(read("profiles/imported-default.json"))
    }

    func testTheirDefaultComesAsItsOwnProfileWhenOursWasEdited() throws {
        var untouched = Profile.builtIn; untouched.id = Profile.defaultID; untouched.name = "Default"
        var theirs = untouched; theirs.request.systemPrompt = "Be terse."
        var ours = untouched; ours.request.systemPrompt = "Mine."
        try write(try profileJSON(theirs), "profiles/default.json", in: source)
        try write(try profileJSON(ours), "profiles/default.json", in: destination)
        let summary = try StandaloneImport.run(from: source, to: destination, untouchedDefault: untouched)
        XCTAssertEqual(summary.defaultProfile, .addedAsProfile)
        let kept = try JSONDecoder().decode(Profile.self, from: Data(read("profiles/default.json")!.utf8))
        XCTAssertEqual(kept.request.systemPrompt, "Mine.")
        let aside = try JSONDecoder().decode(Profile.self, from: Data(read("profiles/imported-default.json")!.utf8))
        XCTAssertEqual(aside.id, "imported-default")
        XCTAssertEqual(aside.request.systemPrompt, "Be terse.")
        // Once: a second import doesn't add another.
        XCTAssertEqual(try StandaloneImport.run(from: source, to: destination, untouchedDefault: untouched).defaultProfile, .unchanged)
    }

    func testAWholeCopyLeavesOutUnfinishedAndDiscardedThings() throws {
        try write("w", "mflux_models/klein4b/model.safetensors", in: source)
        try write("half", "mflux_models/zimage.partial-42/model.safetensors", in: source)
        try write("x", "mflux_models/.DS_Store", in: source)
        try write("x", "projects/P1/index.sqlite", in: source)
        try write("x", "projects/P2.deleting/index.sqlite", in: source)
        try write("chat", "sessions/A.json", in: source)
        try write("x", "sessions/library.json.unreadable-1", in: source)
        _ = try StandaloneImport.run(from: source, to: destination, untouchedDefault: nil)
        XCTAssertEqual(read("mflux_models/klein4b/model.safetensors"), "w")
        XCTAssertNil(read("mflux_models/zimage.partial-42/model.safetensors"))
        XCTAssertNil(read("mflux_models/.DS_Store"))
        XCTAssertEqual(read("projects/P1/index.sqlite"), "x")
        XCTAssertNil(read("projects/P2.deleting/index.sqlite"))
        XCTAssertNil(read("sessions/library.json.unreadable-1"))
    }

    func testALeftoverHalfCopyIsRemoved() throws {
        try write("half", "voice_models/m.import-1234/a", in: destination)
        try write("w", "voice_models/m/a", in: source)
        _ = try StandaloneImport.run(from: source, to: destination, untouchedDefault: nil)
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("voice_models/m.import-1234").path))
        XCTAssertEqual(read("voice_models/m/a"), "w")
    }

    func testAnUnreadableAssignmentsFileHereIsLeftAlone() throws {
        try write(#"{"/m/a": "P1"}"#, "profiles/assignments.json", in: source)
        try write("{not json", "profiles/assignments.json", in: destination)
        let summary = try StandaloneImport.run(from: source, to: destination, untouchedDefault: nil)
        XCTAssertEqual(summary.assignmentsAdded, 0)
        XCTAssertEqual(read("profiles/assignments.json"), "{not json")
    }
}
