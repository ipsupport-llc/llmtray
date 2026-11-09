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
}
