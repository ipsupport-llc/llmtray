import XCTest
@testable import LLMTrayCore

final class DuplexProcessTests: XCTestCase {
    fileprivate final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var decoder = VoiceFrameDecoder()
        private(set) var frames: [VoiceFrame] = []
        func append(_ d: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(d)
            frames += (try? decoder.append(d)) ?? []
        }
        var bytes: Data { lock.lock(); defer { lock.unlock() }; return data }
        var decoded: [VoiceFrame] { lock.lock(); defer { lock.unlock() }; return frames }
    }

    fileprivate final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: DuplexProcess.Exit?
        var value: DuplexProcess.Exit? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private func wait(_ exited: XCTestExpectation) { wait(for: [exited], timeout: 10) }

    /// /bin/cat echoes the frames back: many writes, reassembled whole.
    func testFramesThroughCat() throws {
        let child = DuplexProcess(executable: "/bin/cat", arguments: [])
        let out = Collected()
        let exited = expectation(description: "exit")
        let exit = ExitBox()
        try child.start(onStdout: { out.append($0) }, onExit: { exit.value = $0; exited.fulfill() })
        let frames = (0..<200).map { VoiceFrame(.audio, payload: Data(repeating: UInt8($0 % 256), count: 2560)) } + [VoiceFrame(.quit)]
        for frame in frames { XCTAssertTrue(child.write(frame.encoded)) }
        child.closeStdin()
        wait(exited)
        XCTAssertEqual(exit.value, DuplexProcess.Exit(status: 0, signaled: false))
        XCTAssertEqual(out.decoded, frames)
        XCTAssertFalse(child.write(Data([1])), "stdin is closed")
    }

    func testWritesPastTheLimitAreDropped() throws {
        // `sleep` never reads its stdin: the pipe fills, then the queue.
        let child = DuplexProcess(executable: "/bin/sleep", arguments: ["30"], maxPendingBytes: 256 << 10)
        let exited = expectation(description: "exit")
        let exit = ExitBox()
        try child.start(onStdout: { _ in }, onExit: { exit.value = $0; exited.fulfill() })
        let chunk = Data(repeating: 0, count: 32 << 10)
        var accepted = 0
        for _ in 0..<64 where child.write(chunk) { accepted += 1 }
        XCTAssertLessThan(accepted, 64)
        XCTAssertGreaterThan(accepted, 0)
        child.terminate()
        wait(exited)
        XCTAssertEqual(exit.value?.signaled, true)
    }

    func testWriteAfterTheChildIsGoneDoesNotCrash() throws {
        let child = DuplexProcess(executable: "/usr/bin/true", arguments: [])
        let exited = expectation(description: "exit")
        try child.start(onStdout: { _ in }, onExit: { _ in exited.fulfill() })
        wait(exited)
        // No SIGPIPE (it would end the test run): the write just fails.
        for _ in 0..<10 { child.write(Data(repeating: 1, count: 70_000)) }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(child.write(Data(repeating: 1, count: 1)))
    }
}

/// Spoken answers' runner (runtime/llmtray_tts_runner.py, adr/0016) in its
/// --selftest mode: a tone per sentence, no model, any Python 3.
final class SpeechRunnerTests: XCTestCase {
    private var runner: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runtime/llmtray_tts_runner.py").path
    }

    private func python() throws -> String {
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("no python3")
        }
        return python
    }

    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func testSentencesComeBackInOrderWithTheirIDs() throws {
        let child = DuplexProcess(executable: try python(), arguments: [runner, "--selftest"],
                                  environment: ["PYTHONDONTWRITEBYTECODE": "1"])
        let out = DuplexProcessTests.Collected()
        let exited = expectation(description: "exit")
        let exit = DuplexProcessTests.ExitBox()
        try child.start(onStdout: { out.append($0) }, onExit: { exit.value = $0; exited.fulfill() })
        child.write(VoiceFrame(.voice, payload: json(["clip": NSNull()])).encoded)
        child.write(VoiceFrame(.speak, payload: json(["id": 1, "text": "Hello.", "lang": "en"])).encoded)
        child.write(VoiceFrame(.speak, payload: json(["id": 2, "text": "  ", "lang": "en"])).encoded)
        child.write(VoiceFrame(.speak, payload: json(["id": 3, "text": "Привет.", "lang": "ru"])).encoded)
        // Q and EOF drop what's queued: wait for the last sentence first.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !out.decoded.contains(where: { $0.kind == .replyDone && $0.text.contains("\"id\": 3") }) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        child.closeStdin()
        wait(for: [exited], timeout: 20)
        XCTAssertEqual(exit.value?.status, 0)
        let frames = out.decoded
        XCTAssertEqual(frames.first?.kind, .ready)
        let ready = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[0].payload) as? [String: Any])
        XCTAssertEqual(ready["sample_rate"] as? Int, 24000)
        // id 2 is empty: done with no audio.
        let order = frames.dropFirst().filter { $0.kind != .speech }.map { f -> String in
            let id = (try? JSONSerialization.jsonObject(with: f.payload) as? [String: Any])?["id"] as? Int ?? -1
            return "\(Character(UnicodeScalar(f.type)))\(id)"
        }
        XCTAssertEqual(order, ["B1", "Z1", "Z2", "B3", "Z3"])
        let speech = frames.filter { $0.kind == .speech }
        XCTAssertFalse(speech.isEmpty)
        XCTAssertTrue(speech.allSatisfy { $0.payload.count % 2 == 0 && $0.payload.count <= 48_000 })
    }

    func testQuitDropsWhatIsQueued() throws {
        let child = DuplexProcess(executable: try python(), arguments: [runner, "--selftest"])
        let out = DuplexProcessTests.Collected()
        let exited = expectation(description: "exit")
        try child.start(onStdout: { out.append($0) }, onExit: { _ in exited.fulfill() })
        var batch = Data()
        for id in 1...50 {
            batch += VoiceFrame(.speak, payload: json(["id": id, "text": String(repeating: "long sentence ", count: 20), "lang": "en"])).encoded
        }
        child.write(batch + VoiceFrame(.quit).encoded)
        wait(for: [exited], timeout: 20)
        // At most the one being made when Q came; never all fifty.
        XCTAssertLessThan(out.decoded.filter { $0.kind == .replyDone }.count, 50)
    }

    func testExitsAtEOF() throws {
        let child = DuplexProcess(executable: try python(), arguments: [runner, "--selftest"])
        let out = DuplexProcessTests.Collected()
        let exited = expectation(description: "exit")
        let exit = DuplexProcessTests.ExitBox()
        try child.start(onStdout: { out.append($0) }, onExit: { exit.value = $0; exited.fulfill() })
        child.closeStdin()
        wait(for: [exited], timeout: 20)
        XCTAssertEqual(exit.value?.status, 0)
        XCTAssertEqual(out.decoded.map(\.kind), [.ready])
    }
}

/// The voice conversation's listen runner (runtime/llmtray_listen_runner.py,
/// adr/0031) in --selftest mode: energy VAD, a fake recognizer, any Python 3.
final class ListenRunnerTests: XCTestCase {
    private var runner: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runtime/llmtray_listen_runner.py").path
    }

    private func python() throws -> String {
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("no python3") }
        return python
    }

    func testATurnStartsShowsPartialsAndEnds() throws {
        let child = DuplexProcess(executable: try python(), arguments: [runner, "--selftest"], environment: ["PYTHONDONTWRITEBYTECODE": "1"])
        let out = DuplexProcessTests.Collected()
        let exited = expectation(description: "exit")
        try child.start(onStdout: { out.append($0) }, onExit: { _ in exited.fulfill() })
        let tone = PCM16.data(from: (0..<16000).map { sin(Float($0) * 2 * .pi * 300 / 16000) * 0.3 })
        let silence = PCM16.data(from: [Float](repeating: 0, count: 32000))
        child.write(VoiceFrame(.audio, payload: PCM16.data(from: [Float](repeating: 0, count: 4000))).encoded)
        child.write(VoiceFrame(.audio, payload: tone).encoded)
        child.write(VoiceFrame(.audio, payload: silence).encoded)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !out.decoded.contains(where: { $0.type == UInt8(ascii: "Z") }) { Thread.sleep(forTimeInterval: 0.05) }
        child.write(VoiceFrame(.quit).encoded)
        child.closeStdin()
        wait(for: [exited], timeout: 15)
        let kinds = out.decoded.map { Character(UnicodeScalar($0.type)) }
        XCTAssertEqual(kinds.first, "R")
        XCTAssertTrue(kinds.contains("V"))
        XCTAssertTrue(kinds.contains("U"))
        let z = try XCTUnwrap(out.decoded.first { $0.type == UInt8(ascii: "Z") })
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: z.payload) as? [String: Any])
        XCTAssertEqual(info["reason"] as? String, "turn")
        XCTAssertTrue((info["text"] as? String ?? "").hasPrefix("speech"))
    }

    /// Over the model's voice a short burst (echo getting through) doesn't
    /// start a turn; speech as long as a real cut-in does.
    func testWhileTheModelSpeaksAShortBurstIsNoTurn() throws {
        let child = DuplexProcess(executable: try python(), arguments: [runner, "--selftest"])
        let out = DuplexProcessTests.Collected()
        let exited = expectation(description: "exit")
        try child.start(onStdout: { out.append($0) }, onExit: { _ in exited.fulfill() })
        child.write(VoiceFrame(.mode, payload: try JSONSerialization.data(withJSONObject: ["speaking": true])).encoded)
        func tone(_ n: Int) -> Data { PCM16.data(from: (0..<n).map { sin(Float($0) * 2 * .pi * 300 / 16000) * 0.3 }) }
        let gap = PCM16.data(from: [Float](repeating: 0, count: 4000))
        // 160 ms: past the plain start (96 ms), short of the one over the model.
        child.write(VoiceFrame(.audio, payload: tone(2560)).encoded)
        child.write(VoiceFrame(.audio, payload: gap).encoded)
        child.write(VoiceFrame(.audio, payload: tone(8000)).encoded)
        child.write(VoiceFrame(.audio, payload: PCM16.data(from: [Float](repeating: 0, count: 32000))).encoded)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !out.decoded.contains(where: { $0.type == UInt8(ascii: "Z") }) { Thread.sleep(forTimeInterval: 0.05) }
        child.closeStdin()
        wait(for: [exited], timeout: 15)
        XCTAssertEqual(out.decoded.filter { $0.type == UInt8(ascii: "V") }.count, 1)
        let z = try XCTUnwrap(out.decoded.first { $0.type == UInt8(ascii: "Z") })
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: z.payload) as? [String: Any])
        // Only the long burst (plus its lead-in) is the turn.
        let seconds = try XCTUnwrap(info["seconds"] as? Double)
        XCTAssertLessThan(seconds, 0.9)
    }

    func testWhileTheModelSpeaksTurnsEndOnSilenceOnly() throws {
        let child = DuplexProcess(executable: try python(), arguments: [runner, "--selftest"])
        let out = DuplexProcessTests.Collected()
        let exited = expectation(description: "exit")
        try child.start(onStdout: { out.append($0) }, onExit: { _ in exited.fulfill() })
        child.write(VoiceFrame(.mode, payload: try JSONSerialization.data(withJSONObject: ["speaking": true])).encoded)
        let tone = PCM16.data(from: (0..<16000).map { sin(Float($0) * 2 * .pi * 300 / 16000) * 0.3 })
        child.write(VoiceFrame(.audio, payload: tone).encoded)
        child.write(VoiceFrame(.audio, payload: PCM16.data(from: [Float](repeating: 0, count: 32000))).encoded)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !out.decoded.contains(where: { $0.type == UInt8(ascii: "Z") }) { Thread.sleep(forTimeInterval: 0.05) }
        child.closeStdin()
        wait(for: [exited], timeout: 15)
        let z = try XCTUnwrap(out.decoded.first { $0.type == UInt8(ascii: "Z") })
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: z.payload) as? [String: Any])
        XCTAssertEqual(info["reason"] as? String, "silence")
    }
}
