import XCTest
@testable import LLMTrayCore

final class VoiceFramesTests: XCTestCase {
    func testEncoding() {
        let frame = VoiceFrame(.text, text: "hi")
        XCTAssertEqual([UInt8](frame.encoded), [0x54, 0, 0, 0, 2, 0x68, 0x69])
        XCTAssertEqual([UInt8](VoiceFrame(.quit).encoded), [0x51, 0, 0, 0, 0])
        let big = VoiceFrame(.audio, payload: Data(repeating: 7, count: 0x01_02_03))
        XCTAssertEqual([UInt8](big.encoded.prefix(5)), [0x41, 0x00, 0x01, 0x02, 0x03])
    }

    func testRoundTripWholeChunk() throws {
        let frames = [VoiceFrame(.ready, text: "{}"), VoiceFrame(.speech, payload: Data([1, 2, 3, 4])), VoiceFrame(.quit)]
        var decoder = VoiceFrameDecoder()
        XCTAssertEqual(try decoder.append(frames.map(\.encoded).reduce(Data(), +)), frames)
        XCTAssertEqual(decoder.pendingBytes, 0)
    }

    func testPartialReadsByteByByte() throws {
        let frames = [VoiceFrame(.text, text: "Hello, world"), VoiceFrame(.log, text: "x"), VoiceFrame(.error, text: "")]
        let stream = frames.map(\.encoded).reduce(Data(), +)
        var decoder = VoiceFrameDecoder()
        var got: [VoiceFrame] = []
        for byte in stream {
            got += try decoder.append(Data([byte]))
        }
        XCTAssertEqual(got, frames)
        XCTAssertEqual(decoder.pendingBytes, 0)
    }

    func testSplitsAtEveryBoundary() throws {
        let frames = [VoiceFrame(.speech, payload: Data((0..<300).map { UInt8($0 % 256) })), VoiceFrame(.text, text: "ok")]
        let stream = frames.map(\.encoded).reduce(Data(), +)
        for cut in 0...stream.count {
            var decoder = VoiceFrameDecoder()
            let got = try decoder.append(stream.prefix(cut)) + decoder.append(stream.dropFirst(cut))
            XCTAssertEqual(got, frames, "cut at \(cut)")
        }
    }

    func testIncompleteFrameIsHeld() throws {
        var decoder = VoiceFrameDecoder()
        let encoded = VoiceFrame(.speech, payload: Data(repeating: 1, count: 10)).encoded
        XCTAssertEqual(try decoder.append(encoded.prefix(9)), [])
        XCTAssertEqual(decoder.pendingBytes, 9)
        XCTAssertEqual(try decoder.append(encoded.suffix(from: 9)).count, 1)
    }

    func testUnknownTypeIsPassedOn() throws {
        var decoder = VoiceFrameDecoder()
        let frames = try decoder.append(VoiceFrame(type: 0x58, payload: Data([9])).encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertNil(frames[0].kind)
        XCTAssertEqual(frames[0].payload, Data([9]))
    }

    func testBadLengthFailsForGood() {
        var decoder = VoiceFrameDecoder(maxPayload: 1024)
        var bad = Data([0x53])
        bad.append(contentsOf: [0, 0, 0x04, 0x01])   // 1025
        XCTAssertThrowsError(try decoder.append(bad)) { error in
            XCTAssertEqual(error as? VoiceFrameDecoder.Failure, .badLength(type: 0x53, length: 1025))
        }
        // Out of step: nothing after it is trusted.
        XCTAssertThrowsError(try decoder.append(VoiceFrame(.text, text: "ok").encoded))
        // The limit itself is fine.
        var ok = VoiceFrameDecoder(maxPayload: 4)
        XCTAssertEqual(try ok.append(VoiceFrame(.speech, payload: Data([1, 2, 3, 4])).encoded).count, 1)
    }

    func testDefaultLimitRefusesGarbage() {
        // Text where a header should be ("hello" as type + length).
        var decoder = VoiceFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data("hello world".utf8)))
    }

    func testReadyPayload() {
        let json = #"{"sample_rate": 22050, "input_sample_rate": 16000, "frame_samples": 1280, "model": "m"}"#
        XCTAssertEqual(VoiceRunnerReady(payload: Data(json.utf8)),
                       VoiceRunnerReady(sampleRate: 22_050, inputSampleRate: 16_000, frameSamples: 1280, model: "m"))
        XCTAssertNil(VoiceRunnerReady(payload: Data(#"{"sample_rate": 0, "input_sample_rate": 16000}"#.utf8)))
        XCTAssertNil(VoiceRunnerReady(payload: Data("nope".utf8)))
        XCTAssertEqual(VoiceRunnerReady(payload: Data(#"{"sample_rate": 24000, "input_sample_rate": 16000}"#.utf8))?.frameSamples, nil)
        XCTAssertEqual(VoiceRunnerReady(payload: Data(#"{"sample_rate": 22050, "input_sample_rate": 16000, "rtf": 2.04}"#.utf8))?.rtf, 2.04)
    }

    func testReplyDonePayload() {
        XCTAssertEqual(VoiceReplyDone(payload: Data(#"{"reason": "done", "turn": 3, "seconds": 2.4}"#.utf8)),
                       VoiceReplyDone(reason: .done, turn: 3, seconds: 2.4))
        XCTAssertEqual(VoiceReplyDone(payload: Data(#"{"reason": "no_reply"}"#.utf8))?.reason, .noReply)
        XCTAssertEqual(VoiceReplyDone(payload: Data(#"{"reason": "interrupted", "turn": 1}"#.utf8))?.reason, .interrupted)
        XCTAssertEqual(VoiceReplyDone(payload: Data(#"{"reason": "reset", "turn": 2}"#.utf8))?.reason, .reset)
        XCTAssertNil(VoiceReplyDone(payload: Data(#"{"reason": "bored"}"#.utf8)))
        XCTAssertEqual([VoiceFrame.Kind.mode, .cancelReply, .userText, .note].map(\.rawValue), [UInt8]("MCUN".utf8))
        XCTAssertEqual(VoiceLabMode.runnerMode(walkieTalkie: true), "walkie")
        XCTAssertEqual(VoiceLabMode.runnerMode(walkieTalkie: false), "duplex")
        XCTAssertEqual(VoiceFrame(.endOfTurn, text: "7").encoded.first, UInt8(ascii: "D"))
        XCTAssertEqual(VoiceFrame(.replyDone).kind, .replyDone)
    }

    func testModeByMeasuredSpeed() {
        XCTAssertFalse(VoiceLabMode.auto.usesWalkieTalkie(rtf: 0.93))   // M5 Pro, published
        XCTAssertTrue(VoiceLabMode.auto.usesWalkieTalkie(rtf: 2.0))     // base M5, measured
        XCTAssertFalse(VoiceLabMode.auto.usesWalkieTalkie(rtf: nil))
        XCTAssertFalse(VoiceLabMode.auto.usesWalkieTalkie(rtf: 1.0))
        XCTAssertFalse(VoiceLabMode.duplex.usesWalkieTalkie(rtf: 3))
        XCTAssertTrue(VoiceLabMode.walkieTalkie.usesWalkieTalkie(rtf: 0.5))
        XCTAssertEqual(VoiceLabMode.speedText(rtf: 2.0), "0.5")
        XCTAssertEqual(VoiceLabMode.speedText(rtf: 1.6), "0.6")
        XCTAssertEqual(VoiceLabMode.speedText(rtf: 0), "0.0")
    }
}
