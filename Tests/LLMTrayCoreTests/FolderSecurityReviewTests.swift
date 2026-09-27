import Darwin
import Foundation
import XCTest
@testable import LLMTrayCore

/// A Trash in the test's temp folder: a rename, like the real one on the
/// same volume.
private final class TempTrash: Trasher {
    let dir: String

    init(dir: String) {
        self.dir = dir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func trash(_ url: URL, coordinated: Bool, verify: (URL) -> Bool) throws -> URL? {
        guard verify(url) else { throw FolderAccessError.changed(url.path) }
        let dest = dir + "/" + url.lastPathComponent + " " + UUID().uuidString.prefix(4)
        try FileManager.default.moveItem(atPath: url.path, toPath: dest)
        return URL(fileURLWithPath: dest)
    }
}

/// A switchable change grant for the tests.
private final class GrantSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var denied: (FolderLocation) -> Bool = { _ in false }

    func deny(_ rule: @escaping (FolderLocation) -> Bool) {
        lock.lock()
        denied = rule
        lock.unlock()
    }

    var check: ChangeGrantCheck {
        { [self] loc in
            lock.lock()
            defer { lock.unlock() }
            return !denied(loc)
        }
    }
}

/// The findings of the Claude security review of the folder tools
/// (2026-09-27): approvals bound to the exact plan, crash leftovers,
/// dataless files, folders holding denied items, the wider denylist, journal
/// pruning, change grants checked again, `.DS_Store` in made folders.
final class FolderSecurityReviewTests: FolderTestCase {
    private var journal: ChangeJournal!
    private var trash: TempTrash!
    private var store: ChangePlanStore!
    private let grants = GrantSwitch()

    override func setUpWithError() throws {
        try super.setUpWithError()
        journal = ChangeJournal(directory: URL(fileURLWithPath: base + "/journal"))
        trash = TempTrash(dir: base + "/Trash")
        store = ChangePlanStore()
    }

    override func tearDownWithError() throws {
        StatFlagInjection.shared.clear()
        try super.tearDownWithError()
    }

    private var planner: ChangePlanner { ChangePlanner(denylist: denylist, canChange: grants.check) }
    private var executor: ChangeExecutor { ChangeExecutor(denylist: denylist, journal: journal, trasher: trash, canChange: grants.check) }
    private var undoer: ChangeUndo { ChangeUndo(denylist: denylist, journal: journal, canChange: grants.check) }

    private func mv(_ from: String, _ to: String) throws -> ChangeRequest { .move(from: try loc(from), to: try loc(to)) }
    private func md(_ path: String) throws -> ChangeRequest { .makeDir(try loc(path)) }
    private func rm(_ path: String) throws -> ChangeRequest { .trash(try loc(path)) }

    @discardableResult
    private func add(_ ops: [ChangeRequest], chat: String = "c") throws -> ChangePlan {
        let r = try planner.plan(ops, after: store.pending(chatID: chat)?.items ?? [])
        XCTAssertTrue(r.rejected.isEmpty, "\(r.rejected.map { "\($0.index): \($0.error)" })")
        return store.add(r.items, chatID: chat)
    }

    private func approveNow(chat: String = "c") throws -> ApprovedPlan {
        let p = try XCTUnwrap(store.pending(chatID: chat))
        return try store.approve(chatID: chat, planID: p.id, revision: p.revision, validator: planner)
    }

    private func approved(_ ops: [ChangeRequest]) throws -> ApprovedPlan {
        try add(ops)
        return try approveNow()
    }

    private func status(_ r: ChangeExecutor.Report) -> [String] {
        r.outcomes.map {
            switch $0.status {
            case .done: return "done"
            case .failed(let why): return "failed: \(why)"
            case .uncertain(let why): return "uncertain: \(why)"
            case .notRun: return "notRun"
            }
        }
    }

    private func staging(_ dir: String = "") -> [String] { names(dir).filter { $0.hasPrefix(".llmtray") } }

    // MARK: 1. Approval bound to the exact plan

    func testAnApprovalOfACancelledPlanCantApproveTheNextOne() throws {
        write("a.txt", "a")
        write("b.txt", "b")
        let a = try add([rm("a.txt")])
        store.cancel(chatID: "c")
        let b = try add([rm("b.txt")])
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.revision, b.revision, "revisions never restart")
        XCTAssertNotEqual(a.items.map(\.id), b.items.map(\.id), "nor item ids")
        // The user approves what they saw: plan A.
        XCTAssertThrowsError(try store.approve(chatID: "c", planID: a.id, revision: a.revision, validator: planner)) {
            XCTAssertEqual($0 as? ChangePlanError, .notThePlanReviewed)
        }
        XCTAssertThrowsError(try store.approve(chatID: "c", planID: b.id, revision: a.revision, validator: planner)) {
            XCTAssertEqual($0 as? ChangePlanError, .stale(reviewed: a.revision, current: b.revision))
        }
        XCTAssertThrowsError(try store.approve(chatID: "c", planID: b.id, revision: b.revision,
                                               items: Set(a.items.map(\.id)), validator: planner)) {
            XCTAssertEqual($0 as? ChangePlanError, .unknownItems(a.items.map(\.id)))
        }
        XCTAssertTrue(exists("a.txt") && exists("b.txt"))
        // After an approval, ids and revisions go on too.
        let approvedB = try store.approve(chatID: "c", planID: b.id, revision: b.revision, validator: planner)
        XCTAssertEqual(approvedB.plan.items.map(\.id), b.items.map(\.id))
        let c = try add([rm("a.txt")])
        XCTAssertGreaterThan(c.revision, b.revision)
        XCTAssertGreaterThan(c.items[0].id, b.items[0].id)
        XCTAssertThrowsError(try store.approve(chatID: "c", planID: b.id, revision: b.revision, validator: planner))
    }

    func testRenumberedItemsKeepTheirDependencies() throws {
        write("x.txt", "x")
        try add([md("old")])
        store.cancel(chatID: "c")
        let p = try add([md("new"), mv("x.txt", "new/x.txt")])
        XCTAssertEqual(p.items[1].dependsOn, [p.items[0].id])
        XCTAssertEqual(status(executor.execute(try approveNow())), ["done", "done"])
        XCTAssertTrue(exists("new/x.txt"))
    }

    // MARK: 2. Crash leftovers

    private func crashed(_ ops: [ChangeRequest], at step: ChangeExecutor.Step) throws -> ApprovedPlan {
        let plan = try approved(ops)
        var exec = executor
        exec.crashAt = { $0 == step }
        _ = exec.execute(plan)
        XCTAssertTrue(journal.record(plan.plan.id)?.isIncomplete ?? false)
        return plan
    }

    private func state(_ plan: ApprovedPlan) -> JournalRecord.ItemState? { journal.record(plan.plan.id)?.items.first?.state }

    func testATrashCrashedAtEachStepIsRecovered() throws {
        for step in [ChangeExecutor.Step.staged, .stagingMade, .itemStaged] {
            let name = "t-\(step).txt"
            write("t/" + name, "mine")
            let plan = try crashed([rm("t/" + name)], at: step)
            let expected = StagingRecord.name(.trash, planID: plan.plan.id, item: plan.plan.items[0].id)
            XCTAssertEqual(journal.record(plan.plan.id)?.items.first?.staging?.name, expected, "journaled before it is made")
            if step == .itemStaged { XCTAssertEqual(try fm.contentsOfDirectory(atPath: grant + "/t/" + expected), [name]) }
            let r = undoer.recover(plan.plan.id)
            XCTAssertEqual(r.restored, [plan.plan.items[0].id], "\(step): \(r)")
            XCTAssertEqual(try String(contentsOfFile: grant + "/t/" + name), "mine", "\(step)")
            XCTAssertEqual(staging("t"), [], "\(step)")
            guard case .failed = state(plan) else { return XCTFail("\(step): \(String(describing: state(plan)))") }
            XCTAssertEqual(undoer.recover(plan.plan.id), .init(planID: plan.plan.id), "a second pass finds nothing")
        }
    }

    func testATrashCrashedAfterTheTrashTookItLeavesItThereAndCleansUp() throws {
        write("t/x.txt", "x")
        let plan = try crashed([rm("t/x.txt")], at: .trashed)
        XCTAssertEqual(staging("t").count, 1)
        let r = undoer.recover(plan.plan.id)
        XCTAssertEqual(r.cleaned, [plan.plan.items[0].id])
        XCTAssertEqual(r.restored, [])
        XCTAssertEqual(staging("t"), [])
        XCTAssertFalse(exists("t/x.txt"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: base + "/Trash").count, 1, "still in the Trash")
        XCTAssertEqual(state(plan), .incomplete, "its outcome still needs a look")
    }

    func testARecoveryDoesntOverwriteANameTakenSince() throws {
        write("t/x.txt", "mine")
        let plan = try crashed([rm("t/x.txt")], at: .itemStaged)
        write("t/x.txt", "someone else's")
        let r = undoer.recover(plan.plan.id)
        XCTAssertEqual(r.restored, [])
        XCTAssertTrue(r.needsLook[plan.plan.items[0].id]?.contains("already exists") ?? false, "\(r)")
        XCTAssertEqual(try String(contentsOfFile: grant + "/t/x.txt"), "someone else's")
        let aside = StagingRecord.name(.trash, planID: plan.plan.id, item: plan.plan.items[0].id)
        XCTAssertEqual(try String(contentsOfFile: grant + "/t/\(aside)/x.txt"), "mine", "left where it is")
    }

    func testARecoveryDoesntTakeSomethingElseFromTheStagingFolder() throws {
        write("t/x.txt", "mine")
        let plan = try crashed([rm("t/x.txt")], at: .itemStaged)
        let aside = StagingRecord.name(.trash, planID: plan.plan.id, item: plan.plan.items[0].id)
        try fm.moveItem(atPath: grant + "/t/\(aside)/x.txt", toPath: outside + "/x.txt")
        write("t/\(aside)/x.txt", "swapped in")
        let r = undoer.recover(plan.plan.id)
        XCTAssertEqual(r.restored, [])
        XCTAssertNotNil(r.needsLook[plan.plan.items[0].id])
        XCTAssertFalse(exists("t/x.txt"))
    }

    func testAMakeDirCrashedWithItsStagingFolderIsCleanedUp() throws {
        let plan = try crashed([md("New")], at: .stagingMade)
        XCTAssertEqual(staging().count, 1)
        let recoveries = undoer.recoverInterrupted()
        XCTAssertEqual(recoveries.map(\.planID), [plan.plan.id], "found when the journal is opened")
        XCTAssertEqual(recoveries.first?.restored, [plan.plan.items[0].id])
        XCTAssertEqual(staging(), [])
        XCTAssertFalse(exists("New"))
        guard case .failed = state(plan) else { return XCTFail() }
    }

    func testARenameCrashedUnderItsTemporaryNameIsPutBack() throws {
        // As a crash leaves a rename through a temporary name (APFS takes a
        // case-only rename directly, so the state is made by hand): the
        // name journaled, the item under it.
        write("readme.txt", "r")
        let plan = try approved([mv("readme.txt", "README.txt")])
        let item = plan.plan.items[0]
        let temp = StagingRecord.name(.rename, planID: plan.plan.id, item: item.id)
        try journal.append(JournalEvent(kind: .begin, date: Date(), chatID: "c"), planID: plan.plan.id)
        try journal.append(JournalEvent(kind: .pending, date: Date(), item: item.id, planItem: item), planID: plan.plan.id)
        try journal.append(JournalEvent(kind: .staged, date: Date(), item: item.id,
                                        staging: StagingRecord(kind: .rename, name: temp, root: root, parentComponents: [],
                                                               parentChain: [root.identity])), planID: plan.plan.id)
        try fm.moveItem(atPath: grant + "/readme.txt", toPath: grant + "/" + temp)
        XCTAssertEqual(undoer.recover(plan.plan.id).restored, [item.id])
        XCTAssertEqual(names().filter { $0.lowercased() == "readme.txt" }, ["readme.txt"])
        XCTAssertEqual(staging(), [])
        guard case .failed = state(plan) else { return XCTFail() }
    }

    func testARenameCrashedBeforeItsTemporaryNameIsLeftAlone() throws {
        write("n.txt", "n")
        let plan = try approved([mv("n.txt", "m.txt")])
        let item = plan.plan.items[0]
        try journal.append(JournalEvent(kind: .begin, date: Date(), chatID: "c"), planID: plan.plan.id)
        try journal.append(JournalEvent(kind: .pending, date: Date(), item: item.id, planItem: item), planID: plan.plan.id)
        try journal.append(JournalEvent(kind: .staged, date: Date(), item: item.id,
                                        staging: StagingRecord(kind: .rename, name: StagingRecord.name(.rename, planID: plan.plan.id, item: item.id),
                                                               root: root, parentComponents: [], parentChain: [root.identity])),
                           planID: plan.plan.id)
        XCTAssertEqual(undoer.recover(plan.plan.id), .init(planID: plan.plan.id))
        XCTAssertEqual(state(plan), .incomplete, "no guess about a rename's outcome")
    }

    func testARunningPlanIsntRecoveredUnderItsFeet() throws {
        write("r.txt", "r")
        let plan = try approved([rm("r.txt")])
        var exec = executor
        var during: ChangeUndo.Recovery?
        exec.crashAt = { step in
            if step == .itemStaged { during = self.undoer.recover(plan.plan.id) }
            return false
        }
        XCTAssertEqual(exec.execute(plan).doneCount, 1)
        XCTAssertEqual(during, .init(planID: plan.plan.id))
        XCTAssertFalse(exists("r.txt"))
    }

    func testFinishedPlansGiveTheRecoveryPassNothingToSay() throws {
        write("f.txt", "f")
        let plan = try approved([rm("f.txt")])
        XCTAssertEqual(executor.execute(plan).doneCount, 1)
        grants.deny { _ in true }
        XCTAssertEqual(undoer.recoverInterrupted(), [], "no leftovers, nothing to report -- revoked grant or not")
    }

    func testUndoRecoversFirst() throws {
        write("u.txt", "u")
        let plan = try crashed([rm("u.txt")], at: .itemStaged)
        let r = undoer.undo(plan.plan.id)
        XCTAssertEqual(r.undone, [])
        XCTAssertEqual(try String(contentsOfFile: grant + "/u.txt"), "u")
        XCTAssertEqual(staging(), [])
    }

    // MARK: 3. Put Back

    func testTheTrashItemSaysRestoreIsLLMTraysUndo() throws {
        write("a.txt", "a")
        let r = try planner.plan([rm("a.txt")])
        XCTAssertTrue(r.items[0].notes.contains(ChangePlanner.trashRestoreNote))
    }

    // MARK: 4. Dataless files

    private func markDataless(_ path: String) throws {
        StatFlagInjection.shared.set(UInt32(SF_DATALESS), for: try XCTUnwrap(identity(path)))
    }

    func testADatalessFileIsNeverRead() throws {
        let path = write("cloud.txt", "would download")
        try markDataless(path)
        let files = FolderFiles(walker: walker)
        guard case .info(let info) = try files.run(FolderQuery(components: ["cloud.txt"], hash: true)) else { return XCTFail() }
        XCTAssertEqual(info.notDownloaded, true)
        XCTAssertNil(info.head)
        XCTAssertNil(info.isText)
        XCTAssertEqual(info.hash, .withheld("not downloaded"))
        XCTAssertTrue(info.note?.contains("in iCloud, not downloaded") ?? false)
        guard case .listing(let page) = try files.run(FolderQuery(components: [])) else { return XCTFail() }
        XCTAssertEqual(page.entries.first { $0.path == "cloud.txt" }?.notDownloaded, true)
    }

    func testDuplicatesSkipDatalessFilesWithACount() throws {
        write("a.bin", String(repeating: "x", count: 5000))
        write("b.bin", String(repeating: "x", count: 5000))
        let c = write("c.bin", String(repeating: "x", count: 5000))
        try markDataless(c)
        let report = try DuplicateFinder(walker: walker).find()
        XCTAssertEqual(report.summary.notDownloadedSkipped, 1)
        XCTAssertEqual(report.groups.map { $0.files.map(\.path) }, [["a.bin", "b.bin"]])
    }

    func testReadsRunWithMaterializationOff() {
        let before = Materialization.current
        let inside = Materialization.off { Materialization.current }
        XCTAssertEqual(inside, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        XCTAssertEqual(Materialization.current, before, "restored after")
    }

    func testTheDuplicateScanHasATimeCap() throws {
        for i in 0..<20 { write("d\(i).txt", "same") }
        var t = Date(timeIntervalSince1970: 0)
        var finder = DuplicateFinder(walker: walker, clock: { t = t.addingTimeInterval(1); return t })
        finder.limits.maxSeconds = 5
        let report = try finder.find()
        XCTAssertEqual(report.summary.stopped, .timeLimit)
        XCTAssertLessThan(report.summary.filesScanned, 20, "partial")
    }

    // MARK: 5. Folders holding denied items

    func testAFolderHoldingDeniedItemsIsFlaggedAndNotMovedOrTrashed() throws {
        write("box/sub/.ssh/id_ed25519", "key")
        write("box/notes.txt", "n")
        write("plain/a.txt", "a")
        let files = FolderFiles(walker: walker)
        guard case .listing(let page) = try files.run(FolderQuery(components: [])) else { return XCTFail() }
        XCTAssertEqual(page.entries.first { $0.path == "box" }?.protectedInside, .found)
        XCTAssertNil(page.entries.first { $0.path == "plain" }?.protectedInside)
        guard case .listing(let inside) = try files.run(FolderQuery(components: ["box"])) else { return XCTFail() }
        XCTAssertEqual(inside.protectedInside, .found, "the listed folder itself")
        XCTAssertEqual(inside.entries.first { $0.path == "box/sub" }?.protectedInside, .found)
        guard case .listing(let plainPage) = try files.run(FolderQuery(components: ["plain"])) else { return XCTFail() }
        XCTAssertNil(plainPage.protectedInside)
        let info = try FileClassifier().info(try walker.resolve(["box"]), walker: walker)
        XCTAssertEqual(info.protectedInside, .found)
        XCTAssertTrue(info.note?.contains("protected") ?? false)
        let r = try planner.plan([mv("box", "moved"), rm("box"), mv("plain", "plain2")])
        XCTAssertEqual(r.rejected.map(\.index), [0, 1])
        for e in r.rejected {
            XCTAssertEqual(e.error as? FolderAccessError, .containsProtected("box"))
            XCTAssertTrue("\(e.error)".contains("contains protected items"))
        }
        // One by one, what isn't denied can go.
        XCTAssertEqual(try planner.plan([mv("box/notes.txt", "notes.txt")]).rejected.count, 0)
    }

    func testADeniedItemAddedAfterReviewStopsTheChange() throws {
        write("f/a.txt", "a")
        write("g/a.txt", "a")
        // At approval...
        try add([mv("f", "f2")])
        write("f/.ssh/config", "x")
        XCTAssertThrowsError(try approveNow()) {
            guard case .invalidated(let m) = $0 as? ChangePlanError else { return XCTFail("\($0)") }
            XCTAssertTrue(m.values.first?.contains("protected") ?? false)
        }
        store.cancel(chatID: "c")
        // ...and at execution.
        let plan = try approved([rm("g")])
        write("g/.ssh/config", "x")
        XCTAssertEqual(status(executor.execute(plan)), ["failed: \(FolderAccessError.containsProtected("g"))"])
        XCTAssertTrue(exists("g/.ssh/config"))
    }

    func testAFolderTooLargeToCheckIsNotMoved() throws {
        for i in 0..<5 { write("big/f\(i).txt", "x") }
        var p = planner
        p.protectedCheckBudget = 3
        XCTAssertEqual(try p.plan([mv("big", "big2")]).rejected.first?.error as? FolderAccessError, .uncheckable("big"))
    }

    // MARK: 6. The denylist, wider

    func testHomeCredentialFoldersAndApplicationsAreDenied() throws {
        // By spelling, for a home outside the (denied) temp folder...
        let home = "/Users/llmtray-test-nobody"
        let list = FolderDenylist.standard(home: home)
        for p in [".aws/credentials", ".config/gh/hosts.yml", ".kube/config", ".docker/config.json", ".netrc",
                  ".git-credentials", ".password-store/x.gpg", ".npmrc", ".pypirc", ".gem/credentials",
                  ".cargo/credentials", ".cargo/credentials.toml", ".terraform.d/credentials.tfrc.json"] {
            XCTAssertTrue(list.deniesPath(home + "/" + p), p)
        }
        XCTAssertFalse(list.deniesPath(home + "/.cargo/registry"))
        XCTAssertFalse(list.deniesPath(home + "/Documents/.config-notes"))
        // ...and by identity for one that exists.
        let real = base + "/home"
        try fm.createDirectory(atPath: real + "/.aws", withIntermediateDirectories: true)
        XCTAssertTrue(FolderDenylist.standard(home: real).isDenied(identity: try XCTUnwrap(identity(real + "/.aws"))))
        XCTAssertTrue(list.deniesPath("/Applications/Safari.app"))
        XCTAssertThrowsError(try SafeFolderWalker.makeRoot(path: "/Applications", denylist: list))
        if fm.fileExists(atPath: "/Applications/Utilities") {
            XCTAssertThrowsError(try SafeFolderWalker.makeRoot(path: "/Applications/Utilities", denylist: list))
        }
    }

    func testSecretLookingNames() {
        for (name, parent) in [(".env", "p"), (".env.local", "p"), ("server.pem", "p"), ("tls.KEY", "p"), ("id_rsa", "p"),
                               ("id_rsa.pub", "p"), ("id_ed25519", "p"), ("id_ecdsa_sk", "p"), ("cert.p12", "p"),
                               ("cert.pfx", "p"), ("config", ".git"), (".npmrc", "p"), (".netrc", "p"),
                               (".git-credentials", "p")] {
            XCTAssertTrue(FolderDenylist.looksSecret(name: name, parentName: parent), name)
        }
        for (name, parent) in [("config", "app"), ("env.txt", "p"), ("notes.txt", "p"), ("keys.txt", "p"), ("pem", "p")] {
            XCTAssertFalse(FolderDenylist.looksSecret(name: name, parentName: parent), name)
        }
    }

    func testSecretLookingFilesAreListedButNeverRead() throws {
        write(".env", "API_KEY=sk-123")
        write("repo/.git/config", "[remote] url = https://token@host")
        write("a.pem", "-----BEGIN PRIVATE KEY-----")
        write("b.pem", "-----BEGIN PRIVATE KEY-----")
        let files = FolderFiles(walker: walker)
        guard case .listing(let page) = try files.run(FolderQuery(components: [], includeHidden: true)) else { return XCTFail() }
        XCTAssertTrue(page.entries.contains { $0.path == ".env" }, "listed")
        for path in [".env", "repo/.git/config", "a.pem"] {
            let comps = path.split(separator: "/").map(String.init)
            guard case .info(let info) = try files.run(FolderQuery(components: comps, hash: true)) else { return XCTFail() }
            XCTAssertEqual(info.looksSecret, true, path)
            XCTAssertNil(info.head, path)
            XCTAssertNil(info.lineCount, path)
            XCTAssertEqual(info.hash, .withheld("looks like a secret"), path)
        }
        var finder = DuplicateFinder(walker: walker)
        finder.limits.includeHidden = true
        let report = try finder.find()
        XCTAssertEqual(report.groups, [], "never hashed")
        XCTAssertEqual(report.summary.secretsNotRead, 4)
    }

    // MARK: 7. Journal pruning

    func testFinishedJournalsArePrunedAfterAMonth() throws {
        write("a.txt", "a")
        write("b.txt", "b")
        let done = try approved([mv("a.txt", "a2.txt")])
        XCTAssertEqual(executor.execute(done).doneCount, 1)
        let interrupted = try crashed([rm("b.txt")], at: .trashed)
        write("c.txt", "c")
        let recent = try approved([mv("c.txt", "c2.txt")])
        XCTAssertEqual(executor.execute(recent).doneCount, 1)
        let now = Date()
        let old = now.addingTimeInterval(-31 * 24 * 3600)
        for id in [done.plan.id, interrupted.plan.id] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: journal.url(for: id).path)
        }
        XCTAssertEqual(journal.prune(now: now), [done.plan.id])
        XCTAssertNil(journal.record(done.plan.id))
        XCTAssertNotNil(journal.record(interrupted.plan.id), "an interrupted plan stays until looked at")
        XCTAssertNotNil(journal.record(recent.plan.id))
    }

    // MARK: 8. Change grants checked again

    func testChangeGrantsAreCheckedAtEveryStep() throws {
        write("a.txt", "a")
        write("b.txt", "b")
        mkdir("locked")
        grants.deny { $0.components.first == "locked" }
        let r = try planner.plan([mv("a.txt", "locked/a.txt"), mv("b.txt", "b2.txt")])
        XCTAssertEqual(r.rejected.map(\.index), [0])
        XCTAssertEqual(r.rejected.first?.error as? FolderAccessError, .notGranted(grant + "/locked/a.txt"))
        grants.deny { _ in false }
        // Revoked before approval.
        try add([mv("a.txt", "a2.txt")])
        grants.deny { _ in true }
        XCTAssertThrowsError(try approveNow()) {
            guard case .invalidated = $0 as? ChangePlanError else { return XCTFail("\($0)") }
        }
        // Revoked between approval and execution.
        grants.deny { _ in false }
        let plan = try approveNow()
        grants.deny { _ in true }
        XCTAssertEqual(status(executor.execute(plan)), ["failed: \(FolderAccessError.notGranted(grant + "/a.txt"))"])
        XCTAssertTrue(exists("a.txt"))
        // Revoked before undo.
        grants.deny { _ in false }
        let done = try approved([mv("b.txt", "b2.txt")])
        XCTAssertEqual(executor.execute(done).doneCount, 1)
        grants.deny { _ in true }
        XCTAssertEqual(undoer.reversibility(done.plan.id).first?.reversible, false)
        let u = undoer.undo(done.plan.id)
        XCTAssertEqual(u.undone, [])
        XCTAssertTrue(u.stopped?.reason?.contains("no change access") ?? false, "\(u)")
        XCTAssertTrue(exists("b2.txt"))
        grants.deny { _ in false }
        XCTAssertEqual(undoer.undo(done.plan.id).undone, [done.plan.items[0].id])
    }

    func testBothEndsOfACrossGrantMoveAreChecked() throws {
        let second = base + "/second"
        try fm.createDirectory(atPath: second, withIntermediateDirectories: true)
        let root2 = try SafeFolderWalker.makeRoot(path: second, denylist: denylist)
        write("a.txt", "a")
        let cross = ChangeRequest.move(from: try loc("a.txt"), to: FolderLocation(root: root2, components: ["a.txt"]))
        grants.deny { $0.root == root2 }
        XCTAssertEqual(try planner.plan([cross]).rejected.first?.error as? FolderAccessError, .notGranted(second + "/a.txt"))
        grants.deny { _ in false }
        let plan = try approved([cross])
        grants.deny { $0.root == root2 }
        XCTAssertEqual(status(executor.execute(plan)), ["failed: \(FolderAccessError.notGranted(second + "/a.txt"))"])
        grants.deny { _ in false }
        XCTAssertEqual(executor.execute(try approved([cross])).doneCount, 1)
        XCTAssertTrue(fm.fileExists(atPath: second + "/a.txt"))
    }

    func testFolderGrantsDriveTheChecks() throws {
        let g = FolderGrants(storeURL: nil)
        let grantRecord = try g.grant(root, level: .change, lifetime: .chat("c"), chatID: "c")
        write("a.txt", "a")
        let p = ChangePlanner(denylist: denylist, canChange: g.changeCheck(chatID: "c"))
        XCTAssertEqual(try p.plan([mv("a.txt", "b.txt")]).rejected.count, 0)
        let other = ChangePlanner(denylist: denylist, canChange: g.changeCheck(chatID: "other"))
        XCTAssertEqual(try other.plan([mv("a.txt", "b.txt")]).rejected.count, 1, "another chat's grant")
        let temp = ChangePlanner(denylist: denylist, canChange: g.changeCheck(chatID: "c", temporaryChat: true))
        XCTAssertEqual(try temp.plan([mv("a.txt", "b.txt")]).rejected.count, 1)
        try g.revoke(grantRecord.id)
        XCTAssertEqual(try p.plan([mv("a.txt", "b.txt")]).rejected.count, 1, "revoked")
    }

    // MARK: 9. .DS_Store in a made folder

    func testUndoOfAMadeFolderIgnoresALoneDSStore() throws {
        let plan = try approved([md("X"), md("Y")])
        XCTAssertEqual(executor.execute(plan).doneCount, 2)
        write("X/.DS_Store", "finder")
        write("Y/.DS_Store", "finder")
        write("Y/kept.txt", "k")
        let u = undoer.undo(plan.plan.id)
        XCTAssertEqual(u.undone, [], "Y is newest and not empty: undo stops there")
        XCTAssertEqual(u.stopped?.id, plan.plan.items[1].id)
        XCTAssertTrue(exists("Y/.DS_Store"), "not removed when it isn't alone")
        try fm.removeItem(atPath: grant + "/Y/kept.txt")
        let again = undoer.undo(plan.plan.id)
        XCTAssertEqual(again.undone, plan.plan.items.map(\.id).reversed())
        XCTAssertFalse(exists("X"))
        XCTAssertFalse(exists("Y"))
        XCTAssertEqual(staging(), [])
    }
}
