import XCTest
@testable import LLMTrayCore

@MainActor
final class GenerationQueueTests: XCTestCase {
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
}
