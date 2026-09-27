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

/// One row per folder in Settings: standing grants of the same folder merge.
extension FolderGrantsTests {
    func testStandingGrantsOfOneFolderMerge() throws {
        let g = FolderGrants(storeURL: store, now: t0)
        let first = try g.grant(docs, level: .read, lifetime: .until(t0.addingTimeInterval(3600)), chatID: "c", origin: .chat, now: t0)
        // A later hour: the later end.
        let later = try g.grant(docs, level: .read, lifetime: .until(t0.addingTimeInterval(4000)), chatID: "c", now: t0.addingTimeInterval(400))
        XCTAssertEqual(later.id, first.id)
        XCTAssertEqual(g.standingGrants(now: t0).map(\.lifetime), [.until(t0.addingTimeInterval(4000))])
        // An earlier end doesn't shorten it; change is the higher level.
        try g.grant(docs, level: .change, lifetime: .until(t0.addingTimeInterval(100)), chatID: nil, origin: .settings, now: t0)
        var only = try XCTUnwrap(g.standingGrants(now: t0).first)
        XCTAssertEqual(g.standingGrants(now: t0).count, 1)
        XCTAssertEqual(only.level, .change)
        XCTAssertEqual(only.lifetime, .until(t0.addingTimeInterval(4000)))
        XCTAssertEqual(only.origin, .chat, "where it was first given")
        // Always wins; read doesn't lower change.
        try g.grant(docs, level: .read, lifetime: .always, chatID: "c", now: t0)
        only = try XCTUnwrap(g.standingGrants(now: t0).first)
        XCTAssertEqual(g.standingGrants(now: t0).count, 1)
        XCTAssertEqual(only.level, .change)
        XCTAssertEqual(only.lifetime, .always)
        try g.grant(docs, level: .read, lifetime: .until(t0.addingTimeInterval(9000)), chatID: "c", now: t0)
        XCTAssertEqual(g.standingGrants(now: t0).first?.lifetime, .always, "an hour doesn't shorten always")
        // On disk as one.
        XCTAssertEqual(FolderGrants(storeURL: store, now: t0).standingGrants(now: t0), g.standingGrants(now: t0))
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
        XCTAssertEqual(loaded[0].lifetime, .until(t0.addingTimeInterval(120)))
        XCTAssertEqual(loaded[0].origin, .chat)
        XCTAssertEqual(loaded[1].level, .read, "an expired duplicate adds nothing")
        // Written back merged.
        let stored = try JSONDecoder().decode([FolderGrant].self, from: Data(contentsOf: store))
        XCTAssertEqual(stored.count, 2)
    }

    func testOriginRoundTripsAndOldGrantsHaveNone() throws {
        let g = FolderGrants(storeURL: store, now: t0)
        try g.grant(docs, level: .read, lifetime: .always, chatID: nil, origin: .settings, now: t0)
        try g.grant(downloads, level: .read, lifetime: .always, chatID: "c", origin: .chat, now: t0)
        let reloaded = FolderGrants(storeURL: store, now: t0).standingGrants(now: t0)
        XCTAssertEqual(reloaded.map(\.origin), [.settings, .chat])
        // A store from before the field: decoded, no origin.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [[String: Any]])
        XCTAssertNotNil(legacy[0]["origin"])
        for i in legacy.indices { legacy[i]["origin"] = nil }
        try JSONSerialization.data(withJSONObject: legacy).write(to: store)
        let old = FolderGrants(storeURL: store, now: t0).standingGrants(now: t0)
        XCTAssertEqual(old.count, 2)
        XCTAssertEqual(old.map(\.origin), [nil, nil])
    }

    func testRevokingAMergedRowRemovesTheFolder() throws {
        let g = FolderGrants(storeURL: store, now: t0)
        try g.grant(downloads, level: .read, lifetime: .until(t0.addingTimeInterval(3600)), chatID: "c", now: t0)
        let merged = try g.grant(downloads, level: .change, lifetime: .always, chatID: "c", now: t0)
        try g.revoke(merged.id)
        XCTAssertTrue(g.standingGrants(now: t0).isEmpty)
        XCTAssertNil(g.authorize(path: downloads.path, level: .read, chatID: "c", callKey: "k", now: t0))
        XCTAssertTrue(FolderGrants(storeURL: store, now: t0).standingGrants(now: t0).isEmpty)
    }

    func testUpdateSetsLevelAndLifetimeExactly() throws {
        let g = FolderGrants(storeURL: store, now: t0)
        let grant = try g.grant(docs, level: .change, lifetime: .always, chatID: "c", origin: .chat, now: t0)
        let hour = t0.addingTimeInterval(3600)
        let updated = try g.update(grant.id, root: docs, level: .read, lifetime: .until(hour), now: t0)
        XCTAssertEqual(updated?.level, .read, "lowered, unlike a merge")
        XCTAssertEqual(updated?.lifetime, .until(hour))
        XCTAssertEqual(updated?.origin, .chat)
        XCTAssertFalse(g.coversChange(path: docs.path, chatID: "c", proposal: nil, now: t0))
        XCTAssertEqual(FolderGrants(storeURL: store, now: t0).standingGrants(now: t0).first?.level, .read)
        XCTAssertNil(try g.update(grant.id, root: docs, level: .read, lifetime: .chat("c"), now: t0), "standing only")
        XCTAssertNil(try g.update(grant.id, root: downloads, level: .read, lifetime: .always, now: t0), "same folder only")
        XCTAssertNil(try g.update(grant.id, root: docs, level: .read, lifetime: .always, now: hour), "expired")
        try g.revoke(grant.id)
        XCTAssertNil(try g.update(grant.id, root: docs, level: .read, lifetime: .always, now: t0), "gone")
    }
}
