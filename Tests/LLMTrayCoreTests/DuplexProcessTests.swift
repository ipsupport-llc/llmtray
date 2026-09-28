import XCTest
@testable import LLMTrayCore

final class DuplexProcessTests: XCTestCase {
    private final class Collected: @unchecked Sendable {
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

    private final class ExitBox: @unchecked Sendable {
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

    // MARK: The real runner, --selftest (no model, any Python 3)

    private var runner: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runtime/llmtray_voice_runner.py").path
    }

    private func python() throws -> String {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("no python3")
        }
        return python
    }

    func testRunnerSelftestEchoesFrames() throws {
        let child = DuplexProcess(executable: try python(), arguments: [runner, "--selftest"],
                                  environment: ["PYTHONDONTWRITEBYTECODE": "1"])
        let out = Collected()
        let exited = expectation(description: "exit")
        let exit = ExitBox()
        try child.start(onStdout: { out.append($0) }, onExit: { exit.value = $0; exited.fulfill() })
        let pcm = PCM16.data(from: (0..<1280).map { sin(Float($0) / 10) * 0.5 })
        // Split mid-header and mid-payload, and two frames in one write.
        let a = VoiceFrame(.audio, payload: pcm).encoded
        child.write(a.prefix(3))
        child.write(a.dropFirst(3).prefix(1000))
        child.write(a.dropFirst(1003) + VoiceFrame(.audio, payload: Data([0x10, 0x00])).encoded)
        child.write(VoiceFrame(type: 0x58).encoded)
        child.write(VoiceFrame(.endOfTurn, text: "4").encoded)   // walkie-talkie: a reply, then Z
        child.write(VoiceFrame(.quit).encoded)
        child.closeStdin()
        wait(exited)
        XCTAssertEqual(exit.value?.status, 0)
        let frames = out.decoded
        XCTAssertEqual(frames.first?.kind, .ready)
        let ready = try XCTUnwrap(VoiceRunnerReady(payload: frames[0].payload))
        XCTAssertEqual(ready.inputSampleRate, 16_000)
        XCTAssertEqual(ready.rtf, 0.5)
        XCTAssertEqual(frames.filter { $0.kind == .speech }.count, 4)
        XCTAssertEqual(frames.filter { $0.kind == .speech }.prefix(2).map(\.payload), [pcm, Data([0x10, 0x00])])
        XCTAssertEqual(frames.last { $0.kind == .replyDone }.flatMap { VoiceReplyDone(payload: $0.payload) },
                       VoiceReplyDone(reason: .done, turn: 4, seconds: 0))
        XCTAssertEqual(frames.last?.kind, .replyDone)
        XCTAssertEqual(frames.filter { $0.kind == .log }.count, 2)
        XCTAssertTrue(frames.contains { $0.kind == .error && $0.text.contains("unknown frame type") })
    }

    func testRunnerExitsAtEOF() throws {
        let child = DuplexProcess(executable: try python(), arguments: [runner, "--selftest"])
        let out = Collected()
        let exited = expectation(description: "exit")
        let exit = ExitBox()
        try child.start(onStdout: { out.append($0) }, onExit: { exit.value = $0; exited.fulfill() })
        child.closeStdin()
        wait(exited)
        XCTAssertEqual(exit.value?.status, 0)
        XCTAssertEqual(out.decoded.map(\.kind), [.ready])
    }
}
