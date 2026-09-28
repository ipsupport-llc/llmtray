import XCTest
@testable import LLMTrayCore

final class VoiceAudioTests: XCTestCase {
    func testFloatToInt16() {
        let data = PCM16.data(from: [0, 1, -1, 0.5, 2, -3, .nan] as [Float])
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Int16(littleEndian: $0) }
        XCTAssertEqual(values, [0, 32767, -32767, 16384, 32767, -32767, 0])
    }

    func testInt16ToFloat() {
        var data = Data()
        for v: Int16 in [0, 16384, -32768, 32767] { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(0xFF)   // an odd trailing byte is dropped
        let samples = PCM16.samples(from: data)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], 0.5)
        XCTAssertEqual(samples[2], -1)
        XCTAssertEqual(samples[3], 32767 / 32768, accuracy: 1e-6)
    }

    func testRoundTripIsClose() {
        let original: [Float] = (0..<100).map { sin(Float($0) / 5) * 0.8 }
        let back = PCM16.samples(from: PCM16.data(from: original))
        for (a, b) in zip(original, back) { XCTAssertEqual(a, b, accuracy: 1.0 / 16384) }
    }

    func testLevel() {
        XCTAssertEqual(PCM16.rms([] as [Float]), 0)
        XCTAssertEqual(PCM16.rms([0.5, -0.5] as [Float]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(PCM16.meterLevel(rms: 0), 0)
        XCTAssertEqual(PCM16.meterLevel(rms: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(PCM16.meterLevel(rms: 0.001), 0, accuracy: 1e-6)   // -60 dBFS
        XCTAssertEqual(PCM16.meterLevel(rms: 0.0316), 0.5, accuracy: 0.01)   // -30 dBFS
        XCTAssertEqual(PCM16.meterLevel(rms: 1e-9), 0)
    }

    func testJitterBufferHoldsUntilPrebuffer() {
        var jitter = JitterBuffer(sampleRate: 22_050, milliseconds: 160)
        XCTAssertEqual(jitter.prebufferSamples, 3528)
        let step = [Float](repeating: 0.1, count: 1764)   // 80 ms
        XCTAssertEqual(jitter.push(step).count, 0)
        XCTAssertFalse(jitter.isPlaying)
        XCTAssertEqual(jitter.heldSamples, 1764)
        let out = jitter.push(step)
        XCTAssertEqual(out.count, 2)   // both, in order
        XCTAssertTrue(jitter.isPlaying)
        XCTAssertEqual(jitter.scheduledSamples, 3528)
        // Playing: each chunk goes at once.
        XCTAssertEqual(jitter.push(step).count, 1)
        XCTAssertEqual(jitter.scheduledSamples, 5292)
        XCTAssertEqual(jitter.push([]).count, 0)
    }

    func testJitterBufferRebuffersAfterUnderrun() {
        var jitter = JitterBuffer(prebufferSamples: 100)
        _ = jitter.push([Float](repeating: 0, count: 100))
        jitter.played(60)
        XCTAssertTrue(jitter.isPlaying)
        jitter.played(40)
        XCTAssertFalse(jitter.isPlaying)
        XCTAssertEqual(jitter.underruns, 1)
        XCTAssertEqual(jitter.push([Float](repeating: 0, count: 50)).count, 0)   // held again
        XCTAssertEqual(jitter.push([Float](repeating: 0, count: 50)).count, 2)
        jitter.reset()
        XCTAssertFalse(jitter.isPlaying)
        XCTAssertEqual(jitter.scheduledSamples, 0)
        XCTAssertEqual(jitter.heldSamples, 0)
        jitter.played(10)   // a completion after the reset (player.stop()) is harmless
        XCTAssertEqual(jitter.scheduledSamples, 0)
        XCTAssertEqual(jitter.underruns, 1)
    }

    func testJitterBufferFlushPlaysAShortReply() {
        var jitter = JitterBuffer(prebufferSamples: 1000)
        XCTAssertEqual(jitter.flush().count, 0)
        XCTAssertFalse(jitter.isPlaying)
        _ = jitter.push([Float](repeating: 0, count: 300))
        _ = jitter.push([Float](repeating: 0, count: 200))
        XCTAssertEqual(jitter.flush().map(\.count), [300, 200])
        XCTAssertTrue(jitter.isPlaying)
        XCTAssertEqual(jitter.scheduledSamples, 500)
        XCTAssertEqual(jitter.heldSamples, 0)
        jitter.played(500)
        XCTAssertFalse(jitter.isPlaying)
    }

    func testSpeechActivityHold() {
        var activity = SpeechActivity(threshold: 0.01, hold: 0.4)
        XCTAssertFalse(activity.isSpeaking(at: 0))
        activity.observe(rms: 0.001, at: 1)
        XCTAssertFalse(activity.isSpeaking(at: 1))
        activity.observe(rms: 0.2, at: 2)
        XCTAssertTrue(activity.isSpeaking(at: 2.3))
        activity.observe(rms: 0.0, at: 2.3)   // a quiet chunk doesn't end it at once
        XCTAssertTrue(activity.isSpeaking(at: 2.4))
        XCTAssertFalse(activity.isSpeaking(at: 2.41))
        activity.observe(rms: 0.5, at: 3)
        activity.reset()
        XCTAssertFalse(activity.isSpeaking(at: 3))
    }
}
