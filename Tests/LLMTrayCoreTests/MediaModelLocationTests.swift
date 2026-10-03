import XCTest
@testable import LLMTrayCore

final class MediaModelLocationTests: XCTestCase {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func model(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url.appendingPathComponent("config.json"))
    }

    private let inPlace: (String) -> Bool = { FileManager.default.fileExists(atPath: $0 + "/config.json") }

    func testPreferredIsTheRepoUnderTheModelsFolder() {
        XCTAssertEqual(MediaModelLocation.preferred(repo: "org/name", root: "/m"), "/m/org/name")
    }

    func testResolvePrefersTheModelsFolderThenTheOldPlace() throws {
        let base = try temp()
        let root = base.appendingPathComponent("models").path
        let legacy = base.appendingPathComponent("app/mflux_models/x")
        // Nowhere yet: where a download goes.
        XCTAssertEqual(MediaModelLocation.resolve(repo: "o/x", root: root, legacy: legacy.path, isInPlace: inPlace), root + "/o/x")
        try model(legacy)
        XCTAssertEqual(MediaModelLocation.resolve(repo: "o/x", root: root, legacy: legacy.path, isInPlace: inPlace), legacy.path)
        try model(URL(fileURLWithPath: root + "/o/x"))
        XCTAssertEqual(MediaModelLocation.resolve(repo: "o/x", root: root, legacy: legacy.path, isInPlace: inPlace), root + "/o/x")
    }

    func testMigrationMovesACompleteOldCopyOnTheSameVolume() throws {
        let base = try temp()
        let root = base.appendingPathComponent("models").path
        let legacy = base.appendingPathComponent("app/voice_models/v")
        XCTAssertEqual(MediaModelLocation.migration(repo: "o/v", root: root, legacy: legacy.path, isInPlace: inPlace), .none)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertEqual(MediaModelLocation.migration(repo: "o/v", root: root, legacy: legacy.path, isInPlace: inPlace), .none, "incomplete")
        try model(legacy)
        XCTAssertEqual(MediaModelLocation.migration(repo: "o/v", root: root, legacy: legacy.path, isInPlace: inPlace),
                       .move(from: legacy.path, to: root + "/o/v"))
        // Something already at the target (even partial): left alone.
        try FileManager.default.createDirectory(atPath: root + "/o/v", withIntermediateDirectories: true)
        XCTAssertEqual(MediaModelLocation.migration(repo: "o/v", root: root, legacy: legacy.path, isInPlace: inPlace), .none)
    }

    func testSameVolume() throws {
        let base = try temp()
        XCTAssertTrue(MediaModelLocation.sameVolume(base.path, base.appendingPathComponent("missing/deeper").path))
        // /dev is its own file system (devfs).
        XCTAssertFalse(MediaModelLocation.sameVolume(base.path, "/dev/fd"))
    }

    func testPartialFoldersAndRepoMatching() {
        XCTAssertTrue(MediaModelLocation.isPartial("model.partial"))
        XCTAssertTrue(MediaModelLocation.isPartial("model.partial-1234"))
        XCTAssertFalse(MediaModelLocation.isPartial("model-partial"))
        XCTAssertTrue(MediaModelLocation.isOneOf(["Org/Name"], path: "/m/org/name", root: "/m"))
        XCTAssertTrue(MediaModelLocation.isOneOf(["org/name"], path: "/m/org/name/", root: "/m/"))
        XCTAssertFalse(MediaModelLocation.isOneOf(["org/name"], path: "/m/org/name-2", root: "/m"))
        XCTAssertFalse(MediaModelLocation.isOneOf(["org/name"], path: "/x/org/name", root: "/m"))
    }
}
