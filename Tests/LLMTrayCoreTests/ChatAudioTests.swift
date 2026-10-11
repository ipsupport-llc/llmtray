import XCTest
@testable import LLMTrayCore

final class ChatAudioTests: XCTestCase {
    func testWAVHeader() {
        let pcm = Data(repeating: 0, count: 32_000)   // 1 s at 16 kHz
        let wav = WAVFile.pcm16(pcm, sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44 + 32_000)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        func u32(_ at: Int) -> UInt32 { wav[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        XCTAssertEqual(u32(4), 36 + 32_000)
        XCTAssertEqual(u32(24), 16_000, "sample rate")
        XCTAssertEqual(u32(40), 32_000, "data size")
        // The app's own reader takes it as a WAV of that length.
        XCTAssertEqual(AudioCodec.format(of: wav), .wav)
    }

    func testAudioTokensByLength() {
        // 3 s: 75 soft tokens at 40 ms, plus begin/end.
        XCTAssertEqual(PromptTokenEstimator.Measure.audioTokens(wavBytes: 44 + 96_000), 77)
        var estimator = PromptTokenEstimator()
        XCTAssertFalse(estimator.calibrate(.init(bytes: 1000, audioTokens: 77), promptTokens: 400),
                       "a request with audio isn't a calibration: its tokens aren't in its bytes")
    }
}
