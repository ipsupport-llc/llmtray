import XCTest
@testable import LLMTrayCore

final class AudioCodecTests: XCTestCase {
    /// The runner's layout (16-bit stereo 48 kHz), a 440 Hz tone.
    private func wav(seconds: Double, rate: Int = 48000, channels: Int = 2) -> Data {
        let frames = Int(seconds * Double(rate))
        func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * $0)) & 0xff) } }
        let body = frames * channels * 2
        var d: [UInt8] = Array("RIFF".utf8) + le(36 + body, 4) + Array("WAVEfmt ".utf8)
        d += le(16, 4) + le(1, 2) + le(channels, 2) + le(rate, 4) + le(rate * channels * 2, 4) + le(channels * 2, 2) + le(16, 2)
        d += Array("data".utf8) + le(body, 4)
        for i in 0..<frames {
            let s = Int(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 12000) & 0xffff
            for _ in 0..<channels { d += le(s, 2) }
        }
        return Data(d)
    }

    func testEncodesToSmallerM4A() throws {
        let input = wav(seconds: 10)
        let output = try AudioCodec.m4a(from: input)
        XCTAssertEqual(AudioCodec.format(of: output), .m4a)
        XCTAssertLessThan(output.count, input.count / 4)
        XCTAssertEqual(try XCTUnwrap(AudioCodec.duration(output)), 10, accuracy: 0.1)
    }

    func testFormatSniffing() {
        XCTAssertEqual(AudioCodec.format(of: wav(seconds: 0.1)), .wav)
        XCTAssertEqual(AudioCodec.format(of: Data("hello world!".utf8)), .unknown)
        XCTAssertEqual(AudioCodec.Format.wav.fileExtension, "wav")
        XCTAssertEqual(AudioCodec.Format.m4a.fileExtension, "m4a")
    }

    func testDurationOfWAV() {
        XCTAssertEqual(AudioCodec.duration(wav(seconds: 2))!, 2, accuracy: 0.001)
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try AudioCodec.m4a(from: Data("not audio at all".utf8)))
    }
}
