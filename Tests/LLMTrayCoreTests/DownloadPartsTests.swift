import XCTest
@testable import LLMTrayCore

final class DownloadPartsTests: XCTestCase {
    func testSmallFilesComeWhole() {
        XCTAssertNil(DownloadParts.ranges(size: 0))
        XCTAssertNil(DownloadParts.ranges(size: 100 * 1_048_576))
    }

    func testRangesCoverTheFileExactly() {
        for size: Int64 in [256 * 1_048_576, 3_447_595_615, 5_000_000_001, 300 * 1_048_576 + 7] {
            guard let ranges = DownloadParts.ranges(size: size) else { return XCTFail("\(size)") }
            XCTAssertLessThanOrEqual(ranges.count, DownloadParts.maxParts)
            XCTAssertEqual(ranges.first?.lowerBound, 0)
            XCTAssertEqual(ranges.last?.upperBound, size - 1)
            for (a, b) in zip(ranges, ranges.dropFirst()) { XCTAssertEqual(a.upperBound + 1, b.lowerBound) }
            XCTAssertEqual(ranges.reduce(0) { $0 + Int64($1.count) }, size)
        }
    }

    func testPartCountFollowsTheMinimumPartSize() {
        // 256 MB: 4 parts of 64 MB; 3.4 GB: the 8-part cap.
        XCTAssertEqual(DownloadParts.ranges(size: 256 * 1_048_576)?.count, 4)
        XCTAssertEqual(DownloadParts.ranges(size: 3_447_595_615)?.count, 8)
    }

    func testResponseMustBeThePart() {
        let r: ClosedRange<Int64> = 100...199
        XCTAssertEqual(DownloadParts.header(r), "bytes=100-199")
        XCTAssertTrue(DownloadParts.isPart(status: 206, contentRange: "bytes 100-199/1000", of: r))
        XCTAssertFalse(DownloadParts.isPart(status: 200, contentRange: nil, of: r))
        XCTAssertFalse(DownloadParts.isPart(status: 206, contentRange: "bytes 0-999/1000", of: r))
    }
}
