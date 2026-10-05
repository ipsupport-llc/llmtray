import XCTest
@testable import LLMTrayCore

final class TransferRateTests: XCTestCase {
    func testUnevenChunksReadAsTheirAverage() {
        var rate = TransferRate(window: 10, interval: 1)
        var bytes: Int64 = 0
        var reports: [Double] = []
        // 10 MB/s on average, in bursts: 20 MB every other half-second.
        for step in 0...40 {
            if step % 2 == 0 { bytes += 10_000_000 }
            if let r = rate.add(bytes: bytes, total: 1_000_000_000, at: Double(step) * 0.5) { reports.append(r.speed) }
        }
        // Once the window fills, the speed stays near 10 MB/s; a half-second
        // rate would swing between 0 and 20.
        let settled = reports.suffix(5)
        XCTAssertFalse(settled.isEmpty)
        for speed in settled { XCTAssertEqual(speed, 10_000_000, accuracy: 1_100_000) }
    }

    func testReportsAtMostOncePerInterval() {
        var rate = TransferRate(window: 10, interval: 1)
        var count = 0
        for step in 0...100 where rate.add(bytes: Int64(step) * 1_000, total: 1_000_000, at: Double(step) * 0.1) != nil {
            count += 1
        }
        XCTAssertLessThanOrEqual(count, 10)
        XCTAssertGreaterThanOrEqual(count, 8)
    }

    func testAFileThatStartsOverStartsTheRateOver() {
        var rate = TransferRate(window: 10, interval: 1)
        _ = rate.add(bytes: 0, total: 1_000, at: 0)
        _ = rate.add(bytes: 500, total: 1_000, at: 2)
        // Restarted from zero: no rate from the old high-water samples...
        XCTAssertNil(rate.add(bytes: 0, total: 1_000, at: 3))
        // ...then the new download's own.
        XCTAssertEqual(rate.add(bytes: 100, total: 1_000, at: 4.5)?.speed ?? 0, 100 / 1.5, accuracy: 0.01)
    }

    func testARestartBetweenSamplesIsSeen() {
        var rate = TransferRate(window: 10, interval: 1)
        _ = rate.add(bytes: 0, total: 1_000_000, at: 0)
        _ = rate.add(bytes: 100_000, total: 1_000_000, at: 0.1)   // not sampled
        _ = rate.add(bytes: 95_000, total: 1_000_000, at: 0.2)    // one file restarted: still above the last sample
        XCTAssertNil(rate.add(bytes: 96_000, total: 1_000_000, at: 1.1), "the rate starts over at the restart")
    }

    func testManyCallbacksKeepFewSamples() {
        var rate = TransferRate(window: 10, interval: 1)
        var last: Double = 0
        for step in 0..<20_000 {
            if let r = rate.add(bytes: Int64(step) * 500, total: 100_000_000, at: Double(step) * 0.001) { last = r.speed }
        }
        XCTAssertEqual(last, 500_000, accuracy: 25_000)
    }

    func testTimeLeftAndReset() {
        var rate = TransferRate(window: 10, interval: 1)
        XCTAssertNil(rate.add(bytes: 0, total: 100, at: 0), "no rate from one sample")
        let r = rate.add(bytes: 10, total: 100, at: 2)
        XCTAssertEqual(r?.speed ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(r?.eta ?? 0, 18, accuracy: 0.001)
        rate.reset()
        XCTAssertNil(rate.add(bytes: 10, total: 100, at: 3), "a resume starts over")
        XCTAssertNil(rate.add(bytes: 10, total: 100, at: 5)?.eta, "no time left at zero speed")
    }
}
