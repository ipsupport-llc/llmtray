import Darwin
import Foundation
import XCTest
@testable import LLMTrayCore

/// Folder sizes in listings, the change rule, the next-message line, and the
/// plan review's warnings (adr/0014, "Listing sizes and the plan's
/// warnings"). Temp folders only.
final class FolderSizesAndPlanChecksTests: FolderTestCase {
    private var service: FolderToolService!
    private let chat = FolderChat(id: "chat-s", temporary: false)

    override func setUpWithError() throws {
        try super.setUpWithError()
        service = FolderToolService(grants: FolderGrants(storeURL: URL(fileURLWithPath: base + "/grants.json")),
                                    denylist: denylist, journal: ChangeJournal(directory: URL(fileURLWithPath: base + "/journal")),
                                    home: base)
    }

    override func tearDownWithError() throws {
        StatFlagInjection.shared.clear()
        try super.tearDownWithError()
    }

    private func bytes(_ n: Int, _ byte: UInt8 = 0x61) -> Data { Data(repeating: byte, count: n) }

    private func page(_ q: FolderQuery, limits: FolderFiles.Limits = FolderFiles.Limits()) throws -> ListingPage {
        guard case .listing(let p) = try FolderFiles(walker: walker, limits: limits).run(q) else {
            XCTFail("not a listing")
            return ListingPage(entries: [], total: 0, scanTruncated: false)
        }
        return p
    }

    private func entry(_ p: ListingPage, _ path: String) -> ListingPage.Entry? { p.entries.first { $0.path == path } }

    // MARK: Listing sizes

    func testASubfolderLineCarriesItsItemsAndSize() throws {
        writeData("manual/a.pdf", bytes(1000))
        writeData("manual/b.pdf", bytes(2000))
        writeData("manual/ch1/c.pdf", bytes(3000))
        writeData("manual/.DS_Store", bytes(10))          // bytes, not an item
        writeData("manual/Tool.app/Contents/bin", bytes(500)) // one item, its bytes
        writeData("manual/.ssh/id", bytes(7777))            // denied: neither
        XCTAssertEqual(link(outside + "/huge", into: "manual/link"), 0)
        writeData("huge", bytes(50_000), in: outside)
        let p = try page(FolderQuery(components: []))
        let size = try XCTUnwrap(entry(p, "manual")?.folderSize)
        // a.pdf, b.pdf, ch1, ch1/c.pdf, Tool.app, link
        XCTAssertEqual(size.items, 6)
        XCTAssertEqual(size.bytes, 1000 + 2000 + 3000 + 10 + 500, "a link isn't followed, denied items don't count")
        XCTAssertFalse(size.partial)
        XCTAssertEqual(entry(p, "manual")?.protectedInside, .found, "the same walk flags what's denied inside")
        let text = FolderToolText.listing(p, request: FolderTools.FilesRequest(path: "~/grant"), folder: "~/grant",
                                          components: [], byteBudget: 8000)
        XCTAssertTrue(text.contains("manual/  6 items, 6.5 KB  "), text)
    }

    private func link(_ target: String, into relative: String) -> Int32 {
        mkdir((relative as NSString).deletingLastPathComponent)
        return symlink(target, grant + "/" + relative)
    }

    func testAHardLinkCountsOnceAndAPackageLineShowsBytes() throws {
        let a = writeData("d/a.bin", bytes(4000))
        XCTAssertEqual(Darwin.link(a, grant + "/d/b.bin"), 0)
        writeData("Tool.app/Contents/x", bytes(1234))
        let p = try page(FolderQuery(components: []))
        XCTAssertEqual(entry(p, "d")?.folderSize, FolderSize(items: 2, bytes: 4000))
        XCTAssertEqual(entry(p, "Tool.app")?.kind, .package)
        let text = FolderToolText.listing(p, request: FolderTools.FilesRequest(path: "~/grant"), folder: "~/grant",
                                          components: [], byteBudget: 8000)
        XCTAssertTrue(text.contains("Tool.app [package]  1.2 KB  "), text)
        XCTAssertTrue(text.contains("d/  2 items, 4.0 KB  "), text)
    }

    func testAnEmptyFolderAndOneItem() throws {
        mkdir("empty")
        writeData("one/x", bytes(1))
        let p = try page(FolderQuery(components: []))
        XCTAssertEqual(entry(p, "empty")?.folderSize, FolderSize(items: 0, bytes: 0))
        XCTAssertEqual(FolderToolText.folderSize(FolderSize(items: 1, bytes: 1)), "1 item, 1 B")
        XCTAssertEqual(FolderToolText.folderSize(FolderSize(items: 0, bytes: 0)), "0 items, 0 B")
    }

    func testPastTheCapASizeIsAtLeast() throws {
        for i in 0..<20 { writeData("big/f\(i)", bytes(100)) }
        writeData("small/f", bytes(100))
        var limits = FolderFiles.Limits()
        limits.sizePerFolder = 5
        let p = try page(FolderQuery(components: []), limits: limits)
        let big = try XCTUnwrap(entry(p, "big")?.folderSize)
        XCTAssertTrue(big.partial)
        XCTAssertLessThanOrEqual(big.items, 5)
        XCTAssertEqual(entry(p, "big")?.protectedInside, .unchecked, "not walked whole: not known to be clean")
        XCTAssertEqual(entry(p, "small")?.folderSize, FolderSize(items: 1, bytes: 100))
        XCTAssertEqual(FolderToolText.folderSize(FolderSize(items: 50_000, bytes: 12_000_000_000, partial: true)),
                       "≥ 50,000 items, ≥ 12.0 GB")
        XCTAssertEqual(FolderToolText.count(22_484), "22,484")
        XCTAssertEqual(FolderToolText.count(1_000_000), "1,000,000")
        XCTAssertEqual(FolderToolText.count(999), "999")
        // The whole page's budget spent: later folders aren't measured (no
        // size rather than a wrong one), and still get their protected check.
        limits = FolderFiles.Limits()
        limits.sizeEntriesPerPage = 20
        let spent = try page(FolderQuery(components: []), limits: limits)
        XCTAssertNotNil(entry(spent, "big")?.folderSize)
        XCTAssertNil(entry(spent, "small")?.folderSize)
        XCTAssertNil(entry(spent, "small")?.protectedInside)
    }

    func testTheTimeCapStopsAMeasurement() throws {
        for i in 0..<300 { writeData("slow/f\(i)", bytes(1)) }
        let dir = try walker.openRoot()
        // A deadline already past: stopped at the first check.
        let r = walker.subtreeScan(in: dir, "slow", budget: 10_000, deadline: ProcessInfo.processInfo.systemUptime - 1, measure: true)
        XCTAssertEqual(r.size?.partial, true)
        XCTAssertLessThan(r.size?.items ?? 0, 300)
    }

    func testARecursiveListingMeasuresOnlyTheListedFoldersOwnSubfolders() throws {
        writeData("top/a", bytes(10))
        writeData("top/inner/b", bytes(20))
        writeData("other/x", bytes(5))
        let p = try page(FolderQuery(components: [], recursive: true))
        XCTAssertEqual(entry(p, "top")?.folderSize, FolderSize(items: 3, bytes: 30))
        XCTAssertNil(entry(p, "top/inner")?.folderSize, "its files are listed anyway")
        XCTAssertNotNil(entry(p, "other")?.folderSize)
        // Listing a subfolder: its own subfolders are measured.
        let sub = try page(FolderQuery(components: ["top"]))
        XCTAssertEqual(entry(sub, "top/inner")?.folderSize, FolderSize(items: 1, bytes: 20))
    }

    func testICloudPlaceholdersCountFromMetadataAndDatalessFoldersArentEntered() throws {
        let file = writeData("cloud/doc.pdf", bytes(3000))
        StatFlagInjection.shared.set(UInt32(SF_DATALESS), for: try XCTUnwrap(identity(file)))
        writeData("cloud/away/x", bytes(9999))
        StatFlagInjection.shared.set(UInt32(SF_DATALESS), for: try XCTUnwrap(identity(grant + "/cloud/away")))
        let size = try XCTUnwrap(entry(try page(FolderQuery(components: [])), "cloud")?.folderSize)
        XCTAssertEqual(size.items, 2, "doc.pdf and the placeholder folder itself")
        XCTAssertEqual(size.bytes, 3000, "the placeholder's size from its metadata; the dataless folder not read")
        XCTAssertTrue(size.partial)
    }

    // MARK: The tool's words

    func testChangeFilesSaysASubfolderIsOneItemAndWhatADuplicateIs() {
        let d = FolderTools.changeDescription
        XCTAssertTrue(d.contains("done for real once the user approves it. Not for editing a file's contents."), d)
        XCTAssertTrue(d.contains("A subfolder is one item: move it whole or leave it"), d)
        XCTAssertTrue(d.contains("only what files(only_duplicates) finds, not a (1) in a name"), d)
        // Declared for every request: kept short (it was 134 bytes).
        XCTAssertLessThanOrEqual(d.utf8.count, 300, "\(d.utf8.count) bytes")
    }

    func testChangesAfterAReadRunFlaggedUnlessFilesArePinned() {
        // Hardening 2 as revised: no wait for the next message; the change
        // runs into the plan, flagged. Pinned files keep changes off.
        var t = ToolTrust.TurnState()
        t.record(.folderRead)
        XCTAssertFalse(ToolTrust.changeWaitsForNextMessage(t))
        XCTAssertTrue(ToolTrust.allows(.folderChange, t))
        XCTAssertTrue(ToolTrust.changeIsAfterRead(t))
        t.pinnedText = true
        XCTAssertFalse(ToolTrust.allows(.folderChange, t), "pinned files keep changes off")
    }

    func testAFilesResultSaysChangesWaitOnlyWhereTheChatMayChange() async throws {
        write("a.txt", "a")
        func files(_ path: String, _ next: Bool = true, chat: FolderChat? = nil) async -> String {
            await service.files(FolderTools.FilesRequest(path: path), chat: chat ?? self.chat, callKey: UUID().uuidString,
                                byteBudget: 16_000, changeNextMessage: next, ask: { _ in nil }).text
        }
        try service.grants.grant(root, level: .read, lifetime: .chat(chat.id), chatID: chat.id)
        var text = await files("~/grant")
        XCTAssertFalse(text.contains("change_files works from"), "a read grant: nothing to say")
        try service.grants.grant(root, level: .change, lifetime: .chat(chat.id), chatID: chat.id)
        text = await files("~/grant")
        XCTAssertTrue(text.hasSuffix("\n" + FolderToolText.nextMessageNote), text)
        text = await files("~/grant/a.txt")
        XCTAssertTrue(text.hasSuffix(FolderToolText.nextMessageNote), "a file's info too: \(text)")
        text = await files("~/grant", false)
        XCTAssertFalse(text.contains(FolderToolText.nextMessageNote), "not when the next message won't turn changes on")
        text = await files("~/grant/missing.txt")
        XCTAssertFalse(text.contains(FolderToolText.nextMessageNote), "not under an error: \(text)")
        let temp = FolderChat(id: "temp-s", temporary: true)
        try service.grants.grant(root, level: .read, lifetime: .chat(temp.id), chatID: temp.id, temporaryChat: true)
        text = await files("~/grant", chat: temp)
        XCTAssertFalse(text.contains(FolderToolText.nextMessageNote), "a temporary chat never changes files")
    }

    // MARK: The plan's warnings

    private func propose(_ ops: [FolderTools.RawOp], key: String = UUID().uuidString, afterRead: Bool = false) async throws -> ChangePlan {
        let answer = await service.propose(ops, chat: chat, callKey: key, ask: { _ in nil }, afterRead: afterRead)
        XCTAssertTrue(answer.text.hasPrefix("Added"), answer.text)
        return try XCTUnwrap(service.plans.pending(chatID: chat.id))
    }

    func testChangesProposedAfterAReadAreFlaggedAndTheirTrashStartsUnticked() async throws {
        write("a.dmg", "a")
        write("b.zip", "b")
        write("c (1).txt", "c")
        write("c.txt", "c")
        try service.grants.grant(root, level: .change, lifetime: .chat(chat.id), chatID: chat.id)
        let plan = try await propose([.init(kind: .makeDir, path: "~/grant/Apps"),
                                      .init(kind: .move, path: "~/grant/a.dmg", to: "~/grant/Apps/"),
                                      .init(kind: .trash, path: "~/grant/b.zip"),
                                      .init(kind: .trash, path: "~/grant/c (1).txt")], afterRead: true)
        XCTAssertTrue(plan.items.allSatisfy { $0.afterRead == true })
        var review = PlanReview(plan: plan)
        let move = try XCTUnwrap(plan.items.first { $0.kind == .move })
        let trash = plan.items.filter { $0.kind == .trash }
        XCTAssertTrue(review.isSelected(move.id), "a move is ticked: Undo takes it back")
        XCTAssertTrue(trash.allSatisfy { !review.isSelected($0.id) }, "a Trash after a read starts unticked")
        XCTAssertTrue(review.isSelected(try XCTUnwrap(plan.items.first { $0.kind == .makeDir }).id), "a new folder is ticked")
        XCTAssertEqual(review.planWarnings.first, .proposedAfterRead(items: 3, trash: 2))
        // The copy check finds c (1).txt identical: still not ticked for the user.
        review.apply(service.checks(plan), planID: plan.id, revision: plan.revision)
        XCTAssertTrue(trash.allSatisfy { !review.isSelected($0.id) })
        // The user ticks one: it's theirs.
        review.set(trash[0].id, selected: true)
        XCTAssertTrue(review.isSelected(trash[0].id))
    }

    func testAPlanThatTakesFilesOutOfASubfolderSaysSo() async throws {
        write("a.pdf", "a")
        write("Ford/manual.pdf", "m")
        write("Ford/ch1/p1.pdf", "p")
        write("Other/z.pdf", "z")
        try service.grants.grant(root, level: .change, lifetime: .chat(chat.id), chatID: chat.id)
        let plan = try await propose([
            .init(kind: .makeDir, path: "~/grant/PDFs"),
            .init(kind: .move, path: "~/grant/a.pdf", to: "~/grant/PDFs"),
            .init(kind: .move, path: "~/grant/Ford/manual.pdf", to: "~/grant/PDFs"),
            .init(kind: .move, path: "~/grant/Ford/ch1/p1.pdf", to: "~/grant/PDFs"),
            .init(kind: .move, path: "~/grant/Other/z.pdf", to: "~/grant/PDFs"),
        ])
        var review = PlanReview(plan: plan)
        XCTAssertEqual(PlanReview.reachedSubfolders(plan.items), ["Ford", "Other"])
        XCTAssertEqual(review.planWarnings, [.reachesIntoSubfolders(count: 2, names: ["Ford", "Other"])])
        // Unticked, the warning follows what Approve would do.
        review.set(plan.items[2].id, selected: false)
        review.set(plan.items[3].id, selected: false)
        review.set(plan.items[4].id, selected: false)
        XCTAssertEqual(review.planWarnings, [])
    }

    func testItemsAllInsideTheNamedSubfoldersOrAFolderMovedWholeReachIntoNothing() throws {
        let r = root!
        func item(_ id: Int, _ kind: ChangeKind, _ path: String, sourceKind: EntryKind = .file) throws -> PlanItem {
            let l = try FolderLocation(root: r, path: path)
            let source = CapturedSource(location: l, parentChain: [], identity: FileIdentity(device: 1, inode: UInt64(id)),
                                        kind: sourceKind, size: 10, hardLinked: false, fileProvider: false)
            return PlanItem(id: id, kind: kind, source: source, destination: nil, collision: .fail, dependsOn: [], notes: [])
        }
        // Sorting inside Ford, the folder the user named: all its items sit in it.
        XCTAssertEqual(PlanReview.reachedSubfolders([try item(1, .move, "Ford/a"), try item(2, .trash, "Ford/b")]), [])
        // Two of Ford's subfolders, and nothing right in Ford: the user named them.
        XCTAssertEqual(PlanReview.reachedSubfolders([try item(1, .move, "Ford/ch1/a"), try item(2, .move, "Ford/ch2/b")]), [])
        // Ford moved whole beside a loose file: one item each.
        XCTAssertEqual(PlanReview.reachedSubfolders([try item(1, .move, "Ford", sourceKind: .directory), try item(2, .move, "x.zip")]), [])
        // Deeper: the subfolder right under the tidied folder names it.
        XCTAssertEqual(PlanReview.reachedSubfolders([try item(1, .move, "x.zip"), try item(2, .trash, "Ford/ch1/deep/p")]), ["Ford"])
    }

    func testALargePlanSaysHowManyAndHowMuch() async throws {
        for i in 0..<205 { writeData(String(format: "f%03d.bin", i), bytes(1000)) }
        writeData("folder/inner", bytes(5000))
        try service.grants.grant(root, level: .change, lifetime: .chat(chat.id), chatID: chat.id)
        _ = try await propose((0..<200).map { .init(kind: .trash, path: String(format: "~/grant/f%03d.bin", $0)) })
        let plan = try await propose((200..<205).map { .init(kind: .trash, path: String(format: "~/grant/f%03d.bin", $0)) }
                                     + [.init(kind: .trash, path: "~/grant/folder")])
        var review = PlanReview(plan: plan)
        XCTAssertEqual(review.planWarnings, [.large(items: 206, bytes: 205_000, atLeast: true)], "the folder isn't measured yet")
        review.apply(service.checks(plan), planID: plan.id, revision: plan.revision)
        XCTAssertEqual(review.planWarnings, [.large(items: 206, bytes: 210_000, atLeast: false)])
        let folderItem = try XCTUnwrap(plan.items.last)
        XCTAssertEqual(review.trashSize(folderItem), FolderSize(items: 1, bytes: 5000))
        XCTAssertEqual(review.trashSize(plan.items[0]), FolderSize(items: 1, bytes: 1000))
        // 200 or fewer: nothing to say.
        review.set(plan.items[0].id, selected: false)
        review.set(plan.items[1].id, selected: false)
        review.set(plan.items[2].id, selected: false)
        review.set(plan.items[3].id, selected: false)
        review.set(plan.items[4].id, selected: false)
        review.set(plan.items[5].id, selected: false)
        XCTAssertEqual(review.planWarnings, [])
    }

    func testCopyNames() {
        XCTAssertEqual(PlanChecker.originalName(ofCopy: "1991 Ford E 350 Van V8-460 7.5L (1).zip"), "1991 Ford E 350 Van V8-460 7.5L.zip")
        XCTAssertEqual(PlanChecker.originalName(ofCopy: "report (12).pdf"), "report.pdf")
        XCTAssertEqual(PlanChecker.originalName(ofCopy: "archive (2).tar.gz"), "archive.tar.gz")
        XCTAssertEqual(PlanChecker.originalName(ofCopy: "notes copy.txt"), "notes.txt")
        XCTAssertEqual(PlanChecker.originalName(ofCopy: "notes copy 3.txt"), "notes.txt")
        XCTAssertEqual(PlanChecker.originalName(ofCopy: "photo (1)"), "photo")
        XCTAssertNil(PlanChecker.originalName(ofCopy: "report.pdf"))
        XCTAssertNil(PlanChecker.originalName(ofCopy: "Chapter 2.pdf"))
        XCTAssertNil(PlanChecker.originalName(ofCopy: "(1).pdf"))
        XCTAssertNil(PlanChecker.originalName(ofCopy: "photocopy.txt"))
    }

    func testTrashedCopiesStartUntickedAndOnlyRealOnesGetTicked() async throws {
        writeData("manual.zip", bytes(5230))
        writeData("manual (1).zip", bytes(5570))              // bigger: not the same
        writeData("same.bin", bytes(4096, 0x41))
        writeData("same (1).bin", bytes(4096, 0x42))          // same size, other bytes
        writeData("twin.bin", bytes(4096, 0x43))
        writeData("twin (1).bin", bytes(4096, 0x43))          // a real copy
        writeData("alone (1).txt", bytes(3))                  // no original
        writeData("id_rsa.pem", bytes(64, 0x44))
        writeData("id_rsa (1).pem", bytes(99, 0x45))          // a key's name: never compared, not even by size
        writeData("plain.txt", bytes(5))
        try service.grants.grant(root, level: .change, lifetime: .chat(chat.id), chatID: chat.id)
        let plan = try await propose(["manual (1).zip", "same (1).bin", "twin (1).bin", "alone (1).txt", "id_rsa (1).pem", "plain.txt"]
            .map { .init(kind: .trash, path: "~/grant/" + $0) })
        let ids = plan.items.map(\.id)
        var review = PlanReview(plan: plan)
        XCTAssertEqual(review.approvable, [ids[5]], "every copy-named trash starts unticked")
        XCTAssertTrue(review.checksPending)
        XCTAssertFalse(review.canApprove, "Approve waits for the checks")
        let checks = service.checks(plan)
        XCTAssertEqual(checks.notIdentical, [ids[0]: "manual.zip", ids[1]: "same.bin"])
        XCTAssertEqual(checks.uncompared, [ids[3]: "alone.txt", ids[4]: "id_rsa.pem"])
        XCTAssertEqual(checks.copies[ids[2]]?.verdict, .identical)
        // Checks of another revision are ignored.
        review.apply(checks, planID: plan.id, revision: plan.revision + 1)
        XCTAssertTrue(review.checksPending)
        review.apply(checks, planID: plan.id, revision: plan.revision)
        XCTAssertFalse(review.checksPending)
        XCTAssertTrue(review.canApprove)
        XCTAssertEqual(review.approvable, [ids[2], ids[5]], "only the real copy is ticked")
        XCTAssertEqual(review.planWarnings, [.notIdentical(count: 2, names: ["manual (1).zip", "same (1).bin"]),
                                             .uncompared(count: 2, names: ["alone (1).txt", "id_rsa (1).pem"])])
        // The user ticks one back: a later check (a newer revision) doesn't
        // untick it again; the one they unticked isn't ticked again.
        review.set(ids[0], selected: true)
        review.set(ids[2], selected: false)
        write("more.txt", "m")
        let newer = try await propose([.init(kind: .trash, path: "~/grant/more.txt")])
        var next = PlanReview(plan: newer, previous: review)
        XCTAssertTrue(next.checksPending, "a new revision is checked again")
        next.apply(service.checks(newer), planID: newer.id, revision: newer.revision)
        XCTAssertTrue(next.isSelected(ids[0]))
        XCTAssertFalse(next.isSelected(ids[1]))
        XCTAssertFalse(next.isSelected(ids[2]))
        XCTAssertEqual(next.checks.notIdentical[ids[0]], "manual.zip")
    }

    func testChecksThatDontComeLetApproveThroughWithCopiesUnticked() async throws {
        writeData("a.bin", bytes(10))
        writeData("a (1).bin", bytes(10))
        writeData("b.txt", bytes(1))
        try service.grants.grant(root, level: .change, lifetime: .chat(chat.id), chatID: chat.id)
        let plan = try await propose([.init(kind: .trash, path: "~/grant/a (1).bin"), .init(kind: .trash, path: "~/grant/b.txt")])
        var review = PlanReview(plan: plan)
        review.checksTimedOut(planID: plan.id, revision: plan.revision)
        XCTAssertTrue(review.canApprove)
        XCTAssertEqual(review.approvable, [plan.items[1].id], "the copy not compared stays unticked")
        // Ticked by the user without a comparison: the approval refuses it.
        review.set(plan.items[0].id, selected: true)
        XCTAssertThrowsError(try service.approve(review)) {
            guard case ChangePlanError.invalidated(let bad)? = $0 as? ChangePlanError else { return XCTFail("\($0)") }
            XCTAssertEqual(Array(bad.keys), [plan.items[0].id])
        }
    }

    func testAHardLinkedCopyIsntComparedEvenWhenTheSizesDiffer() async throws {
        let orig = writeData("h.bin", bytes(10))
        writeData("h (1).bin", bytes(20))
        XCTAssertEqual(Darwin.link(orig, outside + "/h-link"), 0)
        try service.grants.grant(root, level: .change, lifetime: .chat(chat.id), chatID: chat.id)
        let plan = try await propose([.init(kind: .trash, path: "~/grant/h (1).bin")])
        XCTAssertEqual(service.checks(plan).copies[plan.items[0].id]?.verdict, .unknown, "Hardening 5 before the sizes")
        StatFlagInjection.shared.set(UInt32(SF_DATALESS), for: try XCTUnwrap(identity(grant + "/h (1).bin")))
        XCTAssertEqual(service.checks(plan).copies[plan.items[0].id]?.verdict, .unknown)
    }

    func testAnIdenticalVerdictGoesStaleWhenEitherFileChanges() async throws {
        writeData("t.bin", bytes(100, 0x31))
        writeData("t (1).bin", bytes(100, 0x31))
        try service.grants.grant(root, level: .change, lifetime: .chat(chat.id), chatID: chat.id)
        let plan = try await propose([.init(kind: .trash, path: "~/grant/t (1).bin")])
        let id = plan.items[0].id
        var review = PlanReview(plan: plan)
        review.apply(service.checks(plan), planID: plan.id, revision: plan.revision)
        XCTAssertEqual(review.approvable, [id])
        // The original changes after the comparison: the approval refuses it.
        writeData("t.bin", bytes(100, 0x32))
        XCTAssertEqual(utimes(grant + "/t.bin", nil), 0)
        XCTAssertThrowsError(try service.approve(review)) {
            guard case ChangePlanError.invalidated(let bad)? = $0 as? ChangePlanError else { return XCTFail("\($0)") }
            XCTAssertTrue(bad[id]?.contains("changed since they were compared") == true, "\(bad)")
        }
        XCTAssertTrue(exists("t (1).bin"))
        // Compared again; only touched between approval and execution (same
        // file, same bytes, another mtime): execution hashes both again, and
        // they still match (testExecutionHashesTheCopyAndItsOriginalAgain has
        // other bytes).
        writeData("t.bin", bytes(100, 0x31))
        var again = PlanReview(plan: plan)
        again.apply(service.checks(plan), planID: plan.id, revision: plan.revision)
        let approved = try service.approve(again)
        var tv = [timeval(tv_sec: 1_000_000, tv_usec: 0), timeval(tv_sec: 1_000_000, tv_usec: 0)]
        XCTAssertEqual(utimes(grant + "/t (1).bin", &tv), 0)
        let report = service.execute(approved)
        XCTAssertEqual(PlanOutcome(report).done, 1)
        XCTAssertFalse(exists("t (1).bin"))
    }

    func testChecksKeepNothingOnceAccessEnds() async throws {
        writeData("r.bin", bytes(10, 1))
        writeData("r (1).bin", bytes(10, 2))
        writeData("dir/x", bytes(10))
        try service.grants.grant(root, level: .change, lifetime: .chat(chat.id), chatID: chat.id)
        let plan = try await propose([.init(kind: .trash, path: "~/grant/r (1).bin"), .init(kind: .trash, path: "~/grant/dir")])
        let checker = PlanChecker(denylist: denylist)
        let none = checker.check(plan, canRead: { _, _ in false })
        XCTAssertEqual(none, PlanChecks(), "nothing scanned without access")
        // Access ending during the check (after the first question).
        var asked = 0
        let ended = checker.check(plan, canRead: { _, _ in asked += 1; return asked <= 1 })
        XCTAssertEqual(ended.copies[plan.items[0].id]?.verdict, .unknown, "nothing of what was read is kept")
        XCTAssertNil(ended.sizes[plan.items[1].id])
        // Through the service: the chat's grant gone.
        service.endChat(chat.id)
        XCTAssertEqual(service.checks(plan), PlanChecks())
    }

    func testTopLevelFilesMovedIntoNewFoldersReachIntoNothing() async throws {
        write("a.pdf", "a")
        write("b.jpg", "b")
        write("c.pdf", "c")
        try service.grants.grant(root, level: .change, lifetime: .chat(chat.id), chatID: chat.id)
        let plan = try await propose([
            .init(kind: .makeDir, path: "~/grant/PDFs"),
            .init(kind: .makeDir, path: "~/grant/Images"),
            .init(kind: .move, path: "~/grant/a.pdf", to: "~/grant/PDFs"),
            .init(kind: .move, path: "~/grant/c.pdf", to: "~/grant/PDFs"),
            .init(kind: .move, path: "~/grant/b.jpg", to: "~/grant/Images"),
        ])
        XCTAssertEqual(PlanReview.reachedSubfolders(plan.items), [])
        XCTAssertEqual(PlanReview(plan: plan).planWarnings, [])
    }

    func testAChangeRefusedOnceIsntDeclaredAgainThisTurn() {
        let t = ToolTrust.TurnState(folderText: true)
        XCTAssertEqual(FolderTools.declared(featureOn: true, temporaryChat: false, turn: t, fileTextRoomSpent: false), ["files", "change_files"])
        XCTAssertEqual(FolderTools.declared(featureOn: true, temporaryChat: false, turn: t, fileTextRoomSpent: false, changeRefused: true),
                       ["files"])
        XCTAssertTrue(ToolTrust.changeRefusal.contains("Don't call it again now"), ToolTrust.changeRefusal)
    }

    func testAChangedCopyIsntCheckedAgainstItsOriginal() async throws {
        writeData("a.bin", bytes(10))
        writeData("a (1).bin", bytes(20))
        try service.grants.grant(root, level: .change, lifetime: .chat(chat.id), chatID: chat.id)
        let plan = try await propose([.init(kind: .trash, path: "~/grant/a (1).bin")])
        // Replaced after the proposal: another file under the name.
        try fm.removeItem(atPath: grant + "/a (1).bin")
        writeData("a (1).bin", bytes(30))
        XCTAssertEqual(service.checks(plan).notIdentical, [:])
    }

    // MARK: Round 2 of review

    private func approvedAfterChecks(_ plan: ChangePlan) throws -> ApprovedPlan {
        var review = PlanReview(plan: plan)
        review.apply(service.checks(plan), planID: plan.id, revision: plan.revision)
        return try service.approve(review)
    }

    func testExecutionHashesTheCopyAndItsOriginalAgain() async throws {
        writeData("t.bin", bytes(100, 0x31))
        writeData("t (1).bin", bytes(100, 0x31))
        try service.grants.grant(root, level: .change, lifetime: .chat(chat.id), chatID: chat.id)
        let plan = try await propose([.init(kind: .trash, path: "~/grant/t (1).bin")])
        let approved = try approvedAfterChecks(plan)
        // Other bytes in place: same file, same size, the old mtime put back --
        // only the hash can tell.
        let path = grant + "/t.bin"
        let mtime = try XCTUnwrap(try fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        let h = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        h.write(Data([0x32]))
        h.closeFile()
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
        let report = service.execute(approved)
        XCTAssertEqual(PlanOutcome(report).failed, 1)
        XCTAssertTrue(PlanOutcome(report).problem?.contains("no longer identical") == true, "\(PlanOutcome(report))")
        XCTAssertTrue(exists("t (1).bin"), "nothing trashed")
    }

    func testTheOriginalIsFollowedWhereAnEarlierMoveTookIt() async throws {
        writeData("t.bin", bytes(100, 0x31))
        writeData("t (1).bin", bytes(100, 0x31))
        try service.grants.grant(root, level: .change, lifetime: .chat(chat.id), chatID: chat.id)
        let plan = try await propose([
            .init(kind: .makeDir, path: "~/grant/Keep"),
            .init(kind: .move, path: "~/grant/t.bin", to: "~/grant/Keep"),
            .init(kind: .trash, path: "~/grant/t (1).bin"),
        ])
        let report = service.execute(try approvedAfterChecks(plan))
        XCTAssertEqual(PlanOutcome(report).done, 3, "\(PlanOutcome(report))")
        XCTAssertFalse(exists("t (1).bin"))
        XCTAssertTrue(exists("Keep/t.bin"))
    }

    func testACopyWhoseOriginalWasTrashedEarlierIsntTrashedAsACopy() async throws {
        writeData("t.bin", bytes(100, 0x31))
        writeData("t (1).bin", bytes(100, 0x31))
        try service.grants.grant(root, level: .change, lifetime: .chat(chat.id), chatID: chat.id)
        let plan = try await propose([.init(kind: .trash, path: "~/grant/t.bin"), .init(kind: .trash, path: "~/grant/t (1).bin")])
        let report = service.execute(try approvedAfterChecks(plan))
        XCTAssertEqual(PlanOutcome(report).done, 1)
        XCTAssertEqual(PlanOutcome(report).failed, 1)
        XCTAssertTrue(exists("t (1).bin"), "the last one isn't trashed on a comparison that can't be made again")
    }

    func testAMeasurementOfAFolderThatLeftTheGrantIsDropped() throws {
        writeData("a/sub/x", bytes(10))
        let dir = try walker.openDirectory(["a"])
        XCTAssertEqual(walker.subtreeScan(in: dir, "sub", budget: 100, measure: true).size, FolderSize(items: 1, bytes: 10))
        // Moved out of the grant while held: what it holds isn't shown.
        try fm.moveItem(atPath: grant + "/a", toPath: outside + "/a")
        let r = walker.subtreeScan(in: dir, "sub", budget: 100, measure: true)
        XCTAssertNil(r.size)
        XCTAssertEqual(r.protected, .unchecked)
    }
}
