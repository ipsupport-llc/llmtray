import Foundation
import XCTest
@testable import LLMTrayCore

final class FolderGrantsTests: XCTestCase {
    private var dir: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let docs = FolderRoot(path: "/Users/u/Documents", identity: FileIdentity(device: 1, inode: 100))
    private let downloads = FolderRoot(path: "/Users/u/Downloads", identity: FileIdentity(device: 1, inode: 200))

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("llmtray-grants-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var store: URL { dir.appendingPathComponent("grants.json") }

    func testLevelsAndContainment() throws {
        let g = FolderGrants(storeURL: nil)
        try g.grant(docs, level: .read, lifetime: .always, chatID: "c")
        XCTAssertNotNil(g.authorize(path: "/Users/u/Documents/a/b.txt", level: .read, chatID: "c", callKey: "k", now: t0))
        XCTAssertNotNil(g.authorize(path: "/Users/u/Documents", level: .read, chatID: "c", callKey: "k", now: t0))
        XCTAssertNil(g.authorize(path: "/Users/u/Documents/a", level: .change, chatID: "c", callKey: "k", now: t0),
                     "read never implies change")
        XCTAssertNil(g.authorize(path: "/Users/u/Documents2/x", level: .read, chatID: "c", callKey: "k", now: t0),
                     "a sibling with the same prefix isn't inside")
        XCTAssertNil(g.authorize(path: "/Users/u", level: .read, chatID: "c", callKey: "k", now: t0))
        try g.grant(downloads, level: .change, lifetime: .always, chatID: "c")
        XCTAssertNotNil(g.authorize(path: "/Users/u/Downloads/x", level: .read, chatID: "c", callKey: "k", now: t0),
                        "change includes read")
    }

    func testOnceIsConsumedByExactlyOneCall() throws {
        let g = FolderGrants(storeURL: nil)
        try g.grant(docs, level: .read, lifetime: .once(callKey: "call-1", chatID: "c"), chatID: "c", now: t0)
        XCTAssertNil(g.authorize(path: docs.path, level: .read, chatID: "c", callKey: "call-2", now: t0),
                     "another call can't use it")
        // Many threads race for it; one wins.
        let wins = NSLock()
        var count = 0
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if g.authorize(path: self.docs.path + "/f", level: .read, chatID: "c", callKey: "call-1", now: self.t0) != nil {
                wins.lock(); count += 1; wins.unlock()
            }
        }
        XCTAssertEqual(count, 1)
        XCTAssertTrue(g.allGrants(now: t0).isEmpty)
        // Bound to its chat, and gone with it.
        try g.grant(docs, level: .read, lifetime: .once(callKey: "call-3", chatID: "c"), chatID: "c", now: t0)
        XCTAssertNil(g.authorize(path: docs.path, level: .read, chatID: "other", callKey: "call-3", now: t0))
        g.endChat("c")
        XCTAssertNil(g.authorize(path: docs.path, level: .read, chatID: "c", callKey: "call-3", now: t0))
    }

    func testALastingGrantIsPreferredOverOnce() throws {
        let g = FolderGrants(storeURL: nil)
        try g.grant(docs, level: .read, lifetime: .once(callKey: "k", chatID: "c"), chatID: "c")
        try g.grant(docs, level: .read, lifetime: .chat("c"), chatID: "c")
        XCTAssertEqual(g.authorize(path: docs.path, level: .read, chatID: "c", callKey: "k", now: t0)?.lifetime, .chat("c"))
        XCTAssertEqual(g.allGrants().count, 2, "once kept for its call")
    }

    func testExpiryAndChatScope() throws {
        let g = FolderGrants(storeURL: nil)
        try g.grant(docs, level: .read, lifetime: .until(t0.addingTimeInterval(3600)), chatID: "c", now: t0)
        try g.grant(downloads, level: .read, lifetime: .chat("c1"), chatID: "c1", now: t0)
        XCTAssertNotNil(g.authorize(path: docs.path, level: .read, chatID: "any", callKey: "k", now: t0.addingTimeInterval(3599)))
        XCTAssertNil(g.authorize(path: docs.path, level: .read, chatID: "any", callKey: "k", now: t0.addingTimeInterval(3600)))
        XCTAssertNotNil(g.authorize(path: downloads.path, level: .read, chatID: "c1", callKey: "k", now: t0))
        XCTAssertNil(g.authorize(path: downloads.path, level: .read, chatID: "c2", callKey: "k", now: t0))
        g.endChat("c1")
        XCTAssertNil(g.authorize(path: downloads.path, level: .read, chatID: "c1", callKey: "k", now: t0))
    }

    func testOnlyStandingGrantsPersist() throws {
        let a = FolderGrants(storeURL: store, now: t0)
        let always = try a.grant(docs, level: .change, lifetime: .always, chatID: "c", now: t0)
        try a.grant(downloads, level: .read, lifetime: .until(t0.addingTimeInterval(60)), chatID: "c", now: t0)
        try a.grant(downloads, level: .read, lifetime: .chat("c"), chatID: "c", now: t0)
        try a.grant(downloads, level: .read, lifetime: .once(callKey: "k", chatID: "c"), chatID: "c", now: t0)
        XCTAssertEqual(FolderGrants(storeURL: store, now: t0).standingGrants(now: t0).count, 2)
        // Reloaded after the hour: the expired one is gone.
        let later = FolderGrants(storeURL: store, now: t0.addingTimeInterval(61))
        XCTAssertEqual(later.standingGrants(now: t0.addingTimeInterval(61)).map(\.id), [always.id])
        try later.revoke(always.id)
        XCTAssertTrue(FolderGrants(storeURL: store, now: t0).standingGrants(now: t0).isEmpty)
    }

    func testAStandingGrantThatCantBeSavedDoesntExist() throws {
        // The store's folder can't be made: a file is in the way.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("blocked").path, contents: Data())
        let g = FolderGrants(storeURL: dir.appendingPathComponent("blocked/grants.json"))
        XCTAssertThrowsError(try g.grant(docs, level: .read, lifetime: .always, chatID: "c"))
        XCTAssertTrue(g.allGrants().isEmpty)
        XCTAssertNoThrow(try g.grant(docs, level: .read, lifetime: .chat("c"), chatID: "c"), "in memory only")
    }

    func testTemporaryChatsGetReadForTheChatOnly() throws {
        let g = FolderGrants(storeURL: store)
        XCTAssertThrowsError(try g.grant(docs, level: .change, lifetime: .chat("t"), chatID: "t", temporaryChat: true))
        XCTAssertThrowsError(try g.grant(docs, level: .read, lifetime: .always, chatID: "t", temporaryChat: true))
        XCTAssertThrowsError(try g.grant(docs, level: .read, lifetime: .until(t0), chatID: "t", temporaryChat: true))
        XCTAssertThrowsError(try g.grant(docs, level: .read, lifetime: .chat("other"), chatID: "t", temporaryChat: true))
        XCTAssertNoThrow(try g.grant(docs, level: .read, lifetime: .chat("t"), chatID: "t", temporaryChat: true))
        XCTAssertNoThrow(try g.grant(docs, level: .read, lifetime: .once(callKey: "k", chatID: "t"), chatID: "t", temporaryChat: true))
        XCTAssertThrowsError(try g.grant(docs, level: .read, lifetime: .once(callKey: "k", chatID: "c"), chatID: "t", temporaryChat: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path), "nothing written")
        // A standing grant from a normal chat doesn't reach a temporary one,
        // not even for reading (Hardening 8: no grants beyond the chat).
        try g.grant(downloads, level: .change, lifetime: .always, chatID: "n")
        XCTAssertNil(g.authorize(path: downloads.path, level: .change, chatID: "t", callKey: "k", temporaryChat: true, now: t0))
        XCTAssertNil(g.authorize(path: downloads.path, level: .read, chatID: "t", callKey: "k", temporaryChat: true, now: t0))
        XCTAssertNotNil(g.authorize(path: downloads.path, level: .read, chatID: "n", callKey: "k", now: t0))
        XCTAssertFalse(g.coversChange(path: downloads.path, chatID: "t", proposal: nil, temporaryChat: true, now: t0))
        // Its own chat grant does.
        XCTAssertNotNil(g.authorize(path: docs.path + "/a", level: .read, chatID: "t", callKey: "k", temporaryChat: true, now: t0))
        XCTAssertNil(g.authorize(path: docs.path, level: .read, chatID: "other", callKey: "k", temporaryChat: true, now: t0))
    }

    func testADenyHoldsAgainstEquivalentTargetsAndUpgrades() {
        let g = FolderGrants(storeURL: nil)
        g.deny(docs, level: .read, chatID: "c")
        func decision(_ path: String, _ id: FileIdentity?, _ level: FolderAccessLevel, chat: String = "c") -> PromptDecision {
            g.shouldPrompt(path: path, identity: id, level: level, chatID: chat, origin: .model)
        }
        func refused(_ d: PromptDecision) -> Bool { if case .refuse = d { return true }; return false }
        XCTAssertTrue(refused(decision(docs.path, docs.identity, .read)))
        XCTAssertTrue(refused(decision(docs.path, docs.identity, .change)), "an upgrade")
        XCTAssertTrue(refused(decision("/System/Volumes/Data/Users/u/Documents", docs.identity, .read)), "same identity, other spelling")
        XCTAssertTrue(refused(decision(docs.path + "/sub", nil, .read)), "inside")
        XCTAssertTrue(refused(decision("/Users/u", nil, .read)), "around it")
        XCTAssertEqual(decision(docs.path, docs.identity, .read, chat: "other"), .prompt, "per chat")
        // The user asking themselves always prompts.
        XCTAssertEqual(g.shouldPrompt(path: docs.path, identity: docs.identity, level: .read, chatID: "c", origin: .user), .prompt)
    }

    func testNoModelPromptAfterADenyUntilTheUserAsks() throws {
        let g = FolderGrants(storeURL: nil)
        g.deny(docs, level: .change, chatID: "c")
        func refused(_ d: PromptDecision) -> Bool { if case .refuse = d { return true }; return false }
        // An unrelated folder: still no model prompt in this chat.
        XCTAssertTrue(refused(g.shouldPrompt(path: downloads.path, identity: downloads.identity, level: .read,
                                             chatID: "c", origin: .model)))
        g.userAskedForAccess(chatID: "c")
        XCTAssertEqual(g.shouldPrompt(path: downloads.path, identity: downloads.identity, level: .read, chatID: "c", origin: .model),
                       .prompt)
        // The deny itself still holds for its folder...
        XCTAssertTrue(refused(g.shouldPrompt(path: docs.path, identity: docs.identity, level: .change, chatID: "c", origin: .model)))
        // ...a lower level than the one denied may be asked.
        XCTAssertEqual(g.shouldPrompt(path: docs.path, identity: docs.identity, level: .read, chatID: "c", origin: .model), .prompt)
        // A read grant doesn't answer a change deny; a change grant does.
        try g.grant(docs, level: .read, lifetime: .chat("c"), chatID: "c")
        XCTAssertEqual(g.denies(chatID: "c").count, 1)
        try g.grant(docs, level: .change, lifetime: .chat("c"), chatID: "c")
        XCTAssertTrue(g.denies(chatID: "c").isEmpty)
    }
}

extension FolderGrantsTests {
    func testTheChangeCheckFollowsRevocationWithoutUsingAnythingUp() throws {
        let g = FolderGrants(storeURL: nil)
        let always = try g.grant(docs, level: .change, lifetime: .always, chatID: "c", now: t0)
        try g.grant(downloads, level: .read, lifetime: .always, chatID: "c", now: t0)
        XCTAssertTrue(g.coversChange(path: docs.path + "/a/b", chatID: "c", proposal: nil, now: t0))
        XCTAssertFalse(g.coversChange(path: downloads.path + "/a", chatID: "c", proposal: nil, now: t0), "read isn't change")
        let check = g.changeCheck(chatID: "c")
        let loc = FolderLocation(root: docs, components: ["a"])
        XCTAssertTrue(check(loc, nil))
        try g.revoke(always.id)
        XCTAssertFalse(check(loc, nil), "revoked: the check says so at once")
        // A once grant: consumed by its call, still covering that call's
        // proposal at approval and execution -- nothing for another chat.
        try g.grant(docs, level: .change, lifetime: .once(callKey: "k1", chatID: "c"), chatID: "c", now: t0)
        XCTAssertTrue(g.coversChange(path: docs.path, chatID: "c", proposal: "k1", now: t0), "not consumed by the check")
        XCTAssertNotNil(g.authorize(path: docs.path, level: .change, chatID: "c", callKey: "k1", now: t0))
        XCTAssertNil(g.authorize(path: docs.path, level: .change, chatID: "c", callKey: "k1", now: t0), "used up")
        XCTAssertTrue(g.coversChange(path: docs.path + "/x", chatID: "c", proposal: "k1", now: t0))
        XCTAssertFalse(g.coversChange(path: docs.path + "/x", chatID: "d", proposal: "k1", now: t0))
        g.endChat("c")
        XCTAssertFalse(g.coversChange(path: docs.path + "/x", chatID: "c", proposal: "k1", now: t0))
        // An expired grant stops covering.
        try g.grant(docs, level: .change, lifetime: .until(t0.addingTimeInterval(60)), chatID: "c", now: t0)
        XCTAssertTrue(g.coversChange(path: docs.path, chatID: "c", proposal: nil, now: t0))
        XCTAssertFalse(g.coversChange(path: docs.path, chatID: "c", proposal: nil, now: t0.addingTimeInterval(61)))
    }

    func testAConsumedOnceCoversOnlyTheProposalItAuthorized() throws {
        let g = FolderGrants(storeURL: nil)
        try g.grant(docs, level: .change, lifetime: .once(callKey: "call-1", chatID: "c"), chatID: "c", now: t0)
        XCTAssertNotNil(g.authorize(path: docs.path + "/a", level: .change, chatID: "c", callKey: "call-1", now: t0))
        // That call's proposal stays covered (approval, execution, undo)...
        XCTAssertTrue(g.coversChange(path: docs.path + "/a", chatID: "c", proposal: "call-1", now: t0))
        XCTAssertTrue(g.coversChange(path: docs.path + "/deep/b", chatID: "c", proposal: "call-1", now: t0))
        // ...a later proposal in the same chat isn't: it needs its own grant.
        XCTAssertFalse(g.coversChange(path: docs.path + "/a", chatID: "c", proposal: "call-2", now: t0))
        XCTAssertFalse(g.coversChange(path: docs.path + "/a", chatID: "c", proposal: nil, now: t0), "no key: no once")
        XCTAssertNil(g.authorize(path: docs.path + "/a", level: .change, chatID: "c", callKey: "call-2", now: t0))
        let check = g.changeCheck(chatID: "c")
        XCTAssertTrue(check(FolderLocation(root: docs, components: ["a"]), "call-1"))
        XCTAssertFalse(check(FolderLocation(root: docs, components: ["a"]), "call-2"))
        // A used-up once can still be revoked: its proposal stops being covered.
        let revocable = try g.grant(docs, level: .change, lifetime: .once(callKey: "call-5", chatID: "c"), chatID: "c", now: t0)
        XCTAssertNotNil(g.authorize(path: docs.path + "/r", level: .change, chatID: "c", callKey: "call-5", now: t0))
        XCTAssertTrue(g.coversChange(path: docs.path + "/r", chatID: "c", proposal: "call-5", now: t0))
        try g.revoke(revocable.id)
        XCTAssertFalse(g.coversChange(path: docs.path + "/r", chatID: "c", proposal: "call-5", now: t0))
        // An unconsumed once is bound to its key as well.
        try g.grant(downloads, level: .change, lifetime: .once(callKey: "call-3", chatID: "c"), chatID: "c", now: t0)
        XCTAssertFalse(g.coversChange(path: downloads.path, chatID: "c", proposal: "call-4", now: t0))
        XCTAssertTrue(g.coversChange(path: downloads.path, chatID: "c", proposal: "call-3", now: t0))
    }
}

/// One row per folder in Settings: standing grants of the same folder merge
/// -- looking for the longest given, changes never longer than given.
extension FolderGrantsTests {
    private var hour: GrantLifetime { .until(t0.addingTimeInterval(3600)) }

    private func merge(_ a: (FolderAccessLevel, GrantLifetime), _ b: (FolderAccessLevel, GrantLifetime),
                       store url: URL? = nil) throws -> (FolderGrants, FolderGrant) {
        let g = FolderGrants(storeURL: url, now: t0)
        try g.grant(docs, level: a.0, lifetime: a.1, chatID: "c", now: t0)
        try g.grant(docs, level: b.0, lifetime: b.1, chatID: "c", now: t0)
        XCTAssertEqual(g.standingGrants(now: t0).count, 1, "one row")
        return (g, try XCTUnwrap(g.standingGrants(now: t0).first))
    }

    func testChangeForAnHourPlusReadAlways() throws {
        for order in [false, true] {
            let a: (FolderAccessLevel, GrantLifetime) = (.change, hour), b: (FolderAccessLevel, GrantLifetime) = (.read, .always)
            let (g, m) = try merge(order ? b : a, order ? a : b)
            XCTAssertEqual(m.level, .change)
            XCTAssertEqual(m.changeLifetime, hour, "change isn't widened")
            XCTAssertEqual(m.lookLifetime, .always, "the read always isn't lost")
            // After the hour: looking on, no changes.
            let later = t0.addingTimeInterval(3601)
            XCTAssertFalse(g.coversChange(path: docs.path, chatID: "c", proposal: nil, now: later))
            XCTAssertNil(g.authorize(path: docs.path, level: .change, chatID: "c", callKey: "k", now: later))
            XCTAssertNotNil(g.authorize(path: docs.path + "/a", level: .read, chatID: "c", callKey: "k", now: later))
            XCTAssertTrue(g.coversRead(path: docs.path, chatID: "c", callKey: "k", now: later))
            XCTAssertEqual(g.standingGrants(now: later).first?.level, .read)
            XCTAssertEqual(g.standingGrants(now: later).first?.lifetime, .always)
        }
    }

    func testReadForAnHourPlusReadAlways() throws {
        let (_, m) = try merge((.read, hour), (.read, .always))
        XCTAssertEqual(m.level, .read)
        XCTAssertEqual(m.lifetime, .always)
        XCTAssertNil(m.readLifetime)
        XCTAssertEqual(try merge((.read, .always), (.read, hour)).1.lifetime, .always)
    }

    func testTwoChangeGrantsTakeTheLaterAndAnHourALaterHour() throws {
        let later = GrantLifetime.until(t0.addingTimeInterval(7200))
        var m = try merge((.change, hour), (.change, later)).1
        XCTAssertEqual(m.lifetime, later)
        XCTAssertNil(m.readLifetime)
        m = try merge((.change, hour), (.change, .always)).1
        XCTAssertEqual(m.lifetime, .always)
        m = try merge((.read, later), (.read, hour)).1
        XCTAssertEqual(m.lifetime, later, "an earlier end doesn't shorten it")
        // Change for an hour + read for longer: both kept, then nothing.
        let (g, both) = try merge((.change, hour), (.read, later))
        XCTAssertEqual(both.changeLifetime, hour)
        XCTAssertEqual(both.lookLifetime, later)
        XCTAssertEqual(g.standingGrants(now: t0.addingTimeInterval(3700)).first?.level, .read)
        XCTAssertTrue(g.standingGrants(now: t0.addingTimeInterval(7200)).isEmpty, "all of it ended")
        XCTAssertFalse(g.coversRead(path: docs.path, chatID: "c", callKey: "k", now: t0.addingTimeInterval(7200)))
    }

    func testTheExpiryFallbackIsSavedAsARead() throws {
        _ = try merge((.change, hour), (.read, .always), store: store)
        let later = t0.addingTimeInterval(4000)
        let reloaded = FolderGrants(storeURL: store, now: later).standingGrants(now: later)
        XCTAssertEqual(reloaded.map(\.level), [.read])
        XCTAssertEqual(reloaded.first?.lifetime, .always)
        let stored = try JSONDecoder().decode([FolderGrant].self, from: Data(contentsOf: store))
        XCTAssertEqual(stored.first?.level, .read, "written back as it stands")
    }

    func testMergeKeepsTheFirstOriginAndTheID() throws {
        let g = FolderGrants(storeURL: nil)
        let first = try g.grant(docs, level: .read, lifetime: hour, chatID: "c", origin: .chat, now: t0)
        let merged = try g.grant(docs, level: .change, lifetime: .always, chatID: nil, origin: .settings, now: t0)
        XCTAssertEqual(merged.id, first.id)
        XCTAssertEqual(merged.origin, .chat)
    }

    func testAnExpiredGrantIsntMergedInto() throws {
        let g = FolderGrants(storeURL: nil)
        try g.grant(docs, level: .change, lifetime: .until(t0.addingTimeInterval(60)), chatID: "c", now: t0)
        let fresh = try g.grant(docs, level: .read, lifetime: .until(t0.addingTimeInterval(3700)), chatID: "c", now: t0.addingTimeInterval(100))
        XCTAssertEqual(fresh.level, .read, "the ended grant's change isn't carried over")
        XCTAssertEqual(g.standingGrants(now: t0.addingTimeInterval(100)).count, 1)
    }

    func testParentAndChildAndPerChatGrantsStayApart() throws {
        let g = FolderGrants(storeURL: nil)
        let parent = FolderRoot(path: "/Users/u/Work", identity: FileIdentity(device: 1, inode: 300))
        let child = FolderRoot(path: "/Users/u/Work/Sub", identity: FileIdentity(device: 1, inode: 301))
        try g.grant(parent, level: .read, lifetime: .always, chatID: "c", now: t0)
        try g.grant(child, level: .change, lifetime: .always, chatID: "c", now: t0)
        XCTAssertEqual(g.standingGrants(now: t0).map(\.root.path), [parent.path, child.path])
        XCTAssertNil(g.authorize(path: parent.path + "/a", level: .change, chatID: "c", callKey: "k", now: t0),
                     "the child's change doesn't reach its parent")
        // Chat and once grants aren't merged, nor listed.
        try g.grant(parent, level: .change, lifetime: .chat("c"), chatID: "c", now: t0)
        try g.grant(parent, level: .change, lifetime: .once(callKey: "k", chatID: "c"), chatID: "c", now: t0)
        XCTAssertEqual(g.standingGrants(now: t0).first?.level, .read)
        XCTAssertEqual(g.allGrants(now: t0).count, 4)
    }

    func testDuplicatesOnDiskAreMergedOnLoad() throws {
        let a = FolderGrant(root: downloads, level: .read, lifetime: .until(t0.addingTimeInterval(60)), created: t0, origin: .chat)
        let b = FolderGrant(root: downloads, level: .read, lifetime: .until(t0.addingTimeInterval(120)), created: t0)
        let c = FolderGrant(root: downloads, level: .change, lifetime: .until(t0.addingTimeInterval(90)), created: t0)
        let d = FolderGrant(root: docs, level: .read, lifetime: .always, created: t0)
        let old = FolderGrant(root: docs, level: .change, lifetime: .until(t0.addingTimeInterval(-1)), created: t0)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode([a, b, c, d, old]).write(to: store)
        let g = FolderGrants(storeURL: store, now: t0)
        let loaded = g.standingGrants(now: t0)
        XCTAssertEqual(loaded.map(\.root.path), [downloads.path, docs.path])
        XCTAssertEqual(loaded[0].id, a.id)
        XCTAssertEqual(loaded[0].level, .change)
        XCTAssertEqual(loaded[0].changeLifetime, .until(t0.addingTimeInterval(90)), "change's own end")
        XCTAssertEqual(loaded[0].lookLifetime, .until(t0.addingTimeInterval(120)), "the longest look")
        XCTAssertEqual(loaded[0].origin, .chat)
        XCTAssertEqual(loaded[1].level, .read, "an expired duplicate adds nothing")
        // Written back merged.
        let stored = try JSONDecoder().decode([FolderGrant].self, from: Data(contentsOf: store))
        XCTAssertEqual(stored.count, 2)
    }

    /// The file as an older build reads it: `level` and `lifetime` are the
    /// strongest access with its own end, so it never gets more than this one
    /// grants -- the longer look is a key it doesn't know.
    func testTheStoreStaysReadableByOlderBuilds() throws {
        _ = try merge((.change, hour), (.read, .always), store: store)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [[String: Any]])
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw[0]["level"] as? Int, FolderAccessLevel.change.rawValue)
        XCTAssertNotNil(raw[0]["readLifetime"])
        // What an older build decodes: the fields it knows.
        struct OldGrant: Decodable { var id: UUID; var root: FolderRoot; var level: FolderAccessLevel; var lifetime: GrantLifetime; var created: Date }
        let old = try JSONDecoder().decode([OldGrant].self, from: Data(contentsOf: store))
        XCTAssertEqual(old.first?.level, .change)
        XCTAssertEqual(old.first?.lifetime, hour, "change only as long as given")
        // And a file from an older build: no origin, no look lifetime.
        var legacy = raw
        legacy[0]["origin"] = nil
        legacy[0]["readLifetime"] = nil
        try JSONSerialization.data(withJSONObject: legacy).write(to: store)
        let loaded = try XCTUnwrap(FolderGrants(storeURL: store, now: t0).standingGrants(now: t0).first)
        XCTAssertNil(loaded.origin)
        XCTAssertNil(loaded.readLifetime)
        XCTAssertEqual(loaded.lifetime, hour)
    }

    func testOriginRoundTrips() throws {
        let g = FolderGrants(storeURL: store, now: t0)
        try g.grant(docs, level: .read, lifetime: .always, chatID: nil, origin: .settings, now: t0)
        try g.grant(downloads, level: .read, lifetime: .always, chatID: "c", origin: .chat, now: t0)
        XCTAssertEqual(FolderGrants(storeURL: store, now: t0).standingGrants(now: t0).map(\.origin), [.settings, .chat])
    }

    func testRevokingAMergedRowRemovesTheFolder() throws {
        let (g, merged) = try merge((.change, hour), (.read, .always), store: store)
        try g.revoke(merged.id)
        XCTAssertTrue(g.standingGrants(now: t0).isEmpty)
        XCTAssertNil(g.authorize(path: docs.path, level: .read, chatID: "c", callKey: "k", now: t0))
        XCTAssertNil(g.authorize(path: docs.path, level: .read, chatID: "c", callKey: "k", now: t0.addingTimeInterval(4000)))
        XCTAssertTrue(FolderGrants(storeURL: store, now: t0).standingGrants(now: t0).isEmpty)
    }

    func testUpdateSetsItExactlyForTheSameFolderOnly() throws {
        let g = FolderGrants(storeURL: store, now: t0)
        let grant = try g.grant(docs, level: .change, lifetime: .always, chatID: "c", origin: .chat, now: t0)
        let updated = try g.update(grant.id, root: docs, level: .read, lifetime: hour, now: t0)
        XCTAssertEqual(updated.level, .read, "lowered, unlike a merge")
        XCTAssertEqual(updated.lifetime, hour)
        XCTAssertEqual(updated.origin, .chat)
        XCTAssertFalse(g.coversChange(path: docs.path, chatID: "c", proposal: nil, now: t0))
        XCTAssertEqual(FolderGrants(storeURL: store, now: t0).standingGrants(now: t0).first?.level, .read)
        XCTAssertThrowsError(try g.update(grant.id, root: docs, level: .read, lifetime: .chat("c"), now: t0)) {
            XCTAssertEqual($0 as? FolderGrants.GrantError, .notStanding)
        }
        let replaced = FolderRoot(path: docs.path, identity: FileIdentity(device: 1, inode: 999))
        XCTAssertThrowsError(try g.update(grant.id, root: replaced, level: .change, lifetime: .always, now: t0)) {
            XCTAssertEqual($0 as? FolderGrants.GrantError, .folderChanged, "another folder at the same path")
        }
        XCTAssertEqual(g.standingGrants(now: t0).first?.level, .read, "nothing changed")
        XCTAssertThrowsError(try g.update(grant.id, root: docs, level: .read, lifetime: .always, now: t0.addingTimeInterval(3600))) {
            XCTAssertEqual($0 as? FolderGrants.GrantError, .gone, "ended")
        }
    }
}
