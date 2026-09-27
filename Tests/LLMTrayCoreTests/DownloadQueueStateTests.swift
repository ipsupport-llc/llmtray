import XCTest
@testable import LLMTrayCore

final class DownloadQueueStateTests: XCTestCase {
    typealias Item = DownloadQueueState.Item

    private func kinds(_ s: DownloadQueueState) -> [DownloadQueueState.Kind] { s.items.map(\.kind) }

    func testOneAtATimeInOrder() {
        var s = DownloadQueueState()
        XCTAssertNil(s.startNext(), "nothing waits")
        s.enqueue(Item(kind: .imageModel, target: "gptqMixed"))
        s.enqueue(Item(kind: .musicModel, target: "turbo"))
        let first = s.startNext()
        XCTAssertEqual(first?.kind, .imageModel)
        XCTAssertNil(s.startNext(), "one runs at a time")
        XCTAssertEqual(s.current?.id, first?.id)
        s.finish(first!.id)
        XCTAssertEqual(s.item(first!.id)?.status, .done)
        XCTAssertEqual(s.startNext()?.kind, .musicModel)
    }

    func testChatModelGoesFirstAmongPending() {
        var s = DownloadQueueState()
        s.enqueue(Item(kind: .imageModel, target: "gptqMixed"))
        s.enqueue(Item(kind: .musicModel, target: "turbo"))
        _ = s.startNext()   // the image model runs
        s.enqueue(Item(kind: .chatModel, target: "org/model"))
        XCTAssertEqual(kinds(s), [.imageModel, .chatModel, .musicModel], "ahead of waiting items, not of the running one")
        s.enqueue(Item(kind: .chatModel, target: "org/other"))
        XCTAssertEqual(kinds(s), [.imageModel, .chatModel, .chatModel, .musicModel], "chat models keep their own order")
        XCTAssertEqual(s.items[2].target, "org/other")
    }

    func testNoDuplicatesUntilFinished() {
        var s = DownloadQueueState()
        XCTAssertTrue(s.enqueue(Item(kind: .chatModel, target: "a/b")))
        XCTAssertFalse(s.enqueue(Item(kind: .chatModel, target: "a/b")))
        XCTAssertTrue(s.enqueue(Item(kind: .imageModel, target: "a/b")), "another kind")
        let running = s.startNext()!
        XCTAssertFalse(s.enqueue(Item(kind: .chatModel, target: "a/b")), "running")
        s.finish(running.id, error: "boom")
        XCTAssertTrue(s.enqueue(Item(kind: .chatModel, target: "a/b")), "failed: may be added again")
    }

    func testEnqueueIsAlwaysPending() {
        var s = DownloadQueueState()
        s.enqueue(Item(kind: .musicModel, target: "turbo", status: .done))
        XCTAssertEqual(s.items.first?.status, .pending)
    }

    func testProgressOnlyWhileRunning() {
        var s = DownloadQueueState()
        s.enqueue(Item(kind: .chatModel, target: "a/b"))
        let id = s.items[0].id
        s.setProgress(id, 0.5)
        XCTAssertEqual(s.item(id)?.status, .pending)
        _ = s.startNext()
        s.setProgress(id, 0.5)
        XCTAssertEqual(s.item(id)?.status, .running(progress: 0.5))
        s.setProgress(id, 1.7)
        XCTAssertEqual(s.item(id)?.status, .running(progress: 1), "clamped")
        s.finish(id)
        s.setProgress(id, 0.2)
        XCTAssertEqual(s.item(id)?.status, .done)
    }

    func testCancel() {
        var s = DownloadQueueState()
        s.enqueue(Item(kind: .chatModel, target: "a/b"))
        s.enqueue(Item(kind: .imageModel, target: "klein4b"))
        let running = s.startNext()!
        let waiting = s.items[1].id
        XCTAssertFalse(s.cancel(waiting), "wasn't running")
        XCTAssertEqual(s.item(waiting)?.status, .cancelled)
        XCTAssertTrue(s.cancel(running.id), "was running: stop its download")
        s.finish(running.id, error: "cancelled by URLSession")
        XCTAssertEqual(s.item(running.id)?.status, .cancelled, "a late report doesn't overwrite it")
        XCTAssertFalse(s.cancel(running.id), "already finished")
        XCTAssertNil(s.startNext())
        XCTAssertFalse(s.hasUnfinished)
    }

    func testCancelAll() {
        var s = DownloadQueueState()
        s.enqueue(Item(kind: .chatModel, target: "a/b"))
        s.enqueue(Item(kind: .musicModel, target: "turbo"))
        let running = s.startNext()!
        XCTAssertEqual(s.cancelAll(), running.id)
        XCTAssertTrue(s.items.allSatisfy { $0.status == .cancelled })
        XCTAssertNil(s.cancelAll())
    }

    func testRetry() throws {
        var s = DownloadQueueState()
        s.enqueue(Item(kind: .imageModel, target: "gptqMixed"))
        s.enqueue(Item(kind: .chatModel, target: "a/b"))
        let chat = s.startNext()!
        XCTAssertEqual(chat.kind, .chatModel)
        s.finish(chat.id, error: "HTTP 500")
        let again = try XCTUnwrap(s.retry(chat.id))
        XCTAssertEqual(kinds(s), [.chatModel, .imageModel], "a chat model goes first again")
        XCTAssertNil(s.item(chat.id), "under a new id")
        XCTAssertEqual(s.item(again)?.status, .pending)
        XCTAssertNil(s.retry(again), "pending: nothing to retry")
        let image = s.items[1].id
        s.cancel(image)
        XCTAssertNotNil(s.retry(image))
        XCTAssertNil(s.retry(UUID()))
    }

    /// Cancelled while running, retried at once: the first attempt, still
    /// finishing, must not count for the retry.
    func testRetryWhileTheCancelledOneFinishes() throws {
        var s = DownloadQueueState()
        s.enqueue(Item(kind: .musicModel, target: "turbo"))
        let first = try XCTUnwrap(s.startNext())
        s.cancel(first.id)
        let retried = try XCTUnwrap(s.retry(first.id))
        XCTAssertFalse(s.isRunning(first.id))
        s.finish(first.id)   // the old download reports back
        XCTAssertEqual(s.item(retried)?.status, .pending, "untouched by the old attempt")
        XCTAssertEqual(s.startNext()?.id, retried)
        XCTAssertTrue(s.isRunning(retried))
    }

    func testRetryDoesNotDuplicate() throws {
        var s = DownloadQueueState()
        s.enqueue(Item(kind: .chatModel, target: "a/b"))
        let first = try XCTUnwrap(s.startNext())
        s.finish(first.id, error: "x")
        s.enqueue(Item(kind: .chatModel, target: "a/b"))   // added again meanwhile
        XCTAssertNil(s.retry(first.id))
        XCTAssertEqual(s.items.count, 2)
    }

    func testRemoveFinishedAndResume() throws {
        var s = DownloadQueueState()
        s.enqueue(Item(kind: .chatModel, target: "a/b"))
        s.enqueue(Item(kind: .imageModel, target: "klein4b"))
        s.enqueue(Item(kind: .musicModel, target: "turbo"))
        let first = s.startNext()!
        s.finish(first.id)
        _ = s.startNext()
        s.removeFinished()
        XCTAssertEqual(kinds(s), [.imageModel, .musicModel])
        // Saved and read back after a relaunch: the running one starts over.
        var restored = try JSONDecoder().decode(DownloadQueueState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(restored, s)
        restored.resetInterrupted()
        XCTAssertEqual(restored.items.map(\.status), [.pending, .pending])
        XCTAssertEqual(restored.startNext()?.kind, .imageModel)
    }

    func testFailedStaysUntilDismissed() throws {
        var s = DownloadQueueState()
        s.enqueue(Item(kind: .chatModel, target: "a/b"))
        s.enqueue(Item(kind: .imageModel, target: "klein4b"))
        s.enqueue(Item(kind: .musicModel, target: "turbo"))
        let failed = try XCTUnwrap(s.startNext())
        s.finish(failed.id, error: "HTTP 500")
        let done = try XCTUnwrap(s.startNext())
        s.finish(done.id)
        s.cancel(s.items[2].id)
        s.removeFinished()
        XCTAssertEqual(s.items.map(\.id), [failed.id], "failed stays, to be retried")
        s.dismiss(UUID())
        s.enqueue(Item(kind: .musicModel, target: "turbo"))
        let pending = s.items[1].id
        s.dismiss(pending)
        XCTAssertNotNil(s.item(pending), "only finished items are dismissed")
        s.dismiss(failed.id)
        XCTAssertNil(s.item(failed.id))
    }

    func testFreeSpace() {
        let gb: Int64 = 1024 * 1024 * 1024
        XCTAssertTrue(DownloadQueueState.hasRoom(for: 10 * gb, free: 20 * gb))
        XCTAssertFalse(DownloadQueueState.hasRoom(for: 10 * gb, free: 11 * gb), "the margin")
        XCTAssertTrue(DownloadQueueState.hasRoom(for: 10 * gb, free: 10 * gb + DownloadQueueState.freeSpaceMargin))
        XCTAssertTrue(DownloadQueueState.hasRoom(for: nil, free: 1), "unknown size doesn't block")
        XCTAssertTrue(DownloadQueueState.hasRoom(for: 10 * gb, free: nil), "unknown free space doesn't block")
    }
}
