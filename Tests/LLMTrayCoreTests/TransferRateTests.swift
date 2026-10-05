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
