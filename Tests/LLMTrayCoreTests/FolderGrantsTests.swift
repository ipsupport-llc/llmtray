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
        XCTAssertFalse(g.coversChange(path: downloads.path, chatID: "t", temporaryChat: true, now: t0))
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
        XCTAssertTrue(g.coversChange(path: docs.path + "/a/b", chatID: "c", now: t0))
        XCTAssertFalse(g.coversChange(path: downloads.path + "/a", chatID: "c", now: t0), "read isn't change")
        let check = g.changeCheck(chatID: "c")
        let loc = FolderLocation(root: docs, components: ["a"])
        XCTAssertTrue(check(loc))
        try g.revoke(always.id)
        XCTAssertFalse(check(loc), "revoked: the check says so at once")
        // A once grant: consumed by its call, still covering that chat's
        // change at approval and execution -- and nothing for another chat.
        try g.grant(docs, level: .change, lifetime: .once(callKey: "k1", chatID: "c"), chatID: "c", now: t0)
        XCTAssertTrue(g.coversChange(path: docs.path, chatID: "c", now: t0), "not consumed by the check")
        XCTAssertNotNil(g.authorize(path: docs.path, level: .change, chatID: "c", callKey: "k1", now: t0))
        XCTAssertNil(g.authorize(path: docs.path, level: .change, chatID: "c", callKey: "k1", now: t0), "used up")
        XCTAssertTrue(g.coversChange(path: docs.path + "/x", chatID: "c", now: t0))
        XCTAssertFalse(g.coversChange(path: docs.path + "/x", chatID: "d", now: t0))
        g.endChat("c")
        XCTAssertFalse(g.coversChange(path: docs.path + "/x", chatID: "c", now: t0))
        // An expired grant stops covering.
        try g.grant(docs, level: .change, lifetime: .until(t0.addingTimeInterval(60)), chatID: "c", now: t0)
        XCTAssertTrue(g.coversChange(path: docs.path, chatID: "c", now: t0))
        XCTAssertFalse(g.coversChange(path: docs.path, chatID: "c", now: t0.addingTimeInterval(61)))
    }
}
