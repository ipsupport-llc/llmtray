import Foundation
import XCTest
@testable import LLMTrayCore

/// A Trash in the test's temp folder: a rename, like the real one on the
/// same volume.
private extension ApprovedPlan {
    var items: [PlanItem] { plan.items }
    var id: UUID { plan.id }
}

/// Foundation's Trash moves by path: this one ignores `verify`, to show what
/// happens when the path names something else by the time it moves.
private final class RacyTrash: Trasher {
    let dir: String

    init(dir: String) {
        self.dir = dir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func trash(_ url: URL, coordinated: Bool, verify: (URL) -> Bool) throws -> URL? {
        let dest = dir + "/" + url.lastPathComponent
        try FileManager.default.moveItem(atPath: url.path, toPath: dest)
        return URL(fileURLWithPath: dest)
    }
}

private final class FakeTrash: Trasher {
    let dir: String
    var fail = false
    var coordinated: [Bool] = []

    init(dir: String) {
        self.dir = dir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func trash(_ url: URL, coordinated: Bool, verify: (URL) -> Bool) throws -> URL? {
        self.coordinated.append(coordinated)
        if fail { throw CocoaError(.featureUnsupported) }
        guard verify(url) else { throw FolderAccessError.changed(url.path) }
        let dest = dir + "/" + url.lastPathComponent + " " + UUID().uuidString.prefix(4)
        try FileManager.default.moveItem(atPath: url.path, toPath: dest)
        return URL(fileURLWithPath: dest)
    }
}

final class ChangePlanTests: FolderTestCase {
    private var journal: ChangeJournal!
    private var trash: FakeTrash!
    private let store = ChangePlanStore()
    private let allow: ChangeGrantCheck = { _ in true }

    override func setUpWithError() throws {
        try super.setUpWithError()
        journal = ChangeJournal(directory: URL(fileURLWithPath: base + "/journal"))
        trash = FakeTrash(dir: base + "/Trash")
    }

    private var planner: ChangePlanner { ChangePlanner(denylist: denylist, canChange: allow) }
    private var executor: ChangeExecutor { ChangeExecutor(denylist: denylist, journal: journal, trasher: trash, canChange: allow) }
    private var undoer: ChangeUndo { ChangeUndo(denylist: denylist, journal: journal, canChange: allow) }

    private func mv(_ from: String, _ to: String) throws -> ChangeRequest { .move(from: try loc(from), to: try loc(to)) }
    private func md(_ path: String) throws -> ChangeRequest { .makeDir(try loc(path)) }
    private func rm(_ path: String) throws -> ChangeRequest { .trash(try loc(path)) }

    /// Plans `ops` into the chat's pending plan (nothing rejected), approves.
    /// `collision` is keyed by the op's index in `ops`.
    private func approved(_ ops: [ChangeRequest], items: Set<Int>? = nil,
                          collision: [Int: CollisionPolicy] = [:]) throws -> ApprovedPlan {
        let ids = try add(ops)
        for (index, p) in collision { store.setCollision(p, item: ids[index], chatID: "c") }
        return try approveNow(items)
    }

    /// Plans `ops` into the chat's pending plan (nothing rejected); the ids
    /// the store gave them.
    @discardableResult
    private func add(_ ops: [ChangeRequest]) throws -> [Int] {
        let r = try planner.plan(ops, after: store.pending(chatID: "c")?.items ?? [])
        XCTAssertTrue(r.rejected.isEmpty, "\(r.rejected.map { "\($0.index): \($0.error)" })")
        return Array(store.add(r.items, chatID: "c").items.suffix(r.items.count).map(\.id))
    }

    /// Approves the pending plan at the revision it has now (what the user
    /// just reviewed).
    private func approveNow(_ items: Set<Int>? = nil) throws -> ApprovedPlan {
        try store.approve(chatID: "c", planID: store.pending(chatID: "c")?.id ?? UUID(),
                          revision: store.pending(chatID: "c")?.revision ?? 0, items: items, validator: planner)
    }

    private func statuses(_ r: ChangeExecutor.Report) -> [String] {
        r.outcomes.map {
            switch $0.status {
            case .done: return "done"
            case .failed: return "failed"
            case .uncertain: return "uncertain"
            case .notRun: return "notRun"
            }
        }
    }

    // MARK: Planning and approval

    func testOneOpsListIsThePlan() throws {
        write("a.pdf", "a")
        write("b.pdf", "b")
        write("c.tmp", "c")
        let plan = try approved([md("2024"), md("2024/q1"), mv("a.pdf", "2024/q1/a.pdf"), mv("b.pdf", "2024/b.pdf"), rm("c.tmp")])
        XCTAssertEqual(plan.items.map(\.kind), [.makeDir, .makeDir, .move, .move, .trash])
        XCTAssertEqual(plan.items.map(\.dependsOn), [[], [1], [1, 2], [1], []])
        XCTAssertNil(store.pending(chatID: "c"), "approval takes the plan out")
        let report = executor.execute(plan)
        XCTAssertEqual(statuses(report), ["done", "done", "done", "done", "done"])
        XCTAssertNil(report.stoppedAt)
        XCTAssertEqual(names(), ["2024", "denied"])
        XCTAssertEqual(names("2024"), ["b.pdf", "q1"])
        XCTAssertEqual(names("2024/q1"), ["a.pdf"])
        XCTAssertEqual(trash.coordinated, [false])
        let record = try XCTUnwrap(journal.record(plan.id))
        XCTAssertFalse(record.isIncomplete)
        XCTAssertEqual(record.chatID, "c")
        XCTAssertEqual(record.items.count, 5)
        guard case .done(let r) = record.items[4].state else { return XCTFail() }
        XCTAssertNotNil(r.trashURL)
    }

    func testBadOpsAreRejectedOneByOne() throws {
        write("a.txt", "a")
        write("taken/x", "x")
        mkdir("existing")
        let r = try planner.plan([
            mv("missing.txt", "b.txt"),          // no source
            mv("a.txt", "nowhere/a.txt"),        // parent neither exists nor planned
            mv("a.txt", "a.txt"),                // where it is
            mv("denied/secret.txt", "s.txt"),    // denied: invisible
            md("existing"),                      // already there
            mv("a.txt", "b.txt"),                // fine
            rm("a.txt"),                         // already in the plan
            mv("taken", "taken/inner"),          // into itself
            md(".ssh"),                          // a denied name would hide it
            mv("taken", "login.keychain")
        ])
        XCTAssertEqual(r.items.count, 1)
        XCTAssertEqual(r.rejected.map(\.index), [0, 1, 2, 3, 4, 6, 7, 8, 9])
        XCTAssertThrowsError(try loc("../outside/x"))
        XCTAssertThrowsError(try planner.plan([mv("a.txt", "b.txt")], temporaryChat: true)) {
            XCTAssertEqual($0 as? ChangePlanError, .temporaryChat)
        }
    }

    func testPlansAccumulateAcrossTurnsAndApprovalCanBePartial() throws {
        write("a.txt", "a")
        write("b.txt", "b")
        let turn1 = try planner.plan([md("new"), mv("a.txt", "new/a.txt")])
        store.add(turn1.items, chatID: "c")
        let turn2 = try planner.plan([mv("b.txt", "new/b.txt")], after: store.pending(chatID: "c")!.items)
        XCTAssertEqual(turn2.items.map(\.id), [3])
        XCTAssertEqual(turn2.items[0].dependsOn, [1], "a folder planned in an earlier turn")
        store.add(turn2.items, chatID: "c")
        XCTAssertEqual(store.pending(chatID: "c")?.items.count, 3)
        XCTAssertThrowsError(try approveNow([2])) {
            XCTAssertEqual($0 as? ChangePlanError, .missingDependency(item: 2, needs: 1))
        }
        XCTAssertThrowsError(try approveNow([9])) {
            XCTAssertEqual($0 as? ChangePlanError, .unknownItems([9]))
        }
        XCTAssertNotNil(store.pending(chatID: "c"), "a refused approval leaves it pending")
        let plan = try approveNow([1, 3])
        XCTAssertEqual(plan.items.map(\.id), [1, 3])
        XCTAssertEqual(statuses(executor.execute(plan)), ["done", "done"])
        XCTAssertTrue(exists("a.txt"))
        XCTAssertTrue(exists("new/b.txt"))
        store.add(try planner.plan([rm("a.txt")]).items, chatID: "c")
        store.cancel(chatID: "c")
        XCTAssertThrowsError(try approveNow()) { XCTAssertEqual($0 as? ChangePlanError, .nothingPending) }
    }

    func testAnItemThatChangedCantBeApproved() throws {
        write("a.txt", "a")
        let r = try planner.plan([rm("a.txt")])
        store.add(r.items, chatID: "c")
        try fm.removeItem(atPath: grant + "/a.txt")
        write("a.txt", "another file, same name")
        let invalid = planner.invalidItems(store.pending(chatID: "c")!)
        XCTAssertEqual(Array(invalid.keys), [1])
        XCTAssertThrowsError(try approveNow()) {
            guard case .invalidated(let m)? = $0 as? ChangePlanError else { return XCTFail("\($0)") }
            XCTAssertEqual(Array(m.keys), [1])
        }
    }

    // MARK: Checked at the moment of the operation

    func testASourceFolderSwappedForASymlinkFailsClosed() throws {
        write("a/file.txt", "inside")
        mkdir("b")
        write("file.txt", "outside", in: outside)
        let plan = try approved([mv("a/file.txt", "b/file.txt")])
        // Between approval and execution "a" becomes a link to outside.
        try fm.moveItem(atPath: grant + "/a", toPath: base + "/a-moved")
        try fm.createSymbolicLink(atPath: grant + "/a", withDestinationPath: outside)
        let report = executor.execute(plan)
        XCTAssertEqual(statuses(report), ["failed"])
        XCTAssertEqual(report.stoppedAt, 1)
        XCTAssertEqual(try String(contentsOfFile: outside + "/file.txt"), "outside")
        XCTAssertEqual(names("b"), [])
    }

    func testADestinationSwappedForASymlinkFailsClosed() throws {
        write("x.txt", "x")
        mkdir("b")
        let plan = try approved([mv("x.txt", "b/x.txt")])
        try fm.removeItem(atPath: grant + "/b")
        try fm.createSymbolicLink(atPath: grant + "/b", withDestinationPath: outside)
        XCTAssertEqual(statuses(executor.execute(plan)), ["failed"])
        XCTAssertTrue(exists("x.txt"))
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: outside)) ?? ["?"], [])
    }

    func testAReplacedItemIsNotTouched() throws {
        write("a.txt", "original")
        let plan = try approved([rm("a.txt")])
        try fm.removeItem(atPath: grant + "/a.txt")
        write("a.txt", "a new file with the old name")
        XCTAssertEqual(statuses(executor.execute(plan)), ["failed"])
        XCTAssertEqual(try String(contentsOfFile: grant + "/a.txt"), "a new file with the old name")
        XCTAssertEqual(trash.coordinated, [], "never reached the Trash")
    }

    // MARK: Names decided by the file system

    func testKeepBothRetriesWithNumberedNames() throws {
        write("in/a.txt", "new")
        write("in/b.txt", "new b")
        write("out/a.txt", "old")
        write("out/a 2.txt", "old 2")
        mkdir("2024")
        var plan = try approved([mv("in/a.txt", "out/a.txt")])
        let refused = executor.execute(plan)
        XCTAssertEqual(statuses(refused), ["failed"])
        guard case .failed(let why) = refused.outcomes[0].status else { return XCTFail() }
        XCTAssertTrue(why.contains("already exists"), why)
        plan = try approved([mv("in/a.txt", "out/a.txt")], collision: [0: .keepBoth])
        guard case .done(let r) = executor.execute(plan).outcomes[0].status else { return XCTFail() }
        XCTAssertEqual(r.finalName, "a 3.txt")
        XCTAssertEqual(try String(contentsOfFile: grant + "/out/a.txt"), "old", "never overwritten")
        // A folder made under a numbered name: later items follow it.
        let p2 = try planner.plan([md("2024"), mv("in/b.txt", "2024/b.txt")])
        XCTAssertEqual(p2.rejected.count, 1, "make_dir of an existing folder is refused when planned")
        // Taken after planning: keep-both makes "2024 2" and the move follows.
        try fm.removeItem(atPath: grant + "/2024")
        let ids = try add([md("2024"), mv("in/b.txt", "2024/b.txt")])
        store.setCollision(.keepBoth, item: ids[0], chatID: "c")
        let p3 = try approveNow()
        mkdir("2024")
        write("2024/b.txt", "someone else's")
        XCTAssertEqual(statuses(executor.execute(p3)), ["done", "done"])
        XCTAssertEqual(try String(contentsOfFile: grant + "/2024 2/b.txt"), "new b")
        XCTAssertEqual(try String(contentsOfFile: grant + "/2024/b.txt"), "someone else's")
    }

    func testNumberedNames() {
        XCTAssertEqual(ChangeExecutor.numberedName("a.txt", 2, isDirectory: false), "a 2.txt")
        XCTAssertEqual(ChangeExecutor.numberedName("archive.tar.gz", 3, isDirectory: false), "archive.tar 3.gz")
        XCTAssertEqual(ChangeExecutor.numberedName("Tool.app", 2, isDirectory: false), "Tool 2.app")
        XCTAssertEqual(ChangeExecutor.numberedName("v1.2", 2, isDirectory: true), "v1.2 2")
        XCTAssertEqual(ChangeExecutor.numberedName(".bashrc", 2, isDirectory: false), ".bashrc 2")
        let long = ChangeExecutor.numberedName(String(repeating: "я", count: 127) + ".txt", 12, isDirectory: false)
        XCTAssertLessThanOrEqual(long.utf8.count, 255)
        XCTAssertTrue(long.hasSuffix(" 12.txt"))
    }

    func testCaseCollisionsAreTheFileSystemsCall() throws {
        write("src/report.txt", "new")
        write("dst/Report.txt", "old")
        let insensitive = volumeIsCaseInsensitive
        let report = executor.execute(try approved([mv("src/report.txt", "dst/report.txt")]))
        if insensitive {
            XCTAssertEqual(statuses(report), ["failed"], "Report.txt and report.txt are one name here")
            XCTAssertEqual(try String(contentsOfFile: grant + "/dst/Report.txt"), "old")
        } else {
            XCTAssertEqual(statuses(report), ["done"])
            XCTAssertEqual(names("dst"), ["Report.txt", "report.txt"])
        }
        // A case-only rename works either way.
        write("notes.txt", "n")
        XCTAssertEqual(statuses(executor.execute(try approved([mv("notes.txt", "NOTES.txt")]))), ["done"])
        XCTAssertTrue(names().contains("NOTES.txt"))
        XCTAssertFalse(names().contains("notes.txt"))
    }

    func testComposedAndDecomposedNames() throws {
        let nfc = "caf\u{E9}.txt", nfd = "cafe\u{301}.txt"
        XCTAssertEqual(nfc, nfd, "Swift calls them equal -- which is why names are compared by the file system")
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))
        write("dst/" + nfc, "old")
        write("src/" + nfd, "new")
        // What this volume does with the other spelling, asked directly.
        let sameName = Posix.lstatPath(grant + "/dst/" + nfd) != nil
        let report = executor.execute(try approved([mv("src/" + nfd, "dst/" + nfd)]))
        if sameName {
            XCTAssertEqual(statuses(report), ["failed"])
            XCTAssertEqual(try String(contentsOfFile: grant + "/dst/" + nfc), "old")
        } else {
            XCTAssertEqual(statuses(report), ["done"])
        }
        // A normalization-only rename: the item itself, not a collision.
        write("n/" + nfc, "x")
        XCTAssertEqual(statuses(executor.execute(try approved([mv("n/" + nfc, "n/" + nfd)]))), ["done"])
        let entries = try fm.contentsOfDirectory(atPath: grant + "/n")
        XCTAssertEqual(entries.count, 1)
    }

    // MARK: Failures, journal, undo

    func testStopsAtTheFirstFailureAndUndoReversesWhatRan() throws {
        for n in ["a", "b", "c", "d"] { write("\(n).txt", n) }
        let plan = try approved([md("new"), mv("a.txt", "new/a.txt"), mv("b.txt", "new/b.txt"),
                                 mv("c.txt", "new/c.txt"), rm("d.txt")])
        try fm.removeItem(atPath: grant + "/c.txt")
        let report = executor.execute(plan)
        XCTAssertEqual(statuses(report), ["done", "done", "done", "failed", "notRun"])
        XCTAssertEqual(report.stoppedAt, 4)
        XCTAssertTrue(exists("d.txt"), "after a failure nothing more runs")
        let record = try XCTUnwrap(journal.record(plan.id))
        XCTAssertFalse(record.isIncomplete, "a failure is an outcome")
        XCTAssertEqual(record.items.count, 4, "the item that never ran isn't journaled")
        // Newest first; the made folder isn't empty until the moves are undone.
        XCTAssertEqual(undoer.reversibility(plan.id).map(\.reversible), [true, true, false])
        let undo = undoer.undo(plan.id)
        XCTAssertNil(undo.stopped)
        XCTAssertEqual(undo.undone, [3, 2, 1])
        XCTAssertEqual(undo.remaining, [])
        XCTAssertEqual(names(), ["a.txt", "b.txt", "d.txt", "denied"])
        // Undone items stay undone.
        XCTAssertEqual(undoer.undo(plan.id).undone, [])
    }

    func testUndoStopsAtAConflictAndSaysWhatRemains() throws {
        write("a.txt", "a")
        write("b.txt", "b")
        let plan = try approved([md("X"), mv("a.txt", "X/a.txt"), mv("b.txt", "X/b.txt")])
        XCTAssertEqual(executor.execute(plan).doneCount, 3)
        write("b.txt", "a new b where the old one was")
        let undo = undoer.undo(plan.id)
        XCTAssertEqual(undo.undone, [])
        XCTAssertEqual(undo.stopped?.id, 3)
        XCTAssertEqual(undo.remaining.map(\.id), [3, 2, 1])
        XCTAssertEqual(undo.remaining.map(\.reversible), [false, true, false])
        XCTAssertEqual(try String(contentsOfFile: grant + "/b.txt"), "a new b where the old one was")
        // Moved by the user since: not ours to move back.
        try fm.removeItem(atPath: grant + "/b.txt")
        try fm.moveItem(atPath: grant + "/X/a.txt", toPath: grant + "/elsewhere.txt")
        let again = undoer.undo(plan.id)
        XCTAssertEqual(again.undone, [3])
        XCTAssertEqual(again.stopped?.id, 2)
        XCTAssertTrue(again.stopped?.reason?.contains("moved or replaced") ?? false)
        XCTAssertTrue(exists("elsewhere.txt"))
    }

    func testTrashFailureIsAFailureNeverADelete() throws {
        write("keep.txt", "k")
        trash.fail = true
        let report = executor.execute(try approved([rm("keep.txt")]))
        XCTAssertEqual(statuses(report), ["failed"])
        XCTAssertEqual(try String(contentsOfFile: grant + "/keep.txt"), "k")
    }

    func testTrashAndPutBack() throws {
        write("old.log", "log")
        let plan = try approved([rm("old.log")])
        guard case .done(let r) = executor.execute(plan).outcomes[0].status else { return XCTFail() }
        XCTAssertFalse(exists("old.log"))
        XCTAssertEqual(r.trashURL.map { (try? String(contentsOfFile: $0)) ?? "" }, "log")
        write("old.log", "a new one")
        XCTAssertEqual(undoer.undo(plan.id).stopped?.id, 1, "the name is taken: not overwritten")
        try fm.removeItem(atPath: grant + "/old.log")
        XCTAssertEqual(undoer.undo(plan.id).undone, [1])
        XCTAssertEqual(try String(contentsOfFile: grant + "/old.log"), "log")
    }

    func testTheSystemTrashAndRestore() throws {
        // A file made here for this test, and nothing else, goes to the
        // user's Trash -- and is put back.
        let name = "llmtray-test-\(UUID().uuidString).txt"
        write(name, "trash me")
        let exec = ChangeExecutor(denylist: denylist, journal: journal, trasher: SystemTrasher(), canChange: allow)
        let plan = try approved([rm(name)])
        let report = exec.execute(plan)
        guard case .done(let r) = report.outcomes[0].status else {
            if case .failed(let why) = report.outcomes[0].status {
                XCTAssertTrue(exists(name), "a failed trash leaves the file")
                throw XCTSkip("FileManager.trashItem is unavailable here: \(why)")
            }
            return XCTFail()
        }
        defer { if let t = r.trashURL, fm.fileExists(atPath: t) { try? fm.removeItem(atPath: t) } }
        XCTAssertFalse(exists(name))
        let trashURL = try XCTUnwrap(r.trashURL)
        XCTAssertEqual(Posix.lstatPath(trashURL)?.identity, r.identity)
        let undo = undoer.undo(plan.id)
        XCTAssertEqual(undo.undone, [1], "\(undo)")
        XCTAssertEqual(try String(contentsOfFile: grant + "/" + name), "trash me")
        XCTAssertFalse(fm.fileExists(atPath: trashURL))
    }

    func testACrashMidPlanShowsAsIncomplete() throws {
        write("a.txt", "a")
        let plan = try approved([mv("a.txt", "b.txt")])
        try journal.append(JournalEvent(kind: .begin, date: Date(), chatID: "c"), planID: plan.id)
        try journal.append(JournalEvent(kind: .pending, date: Date(), item: 1, planItem: plan.items[0]), planID: plan.id)
        // A torn line from a crash mid-write.
        let h = try FileHandle(forWritingTo: journal.url(for: plan.id))
        h.seekToEndOfFile()
        h.write(Data("{\"kind\":\"do".utf8))
        try h.close()
        let record = try XCTUnwrap(journal.record(plan.id))
        XCTAssertTrue(record.isIncomplete)
        XCTAssertEqual(record.items.map(\.state), [.incomplete])
        XCTAssertEqual(undoer.reversibility(plan.id), [.init(id: 1, reversible: false, reason: "interrupted: its outcome is unknown")])
        XCTAssertEqual(undoer.undo(plan.id).undone, [])
        XCTAssertEqual(journal.records().map(\.planID), [plan.id])
    }

    func testNoJournalNoChange() throws {
        write("a.txt", "a")
        // The journal's folder can't be made: a file is in the way.
        fm.createFile(atPath: base + "/blocked", contents: Data())
        let exec = ChangeExecutor(denylist: denylist, journal: ChangeJournal(directory: URL(fileURLWithPath: base + "/blocked/j")),
                                  trasher: trash, canChange: allow)
        let report = exec.execute(try approved([mv("a.txt", "b.txt")]))
        XCTAssertEqual(statuses(report), ["failed"])
        XCTAssertTrue(exists("a.txt"))
        XCTAssertFalse(exists("b.txt"))
    }

    func testNotesForTheReview() throws {
        let target = write("real.txt", "r", in: outside)
        try fm.linkItem(atPath: target, toPath: grant + "/linked.txt")
        write("Tool.app/Contents/x", "x")
        let r = try planner.plan([rm("linked.txt"), mv("Tool.app", "Tool2.app")])
        XCTAssertTrue(r.items[0].source!.hardLinked)
        XCTAssertTrue(r.items[0].notes.contains { $0.contains("hard link") })
        XCTAssertEqual(r.items[1].source?.kind, .package)
        XCTAssertEqual(r.items[1].summary, "move Tool.app to Tool2.app")
        store.add(r.items, chatID: "c")
        XCTAssertEqual(statuses(executor.execute(try approveNow())), ["done", "done"])
        XCTAssertTrue(exists("Tool2.app/Contents/x"), "a package moves as one item")
        XCTAssertEqual(try String(contentsOfFile: target), "r", "the other name keeps the file")
    }

    // MARK: Review findings: binding, check-to-use, durability

    func testApprovalIsBoundToTheReviewedRevision() throws {
        write("a.txt", "a")
        write("b.txt", "b")
        store.add(try planner.plan([rm("a.txt")]).items, chatID: "c")
        let reviewed = try XCTUnwrap(store.pending(chatID: "c")?.revision)
        // The model adds to the plan while the user looks at it.
        store.add(try planner.plan([rm("b.txt")], after: store.pending(chatID: "c")!.items).items, chatID: "c")
        XCTAssertThrowsError(try store.approve(chatID: "c", planID: store.pending(chatID: "c")!.id, revision: reviewed, validator: planner)) {
            XCTAssertEqual($0 as? ChangePlanError, .stale(reviewed: reviewed, current: reviewed + 1))
        }
        let next = store.pending(chatID: "c")!.revision
        store.setCollision(.keepBoth, item: 1, chatID: "c")
        XCTAssertThrowsError(try store.approve(chatID: "c", planID: store.pending(chatID: "c")!.id, revision: next, validator: planner))
        XCTAssertEqual(try approveNow().items.count, 2)
    }

    func testASourceSwappedBetweenCheckAndRenameGoesBack() throws {
        write("a.txt", "mine")
        let plan = try approved([mv("a.txt", "b.txt")])
        var exec = executor
        exec.beforeOperation = { _ in
            try? self.fm.moveItem(atPath: self.grant + "/a.txt", toPath: self.base + "/a-original.txt")
            self.write("a.txt", "intruder")
        }
        let report = exec.execute(plan)
        XCTAssertEqual(statuses(report), ["failed"])
        XCTAssertEqual(try String(contentsOfFile: grant + "/a.txt"), "intruder", "put back where it was")
        XCTAssertFalse(exists("b.txt"))
        XCTAssertFalse(journal.record(plan.id)!.isIncomplete, "nothing of the plan changed: a plain failure")
    }

    /// Past every check, inside the Trash call (one that moves by path
    /// without verifying): the item is taken from where it was staged and
    /// another file put in its place.
    private func swapInIntruder(_ url: URL) {
        try? fm.moveItem(atPath: url.path, toPath: base + "/a-original.txt")
        fm.createFile(atPath: url.path, contents: Data("intruder".utf8))
    }

    func testATrashSwapIsPutBack() throws {
        write("a.txt", "mine")
        let plan = try approved([rm("a.txt")])
        var staged = ""
        let exec = ChangeExecutor(denylist: denylist, journal: journal,
                                  trasher: HookedTrash(RacyTrash(dir: base + "/RacyTrash"), before: {
                                      staged = $0.path
                                      self.swapInIntruder($0)
                                  }), canChange: allow)
        // What went isn't the item: it goes back where it was taken from; the
        // item itself was taken by someone else, and that is said.
        XCTAssertEqual(statuses(exec.execute(plan)), ["uncertain"])
        XCTAssertEqual(try String(contentsOfFile: staged), "intruder")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: base + "/RacyTrash"), [])
    }

    func testAnUnconfirmedTrashIsUncertainNotFailed() throws {
        write("a.txt", "mine")
        let plan = try approved([rm("a.txt")])
        // The swapped-in item goes to the Trash and its name is taken again:
        // it can't be put back, and that is said, not hidden.
        let exec = ChangeExecutor(denylist: denylist, journal: journal,
                                  trasher: HookedTrash(RacyTrash(dir: base + "/RacyTrash"), before: swapInIntruder,
                                                       after: { self.fm.createFile(atPath: $0.path, contents: Data("third".utf8)) }), canChange: allow)
        let report = exec.execute(plan)
        XCTAssertEqual(statuses(report), ["uncertain"])
        let record = try XCTUnwrap(journal.record(plan.id))
        XCTAssertTrue(record.isIncomplete)
        guard case .uncertain = record.items[0].state else { return XCTFail("\(record.items[0].state)") }
        XCTAssertEqual(undoer.reversibility(plan.id).first?.reversible, false)
    }

    func testAJournalThatFailsAfterTheChangeStopsThePlan() throws {
        write("a.txt", "a")
        write("b.txt", "b")
        let plan = try approved([mv("a.txt", "a2.txt"), mv("b.txt", "b2.txt")])
        journal.appendHook = { if $0.kind == .done { throw CocoaError(.fileWriteOutOfSpace) } }
        let report = executor.execute(plan)
        journal.appendHook = nil
        XCTAssertEqual(statuses(report), ["uncertain", "notRun"])
        XCTAssertTrue(exists("b.txt"), "nothing after it ran")
        let record = try XCTUnwrap(journal.record(plan.id))
        XCTAssertTrue(record.isIncomplete)
        XCTAssertEqual(record.items.map(\.state), [.incomplete])
    }

    func testUndoTakesOnlyTheFolderItMade() throws {
        let plan = try approved([md("X")])
        XCTAssertEqual(executor.execute(plan).doneCount, 1)
        // Replaced by another (empty) folder of the same name.
        try fm.removeItem(atPath: grant + "/X")
        mkdir("X")
        let undo = undoer.undo(plan.id)
        XCTAssertEqual(undo.undone, [])
        XCTAssertEqual(undo.stopped?.id, 1)
        XCTAssertTrue(exists("X"), "not ours: left alone")
        XCTAssertEqual(names().filter { $0.hasPrefix(".llmtray") }, [])
    }

    func testTornJournalTailDoesNotSwallowTheNextEvent() throws {
        let id = UUID()
        try journal.append(JournalEvent(kind: .begin, date: Date(), chatID: "c"), planID: id)
        let h = try FileHandle(forWritingTo: journal.url(for: id))
        h.seekToEndOfFile()
        h.write(Data("{\"kind\":\"pend".utf8))
        try h.close()
        try journal.append(JournalEvent(kind: .end, date: Date()), planID: id)
        XCTAssertNotNil(journal.record(id)?.ended)
    }

    func testAnApprovalRunsOnce() throws {
        write("a.txt", "a")
        let plan = try approved([mv("a.txt", "b.txt")])
        XCTAssertEqual(statuses(executor.execute(plan)), ["done"])
        XCTAssertEqual(undoer.undo(plan.id).undone, [1])
        let again = executor.execute(plan)
        XCTAssertEqual(statuses(again), ["failed"])
        XCTAssertTrue(exists("a.txt"), "the undone change isn't redone without a new approval")
    }

    func testMakeDirLeavesNoStagingFolder() throws {
        mkdir("taken")
        XCTAssertEqual(statuses(executor.execute(try approved([md("new")]))), ["done"])
        store.add(try planner.plan([md("later")]).items, chatID: "c")
        let p = try approveNow()
        mkdir("later")
        XCTAssertEqual(statuses(executor.execute(p)), ["failed"], "taken since: not overwritten")
        XCTAssertEqual(names().filter { $0.hasPrefix(".llmtray") }, [])
        XCTAssertEqual(names(), ["denied", "later", "new", "taken"])
    }

    func testACrashDuringAMadeFolderUndoIsFinishedNextTime() throws {
        let plan = try approved([md("X"), md("Y")])
        XCTAssertEqual(executor.execute(plan).doneCount, 2)
        // As a crash leaves it: undo pending, the folder taken aside.
        for (item, name) in [(2, "Y"), (1, "X")] {
            try journal.append(JournalEvent(kind: .undoPending, date: Date(), item: item), planID: plan.id)
            try fm.moveItem(atPath: grant + "/" + name, toPath: grant + "/" + ChangeUndo.asideName(planID: plan.id, item: item))
        }
        // X got a file meanwhile: it's put back under its name, not removed.
        write(ChangeUndo.asideName(planID: plan.id, item: 1) + "/keep.txt", "k")
        let undo = undoer.undo(plan.id)
        XCTAssertEqual(undo.undone, [2])
        XCTAssertEqual(undo.stopped?.id, 1)
        XCTAssertEqual(names(), ["X", "denied"])
        XCTAssertTrue(exists("X/keep.txt"))
    }

    func testUndoneIsReportedOnlyOnceJournaled() throws {
        write("a.txt", "a")
        let plan = try approved([mv("a.txt", "b.txt")])
        XCTAssertEqual(executor.execute(plan).doneCount, 1)
        journal.appendHook = { if $0.kind == .undone { throw CocoaError(.fileWriteOutOfSpace) } }
        let first = undoer.undo(plan.id)
        journal.appendHook = nil
        XCTAssertEqual(first.undone, [])
        XCTAssertEqual(first.stopped?.id, 1)
        XCTAssertTrue(exists("a.txt"), "the move itself was undone")
        // The next undo sees it back and records it.
        XCTAssertEqual(undoer.undo(plan.id).undone, [1])
        guard case .undone = journal.record(plan.id)!.items[0].state else { return XCTFail() }
    }

    func testInterruptedUndoRecoveryDoesntGuess() throws {
        // A made folder gone from its place and not taken aside: removed, or
        // moved away by someone -- uncertain, not undone.
        let made = try approved([md("X")])
        XCTAssertEqual(executor.execute(made).doneCount, 1)
        try journal.append(JournalEvent(kind: .undoPending, date: Date(), item: 1), planID: made.id)
        try fm.moveItem(atPath: grant + "/X", toPath: grant + "/elsewhere")
        let r1 = undoer.undo(made.id)
        XCTAssertEqual(r1.undone, [])
        XCTAssertTrue(r1.stopped?.reason?.contains("needs a look") ?? false, "\(r1)")
        // A move whose item is back at its source by a hard link, still at
        // the destination: uncertain.
        write("a.txt", "a")
        let moved = try approved([mv("a.txt", "b.txt")])
        XCTAssertEqual(executor.execute(moved).doneCount, 1)
        try journal.append(JournalEvent(kind: .undoPending, date: Date(), item: moved.items[0].id), planID: moved.id)
        try fm.linkItem(atPath: grant + "/b.txt", toPath: grant + "/a.txt")
        let r2 = undoer.undo(moved.id)
        XCTAssertEqual(r2.undone, [])
        XCTAssertTrue(r2.stopped?.reason?.contains("both places") ?? false, "\(r2)")
        XCTAssertTrue(exists("b.txt"))
    }

    func testTheJournalMakesItsFoldersDurably() throws {
        let deep = ChangeJournal(directory: URL(fileURLWithPath: base + "/j1/j2/j3"))
        let id = UUID()
        try deep.append(JournalEvent(kind: .begin, date: Date(), chatID: "c"), planID: id)
        XCTAssertTrue(deep.exists(id))
        XCTAssertNotNil(deep.record(id))
        // Over the read cap: shown as incomplete, not read whole.
        deep.maxRecordBytes = 10
        XCTAssertNil(deep.record(id), "a cut first line isn't a begin")
    }

    func testAHeldFolderMovedOutOfTheGrantIsNotChangedThrough() throws {
        // Move: the destination folder leaves the grant while held open.
        write("a.txt", "a")
        mkdir("b")
        var exec = executor
        exec.beforeOperation = { _ in try? self.fm.moveItem(atPath: self.grant + "/b", toPath: self.outside + "/b") }
        XCTAssertEqual(statuses(exec.execute(try approved([mv("a.txt", "b/a.txt")]))), ["failed"])
        XCTAssertTrue(exists("a.txt"), "moved back")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside + "/b"), [])
        // make_dir: its parent leaves the grant.
        mkdir("p")
        exec.beforeOperation = { _ in try? self.fm.moveItem(atPath: self.grant + "/p", toPath: self.outside + "/p") }
        XCTAssertEqual(statuses(exec.execute(try approved([md("p/new")]))), ["failed"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside + "/p"), [], "taken back, staging removed")
        // Trash: the item's folder leaves the grant; the grant path no longer
        // names it, so nothing goes to the Trash.
        write("t/x.txt", "x")
        exec.beforeOperation = { _ in try? self.fm.moveItem(atPath: self.grant + "/t", toPath: self.outside + "/t") }
        XCTAssertEqual(statuses(exec.execute(try approved([rm("t/x.txt")]))), ["failed"])
        XCTAssertEqual(try String(contentsOfFile: outside + "/t/x.txt"), "x")
    }

    func testAPlanHasABoundedSize() throws {
        for n in 0..<3 { write("f\(n)", "x") }
        var p = planner
        p.maxItems = 2
        let r = try p.plan([rm("f0"), rm("f1"), rm("f2")])
        XCTAssertEqual(r.items.count, 2)
        XCTAssertEqual(r.rejected.map(\.index), [2])
    }

    // MARK: Review round 5: the Trash path, undo containment, rename-backs

    /// Runs `before` inside the Trash call, with the URL it was given, before
    /// it verifies and moves; `after` once it has moved.
    private final class HookedTrash: Trasher {
        let inner: Trasher
        let before: (URL) -> Void
        let after: (URL) -> Void
        init(_ inner: Trasher, before: @escaping (URL) -> Void = { _ in }, after: @escaping (URL) -> Void = { _ in }) {
            self.inner = inner
            self.before = before
            self.after = after
        }
        func trash(_ url: URL, coordinated: Bool, verify: (URL) -> Bool) throws -> URL? {
            before(url)
            let out = try inner.trash(url, coordinated: coordinated, verify: verify)
            after(url)
            return out
        }
    }

    /// Verifies, then runs `between`, then moves by path -- the window
    /// between `verify` and `trashItem`'s own path lookup.
    private final class VerifyThenMove: Trasher {
        let dir: String
        let between: (URL) -> Void
        init(dir: String, between: @escaping (URL) -> Void) {
            self.dir = dir
            self.between = between
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        func trash(_ url: URL, coordinated: Bool, verify: (URL) -> Bool) throws -> URL? {
            guard verify(url) else { throw FolderAccessError.changed(url.path) }
            between(url)
            let dest = dir + "/" + url.lastPathComponent
            try FileManager.default.moveItem(atPath: url.path, toPath: dest)
            return URL(fileURLWithPath: dest)
        }
    }

    /// The item's folder leaves the grant and a symlink to it takes its
    /// name: the grant's spelling still reaches the same folder and item.
    private func swapForSymlink(_ name: String) {
        try? fm.moveItem(atPath: grant + "/" + name, toPath: outside + "/" + name)
        try? fm.createSymbolicLink(atPath: grant + "/" + name, withDestinationPath: outside + "/" + name)
    }

    func testTheTrashPathIsCheckedAgainRightBeforeTheCall() throws {
        write("t/x.txt", "x")
        let plan = try approved([rm("t/x.txt")])
        var exec = executor
        exec.beforeOperation = { _ in self.swapForSymlink("t") }
        XCTAssertEqual(statuses(exec.execute(plan)), ["failed"])
        XCTAssertEqual(trash.coordinated, [], "the Trash isn't asked")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside + "/t"), ["x.txt"], "nothing made there")
    }

    func testTheTrashPathIsCheckedAgainInsideTheCall() throws {
        write("t/x.txt", "x")
        let plan = try approved([rm("t/x.txt")])
        let exec = ChangeExecutor(denylist: denylist, journal: journal,
                                  trasher: HookedTrash(trash, before: { _ in self.swapForSymlink("t") }), canChange: allow)
        XCTAssertEqual(statuses(exec.execute(plan)), ["failed"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside + "/t"), ["x.txt"], "back under its name, staging gone")
        XCTAssertEqual(try String(contentsOfFile: outside + "/t/x.txt"), "x")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: base + "/Trash"), [])
    }

    func testAPathRedirectedAfterVerifyingCantTrashAnythingElse() throws {
        write("t/x.txt", "mine")
        let plan = try approved([rm("t/x.txt")])
        var staging = ""
        // Between verify and the move: the folder leaves, and a symlink under
        // its name leads to a copy of the staging folder's path elsewhere.
        let exec = ChangeExecutor(denylist: denylist, journal: journal, trasher: VerifyThenMove(dir: base + "/Trash2") { url in
            staging = url.deletingLastPathComponent().lastPathComponent
            try? self.fm.moveItem(atPath: self.grant + "/t", toPath: self.outside + "/t")
            self.write("victim/\(staging)/x.txt", "victim", in: self.outside)
            try? self.fm.createSymbolicLink(atPath: self.grant + "/t", withDestinationPath: self.outside + "/victim")
        }, canChange: allow)
        XCTAssertEqual(statuses(exec.execute(plan)), ["failed"])
        XCTAssertTrue(staging.hasPrefix(".llmtray-trash-"), staging)
        XCTAssertEqual(try String(contentsOfFile: outside + "/victim/\(staging)/x.txt"), "victim", "what went is put back")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside + "/t"), ["x.txt"])
        XCTAssertEqual(try String(contentsOfFile: outside + "/t/x.txt"), "mine")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: base + "/Trash2"), [])
    }

    func testATrashWhoseFolderLeftTheGrantIsPutBack() throws {
        write("t/x.txt", "x")
        let plan = try approved([rm("t/x.txt")])
        let exec = ChangeExecutor(denylist: denylist, journal: journal, trasher: HookedTrash(trash, after: { _ in
            try? self.fm.moveItem(atPath: self.grant + "/t", toPath: self.outside + "/t")
        }), canChange: allow)
        XCTAssertEqual(statuses(exec.execute(plan)), ["failed"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside + "/t"), ["x.txt"], "put back where it came from")
        XCTAssertEqual(try String(contentsOfFile: outside + "/t/x.txt"), "x")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: base + "/Trash"), [])
        XCTAssertFalse(journal.record(plan.id)!.isIncomplete)
    }

    func testATrashLeavesNoStagingFolder() throws {
        write("t/x.txt", "x")
        XCTAssertEqual(statuses(executor.execute(try approved([rm("t/x.txt")]))), ["done"])
        XCTAssertEqual(names("t"), [])
        trash.fail = true
        write("t/y.txt", "y")
        XCTAssertEqual(statuses(executor.execute(try approved([rm("t/y.txt")]))), ["failed"])
        XCTAssertEqual(names("t"), ["y.txt"])
    }

    func testAHardLinkMadeAfterReviewInvalidatesTheItem() throws {
        write("a.txt", "a")
        store.add(try planner.plan([rm("a.txt")]).items, chatID: "c")
        // The review showed one name; now there are two.
        try fm.linkItem(atPath: grant + "/a.txt", toPath: outside + "/a-link.txt")
        XCTAssertThrowsError(try approveNow()) {
            guard case ChangePlanError.invalidated = $0 else { return XCTFail("\($0)") }
        }
        // Approved while it had one name, linked before it runs.
        try fm.removeItem(atPath: outside + "/a-link.txt")
        let plan = try approveNow()
        try fm.linkItem(atPath: grant + "/a.txt", toPath: outside + "/a-link.txt")
        XCTAssertEqual(statuses(executor.execute(plan)), ["failed"])
        XCTAssertTrue(exists("a.txt"))
    }

    private func assertStoppedPlainly(_ r: ChangeUndo.Report, _ planID: UUID, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.undone, [], file: file, line: line)
        XCTAssertEqual(r.stopped?.id, journal.record(planID)?.items.first?.planItem.id, file: file, line: line)
        XCTAssertFalse(r.stopped?.reason?.contains("needs a look") ?? true, "\(r)", file: file, line: line)
        guard case .done = journal.record(planID)?.items.first?.state else {
            return XCTFail("still done after a reverted undo", file: file, line: line)
        }
    }

    func testUndoDoesntChangeThroughAFolderThatLeftTheGrant() throws {
        var leaving = ""
        var u = undoer
        u.beforeOperation = { _ in try? self.fm.moveItem(atPath: self.grant + "/" + leaving, toPath: self.outside + "/" + leaving) }
        // Move back into a source folder that left.
        write("src/a.txt", "a")
        mkdir("dst")
        let p1 = try approved([mv("src/a.txt", "dst/a.txt")])
        XCTAssertEqual(executor.execute(p1).doneCount, 1)
        leaving = "src"
        assertStoppedPlainly(u.undo(p1.id), p1.id)
        XCTAssertTrue(exists("dst/a.txt"), "moved back where it was")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside + "/src"), [])
        // Move back out of a destination folder that left.
        write("s2/b.txt", "b")
        mkdir("d2")
        let p2 = try approved([mv("s2/b.txt", "d2/b.txt")])
        XCTAssertEqual(executor.execute(p2).doneCount, 1)
        leaving = "d2"
        assertStoppedPlainly(u.undo(p2.id), p2.id)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside + "/d2"), ["b.txt"])
        XCTAssertEqual(names("s2"), [])
        // Put back from the Trash into a folder that left.
        write("t/x.txt", "x")
        let p3 = try approved([rm("t/x.txt")])
        guard case .done(let r3) = executor.execute(p3).outcomes[0].status, let t3 = r3.trashURL else { return XCTFail() }
        leaving = "t"
        assertStoppedPlainly(u.undo(p3.id), p3.id)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside + "/t"), [])
        XCTAssertEqual(try String(contentsOfFile: t3), "x", "back in the Trash")
        // A made folder in a folder that left isn't removed.
        mkdir("p")
        let p4 = try approved([md("p/X")])
        XCTAssertEqual(executor.execute(p4).doneCount, 1)
        leaving = "p"
        assertStoppedPlainly(u.undo(p4.id), p4.id)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside + "/p"), ["X"])
    }

    func testAnInterruptedMadeFolderUndoDoesntRemoveOutsideTheGrant() throws {
        mkdir("q")
        let plan = try approved([md("q/Y")])
        XCTAssertEqual(executor.execute(plan).doneCount, 1)
        try journal.append(JournalEvent(kind: .undoPending, date: Date(), item: 1), planID: plan.id)
        try fm.moveItem(atPath: grant + "/q/Y", toPath: grant + "/q/" + ChangeUndo.asideName(planID: plan.id, item: 1))
        var u = undoer
        u.beforeOperation = { _ in try? self.fm.moveItem(atPath: self.grant + "/q", toPath: self.outside + "/q") }
        let r = u.undo(plan.id)
        XCTAssertEqual(r.undone, [])
        XCTAssertEqual(r.stopped?.id, 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside + "/q"), ["Y"], "put back under its name, not removed")
    }

    func testUndoPutsBackWhatWasSwappedIn() throws {
        var u = undoer
        var swap: () -> Void = {}
        u.beforeOperation = { _ in swap() }
        // Move: the item at the destination swapped before it moves back.
        write("a.txt", "mine")
        let p1 = try approved([mv("a.txt", "b.txt")])
        XCTAssertEqual(executor.execute(p1).doneCount, 1)
        swap = {
            try? self.fm.moveItem(atPath: self.grant + "/b.txt", toPath: self.base + "/b-original.txt")
            self.write("b.txt", "intruder")
        }
        assertStoppedPlainly(u.undo(p1.id), p1.id)
        XCTAssertEqual(try String(contentsOfFile: grant + "/b.txt"), "intruder", "back where it was")
        XCTAssertFalse(exists("a.txt"))
        // Trash: the item in the Trash swapped before it is put back.
        write("c.txt", "mine")
        let p2 = try approved([rm("c.txt")])
        guard case .done(let r2) = executor.execute(p2).outcomes[0].status, let t2 = r2.trashURL else { return XCTFail() }
        swap = {
            try? self.fm.moveItem(atPath: t2, toPath: self.base + "/c-original.txt")
            self.fm.createFile(atPath: t2, contents: Data("intruder".utf8))
        }
        assertStoppedPlainly(u.undo(p2.id), p2.id)
        XCTAssertFalse(exists("c.txt"))
        XCTAssertEqual(try String(contentsOfFile: t2), "intruder", "back in the Trash")
        // make_dir: another folder swapped in under its name.
        let p3 = try approved([md("X")])
        XCTAssertEqual(executor.execute(p3).doneCount, 1)
        swap = {
            try? self.fm.moveItem(atPath: self.grant + "/X", toPath: self.outside + "/X-original")
            self.mkdir("X")
        }
        assertStoppedPlainly(u.undo(p3.id), p3.id)
        XCTAssertTrue(exists("X"), "not ours: put back, not removed")
        XCTAssertEqual(names().filter { $0.hasPrefix(".llmtray") }, [])
    }

    func testAnInterruptedTrashUndoDoesntTakeAFailedLookForGone() throws {
        if geteuid() == 0 { throw XCTSkip("permissions don't hold for root") }
        write("h.txt", "h")
        let plan = try approved([rm("h.txt")])
        guard case .done(let r) = executor.execute(plan).outcomes[0].status, let t = r.trashURL else { return XCTFail() }
        try journal.append(JournalEvent(kind: .undoPending, date: Date(), item: 1), planID: plan.id)
        // Back at its place by a hard link, still in the Trash -- which
        // can't be looked into.
        try fm.linkItem(atPath: t, toPath: grant + "/h.txt")
        let trashDir = base + "/Trash"
        XCTAssertEqual(chmod(trashDir, 0), 0)
        let undo = undoer.undo(plan.id)
        XCTAssertEqual(chmod(trashDir, 0o755), 0)
        XCTAssertEqual(undo.undone, [])
        XCTAssertTrue(undo.stopped?.reason?.contains("needs a look") ?? false, "\(undo)")
        guard case .undoIncomplete = journal.record(plan.id)!.items[0].state else { return XCTFail() }
        XCTAssertTrue(fm.fileExists(atPath: t))
    }

    func testATruncatedJournalIsNotReversible() throws {
        write("a.txt", "a")
        let plan = try approved([mv("a.txt", "b.txt")])
        XCTAssertEqual(executor.execute(plan).doneCount, 1)
        let size = try XCTUnwrap(fm.attributesOfItem(atPath: journal.url(for: plan.id).path)[.size] as? NSNumber).intValue
        journal.maxRecordBytes = size - 1
        XCTAssertEqual(journal.record(plan.id)?.truncated, true)
        let expected = [ChangeUndo.Remaining(id: 0, reversible: false, reason: "the journal is too large to read whole")]
        XCTAssertEqual(undoer.reversibility(plan.id), expected)
        let undo = undoer.undo(plan.id)
        XCTAssertEqual(undo.undone, [])
        XCTAssertEqual(undo.remaining, expected)
        XCTAssertTrue(exists("b.txt"))
    }
}
