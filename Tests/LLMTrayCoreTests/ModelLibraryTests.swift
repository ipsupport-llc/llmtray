import XCTest
@testable import LLMTrayCore

final class ModelLibraryTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "ModelLibraryTests-\(UUID())"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testUsageIsRecordedAtMostOncePerMinute() {
        let store = ModelUsageStore(defaults: defaults())
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(store.lastUsed("/m/a"))
        XCTAssertTrue(store.record("/m/a", at: t0))
        XCTAssertFalse(store.record("/m/a", at: t0.addingTimeInterval(30)))
        XCTAssertEqual(store.lastUsed("/m/a"), t0)
        XCTAssertTrue(store.record("/m/a", at: t0.addingTimeInterval(61)))
        XCTAssertEqual(store.lastUsed("/m/a"), t0.addingTimeInterval(61))
        // A clock set back still records.
        XCTAssertTrue(store.record("/m/a", at: t0))
        // Per model.
        XCTAssertTrue(store.record("/m/b", at: t0))
        store.forget("/m/a")
        XCTAssertNil(store.lastUsed("/m/a"))
        XCTAssertEqual(store.lastUsed("/m/b"), t0)
    }

    private func tree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for model in ["org/a", "org/b", "solo"] {
            let dir = root.appendingPathComponent(model)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        }
        addTeardownBlock { try? fm.removeItem(at: root) }
        return root
    }

    func testOnlyModelFoldersInsideTheRootMayBeRemoved() throws {
        let root = try tree()
        let r = root.path
        XCTAssertEqual(try ModelRemoval.check(modelPath: r + "/org/a", root: r).lastPathComponent, "a")
        XCTAssertEqual(try ModelRemoval.check(modelPath: r + "/solo", root: r).lastPathComponent, "solo")
        XCTAssertThrowsError(try ModelRemoval.check(modelPath: r, root: r)) { XCTAssertEqual($0 as? ModelRemoval.Refusal, .outsideModelsFolder) }
        XCTAssertThrowsError(try ModelRemoval.check(modelPath: r + "/org/a/..", root: r)) { XCTAssertEqual($0 as? ModelRemoval.Refusal, .notAModel) }
        XCTAssertThrowsError(try ModelRemoval.check(modelPath: r + "/org/../..", root: r)) { XCTAssertEqual($0 as? ModelRemoval.Refusal, .outsideModelsFolder) }
        XCTAssertThrowsError(try ModelRemoval.check(modelPath: "/tmp", root: r)) { XCTAssertEqual($0 as? ModelRemoval.Refusal, .outsideModelsFolder) }
        // The org folder holds no config.json: not a model.
        XCTAssertThrowsError(try ModelRemoval.check(modelPath: r + "/org", root: r)) { XCTAssertEqual($0 as? ModelRemoval.Refusal, .notAModel) }
    }

    func testALinkedModelIsRemovedAsTheLink() throws {
        let root = try tree()
        let elsewhere = try tree().appendingPathComponent("org/a")
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        let url = try ModelRemoval.check(modelPath: link.path, root: root.path)
        XCTAssertEqual(url.lastPathComponent, "linked")
        XCTAssertEqual(url.deletingLastPathComponent().resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
    }

    func testEmptyOrgFolderIsLeftForRemovalButNotTheRoot() throws {
        let root = try tree()
        let fm = FileManager.default
        let a = try ModelRemoval.check(modelPath: root.path + "/org/a", root: root.path)
        try fm.removeItem(at: a)
        XCTAssertEqual(ModelRemoval.emptyParents(of: a, root: root.path), [], "org still holds b")
        let b = try ModelRemoval.check(modelPath: root.path + "/org/b", root: root.path)
        try fm.removeItem(at: b)
        try Data().write(to: b.deletingLastPathComponent().appendingPathComponent(".DS_Store"))
        XCTAssertEqual(ModelRemoval.emptyParents(of: b, root: root.path).map(\.lastPathComponent), ["org"])
        let solo = try ModelRemoval.check(modelPath: root.path + "/solo", root: root.path)
        try fm.removeItem(at: solo)
        XCTAssertEqual(ModelRemoval.emptyParents(of: solo, root: root.path), [], "never the root")
    }

    func testSameOrInside() {
        XCTAssertTrue(ModelRemoval.isSameOrInside("/m/org/a", "/m/org/a"))
        XCTAssertTrue(ModelRemoval.isSameOrInside("/m/org/a", "/m/org"))
        XCTAssertTrue(ModelRemoval.isSameOrInside("/m/org/a/", "/m/org"))
        XCTAssertFalse(ModelRemoval.isSameOrInside("/m/org/a", "/m/org/ab"))
        XCTAssertFalse(ModelRemoval.isSameOrInside("/m/orga/b", "/m/org"))
        XCTAssertFalse(ModelRemoval.isSameOrInside("/m/org", "/m/org/a"))
    }

    func testAddedDateIsTheFolderCreation() throws {
        let root = try tree()
        let added = try XCTUnwrap(ModelRemoval.addedDate(modelPath: root.path + "/org/a"))
        XCTAssertLessThan(abs(added.timeIntervalSinceNow), 60)
        XCTAssertNil(ModelRemoval.addedDate(modelPath: root.path + "/missing"))
    }
}
