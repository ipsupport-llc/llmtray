import XCTest
@testable import LLMTrayCore

final class WAVInfoTests: XCTestCase {
    /// The runner's own layout: RIFF, fmt (16 bytes), data.
    private func wav(seconds: Double, rate: Int = 48000, channels: Int = 2) -> Data {
        let body = Int(seconds * Double(rate)) * channels * 2
        func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * $0)) & 0xff) } }
        var d: [UInt8] = Array("RIFF".utf8) + le(36 + body, 4) + Array("WAVEfmt ".utf8)
        d += le(16, 4) + le(1, 2) + le(channels, 2) + le(rate, 4) + le(rate * channels * 2, 4) + le(channels * 2, 2) + le(16, 2)
        d += Array("data".utf8) + le(body, 4)
        return Data(d) + Data(count: body)
    }

    func testDuration() {
        XCTAssertEqual(WAVInfo.duration(wav(seconds: 30))!, 30, accuracy: 0.001)
        XCTAssertEqual(WAVInfo.duration(wav(seconds: 1.5, rate: 22050, channels: 1))!, 1.5, accuracy: 0.001)
    }

    func testNotWAV() {
        XCTAssertNil(WAVInfo.duration(Data("hello".utf8)))
        XCTAssertNil(WAVInfo.duration(Data()))
    }
}
