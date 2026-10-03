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

    func testALinkedOrgFolderIsRefused() throws {
        // root/alias -> root/org: removing alias/a would remove org/a.
        let root = try tree()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("org"))
        XCTAssertThrowsError(try ModelRemoval.check(modelPath: root.path + "/alias/a", root: root.path)) {
            XCTAssertEqual($0 as? ModelRemoval.Refusal, .outsideModelsFolder)
        }
        XCTAssertNoThrow(try ModelRemoval.check(modelPath: root.path + "/org/a", root: root.path))
    }

    func testARootReachedThroughALinkStillWorks() throws {
        // The models folder set as a link (or /tmp vs /private/tmp).
        let root = try tree()
        let linkRoot = FileManager.default.temporaryDirectory.appendingPathComponent("root-link-\(UUID())")
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: linkRoot) }
        let url = try ModelRemoval.check(modelPath: linkRoot.path + "/org/a", root: linkRoot.path)
        XCTAssertEqual(url.resolvingSymlinksInPath(), root.appendingPathComponent("org/a").resolvingSymlinksInPath())
        XCTAssertNoThrow(try ModelRemoval.check(modelPath: root.resolvingSymlinksInPath().path + "/org/a", root: linkRoot.path))
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

    func testAMediaModelNeedsNoConfig() throws {
        // An image model's folder holds its parts, no config.json.
        let root = try tree()
        let image = root.appendingPathComponent("org/image")
        try FileManager.default.createDirectory(at: image.appendingPathComponent("transformer"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try ModelRemoval.check(modelPath: image.path, root: root.path))
        XCTAssertEqual(try ModelRemoval.check(modelPath: image.path, root: root.path, requireConfig: false).lastPathComponent, "image")
        // Still never the root, nor outside it, nor a file.
        XCTAssertThrowsError(try ModelRemoval.check(modelPath: root.path, root: root.path, requireConfig: false))
        try Data().write(to: root.appendingPathComponent("org/file"))
        XCTAssertThrowsError(try ModelRemoval.check(modelPath: root.path + "/org/file", root: root.path, requireConfig: false))
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
