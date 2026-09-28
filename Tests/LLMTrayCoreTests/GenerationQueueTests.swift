import XCTest
@testable import LLMTrayCore

// XCTestCase is nonisolated: the tests (not the class) are main-actor
// isolated, which Swift 5.10 and 6 both accept.
final class GenerationQueueTests: XCTestCase {}

@MainActor
extension GenerationQueueTests {
    func testFirstComerRunsAtOnce() async throws {
        let queue = GenerationQueue(pollInterval: 0.01)
        let ticket = try await queue.acquire()
        XCTAssertTrue(queue.isBusy)
        ticket.release()
        XCTAssertFalse(queue.isBusy)
    }

    func testWaitersRunInOrder() async throws {
        let queue = GenerationQueue(pollInterval: 0.01)
        let first = try await queue.acquire()
        var order: [Int] = []
        var positions: [Int?] = []
        let second = Task { @MainActor in
            let t = try await queue.acquire(onPosition: { positions.append($0) })
            order.append(2)
            t.release()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        let third = Task { @MainActor in
            let t = try await queue.acquire()
            order.append(3)
            t.release()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(queue.waitingCount, 2)
        XCTAssertEqual(positions.first ?? nil, 1)   // the running one ahead of it
        first.release()
        _ = try await second.value
        _ = try await third.value
        XCTAssertEqual(order, [2, 3])
        XCTAssertEqual(positions.last ?? 0, nil)    // granted
        XCTAssertFalse(queue.isBusy)
    }

    func testCancelledWaiterLeaves() async throws {
        let queue = GenerationQueue(pollInterval: 0.01)
        let first = try await queue.acquire()
        var stop = false
        let waiter = Task { @MainActor in
            try await queue.acquire(isCancelled: { stop })
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        stop = true
        do {
            _ = try await waiter.value
            XCTFail("should have been cancelled")
        } catch is GenerationQueue.Cancelled {}
        XCTAssertEqual(queue.waitingCount, 0)
        first.release()
        let next = try await queue.acquire()   // nobody left in front
        next.release()
    }

    func testReleaseTwiceIsHarmless() async throws {
        let queue = GenerationQueue(pollInterval: 0.01)
        let a = try await queue.acquire()
        a.release()
        let b = try await queue.acquire()
        a.release()   // must not free b's turn
        XCTAssertTrue(queue.isBusy)
        b.release()
    }

    // MARK: - the background lane

    func testBackgroundSlicesRunWhenIdleAndHoldNothingBetween() async throws {
        let queue = GenerationQueue(pollInterval: 0.01)
        let slice = try await queue.acquireBackground()
        XCTAssertTrue(queue.isBackgroundRunning)
        XCTAssertFalse(queue.isBusy, "a slice isn't a generation")
        XCTAssertFalse(slice.shouldYield)
        slice.release()
        XCTAssertFalse(queue.isBackgroundRunning)
        let next = try await queue.acquireBackground()
        next.release()
        next.release()   // twice is harmless
        let ticket = try await queue.acquire()
        ticket.release()
    }

    func testAGenerationGetsTheQueueAtTheNextSliceBoundary() async throws {
        let queue = GenerationQueue(pollInterval: 0.01)
        var events: [String] = []
        queue.onInteractiveGrant = { events.append("runner told to exit") }
        let slice = try await queue.acquireBackground()
        var positions: [Int?] = []
        let generation = Task { @MainActor in
            let t = try await queue.acquire(onPosition: { positions.append($0) })
            events.append("generation")
            return t
        }
        let indexing = Task { @MainActor in
            let s = try await queue.acquireBackground()
            events.append("next slice")
            s.release()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(slice.shouldYield, "the running slice is told a generation waits")
        XCTAssertEqual(positions.first ?? nil, 1, "the slice counts as one ahead")
        XCTAssertTrue(events.isEmpty, "not before the boundary")
        slice.release()
        let ticket = try await generation.value
        XCTAssertEqual(events, ["runner told to exit", "generation"])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(queue.backgroundWaitingCount, 1, "indexing waits while the generation runs")
        ticket.release()
        _ = try await indexing.value
        XCTAssertEqual(events, ["runner told to exit", "generation", "next slice"])
    }

    func testWaitingGenerationsAllGoBeforeIndexingResumes() async throws {
        let queue = GenerationQueue(pollInterval: 0.01)
        let first = try await queue.acquire()
        var order: [String] = []
        let bg = Task { @MainActor in
            let s = try await queue.acquireBackground()
            order.append("slice")
            s.release()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        let second = Task { @MainActor in
            let t = try await queue.acquire()
            order.append("second")
            t.release()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        first.release()
        _ = try await second.value
        _ = try await bg.value
        XCTAssertEqual(order, ["second", "slice"], "a generation that asked after the slice still goes first")
    }

    /// Every grant asks: the runner may have been started by a search's
    /// query, not only by an index slice.
    func testEveryGenerationGrantAsksTheRunnerToStop() async throws {
        let queue = GenerationQueue(pollInterval: 0.01)
        var told = 0
        queue.onInteractiveGrant = { told += 1 }
        let t = try await queue.acquire()
        t.release()
        XCTAssertEqual(told, 1, "no slice before it: the hook still runs")
        let s = try await queue.acquireBackground()
        s.release()
        let t2 = try await queue.acquire()
        t2.release()
        XCTAssertEqual(told, 2)
    }

    /// The demand hook pauses the runner from the first waiting generation
    /// until none runs or waits.
    func testInteractiveDemandIsReportedOnEachChange() async throws {
        let queue = GenerationQueue(pollInterval: 0.01)
        var changes: [Bool] = []
        queue.onInteractiveDemand = { changes.append($0) }
        let first = try await queue.acquire()
        XCTAssertEqual(changes, [false, true], "the current state first, then the change")
        let second = Task { @MainActor in try await queue.acquire() }
        try await Task.sleep(nanoseconds: 30_000_000)
        first.release()
        let t2 = try await second.value
        XCTAssertEqual(changes, [false, true], "still a generation: no flip between them")
        t2.release()
        XCTAssertEqual(changes, [false, true, false])
        var stop = false
        let blocker = try await queue.acquire()
        let cancelled = Task { @MainActor in try await queue.acquire(isCancelled: { stop }) }
        try await Task.sleep(nanoseconds: 30_000_000)
        stop = true
        _ = try? await cancelled.value
        XCTAssertEqual(changes, [false, true, false, true], "a waiter leaving doesn't end the demand while one runs")
        blocker.release()
        XCTAssertEqual(changes, [false, true, false, true, false])
    }

    /// An embedder wired up while a generation runs starts out paused: the
    /// hook is told the current demand when it's set, not at the next change.
    func testADemandHookSetMidGenerationIsToldAtOnce() async throws {
        let queue = GenerationQueue(pollInterval: 0.01)
        let generation = try await queue.acquire()
        let runner = EmbedRunner(configuration: EmbedRunner.Configuration(executable: "/usr/bin/false", arguments: []))
        XCTAssertFalse(runner.isPaused)
        queue.onInteractiveDemand = { runner.setPaused($0) }
        XCTAssertTrue(runner.isPaused, "paused before anything could start it")
        do {
            _ = try await runner.embed(["запрос"], kind: .query)
            XCTFail("paused")
        } catch EmbedRunner.Failure.paused {}
        XCTAssertNil(runner.pid, "nothing started")
        generation.release()
        XCTAssertFalse(runner.isPaused)
    }

    func testCancelledBackgroundWaiterLeaves() async throws {
        let queue = GenerationQueue(pollInterval: 0.01)
        let ticket = try await queue.acquire()
        var stop = false
        let waiter = Task { @MainActor in try await queue.acquireBackground(isCancelled: { stop }) }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(queue.backgroundWaitingCount, 1)
        stop = true
        do {
            _ = try await waiter.value
            XCTFail("cancelled")
        } catch is GenerationQueue.Cancelled {}
        XCTAssertEqual(queue.backgroundWaitingCount, 0)
        ticket.release()
    }
}
