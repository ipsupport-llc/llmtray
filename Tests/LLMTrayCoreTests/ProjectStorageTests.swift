import XCTest
@testable import LLMTrayCore

final class ProjectStorageTests: XCTestCase {
    private var root: String!
    private var storage: ProjectStorage!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "llmtray-projects-\(UUID().uuidString)/projects"
        storage = ProjectStorage(root: root)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: (root as NSString).deletingLastPathComponent)
    }

    private func makeDirectory(_ id: UUID) throws {
        try fm.createDirectory(atPath: storage.directory(for: id) + "/files", withIntermediateDirectories: true)
        fm.createFile(atPath: storage.directory(for: id) + "/files/1.pdf", contents: Data("x".utf8))
    }

    func testRecordsInAListing() {
        let a = UUID(), b = UUID()
        let names = [a.uuidString, a.uuidString + ".deleting", b.uuidString + ".deleting", "notes.deleting", ".DS_Store", b.uuidString]
        XCTAssertEqual(Set(ProjectStorage.deletionRecords(in: names)), [a, b])
        XCTAssertEqual(ProjectStorage.deletionRecords(in: [a.uuidString]), [], "a directory alone is no record")
    }

    func testDeletionRemovesTheDirectoryThenTheRecord() throws {
        let id = UUID()
        try makeDirectory(id)
        XCTAssertTrue(storage.beginDeletion(id))
        XCTAssertEqual(storage.pendingDeletions(library: .loaded), [id])
        XCTAssertTrue(storage.finishDeletion(id))
        XCTAssertFalse(fm.fileExists(atPath: storage.directory(for: id)))
        XCTAssertEqual(storage.pendingDeletions(library: .loaded), [])
    }

    func testDeletionWithoutADirectory() {
        // A project that never had files: the root is made for the record.
        let id = UUID()
        XCTAssertTrue(storage.beginDeletion(id))
        XCTAssertTrue(storage.finishDeletion(id))
        XCTAssertEqual(storage.pendingDeletions(library: .missing), [])
    }

    func testACrashAfterTheRecordIsFinishedLater() throws {
        let deleted = UUID(), orphan = UUID(), kept = UUID()
        try makeDirectory(deleted)
        try makeDirectory(orphan)   // no project, no record
        try makeDirectory(kept)
        storage.beginDeletion(deleted)
        // Next launch: only the recorded one goes.
        let pending = storage.pendingDeletions(library: .loaded)
        XCTAssertEqual(pending, [deleted])
        pending.forEach { storage.finishDeletion($0) }
        XCTAssertFalse(fm.fileExists(atPath: storage.directory(for: deleted)))
        XCTAssertTrue(fm.fileExists(atPath: storage.directory(for: orphan) + "/files/1.pdf"), "never swept")
        XCTAssertTrue(fm.fileExists(atPath: storage.directory(for: kept)))
    }

    func testNothingIsDoneWhenTheLibraryIsUnreadable() throws {
        let id = UUID()
        try makeDirectory(id)
        storage.beginDeletion(id)
        XCTAssertEqual(storage.pendingDeletions(library: .unreadable), [])
        XCTAssertEqual(storage.pendingDeletions(library: .missing), [id], "no library.json at all: still finished")
    }

    func testNoRecordNoDeletionOfADirectory() throws {
        let id = UUID(), empty = UUID()
        try makeDirectory(id)
        // The record can't be written (a read-only projects directory).
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root) }
        XCTAssertFalse(storage.beginDeletion(id), "a directory, and no record: stop")
        XCTAssertTrue(storage.beginDeletion(empty), "nothing on disk to leave behind")
    }

    func testNoRootNoRecords() {
        XCTAssertEqual(storage.pendingDeletions(library: .loaded), [])
    }
}
