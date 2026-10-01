import Darwin
import XCTest
@testable import LLMTrayCore

/// The control socket end to end, in-process: a real server on a temporary
/// path, the CLI's own client, a stand-in for the app's command handler.
@MainActor
final class ControlSocketTests: XCTestCase {
    private var directory: String!
    private var path: String { directory + "/c.sock" }

    override func setUp() async throws {
        // Short: sun_path is 104 bytes, and NSTemporaryDirectory is long.
        directory = "/tmp/llmtray-test-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// The client blocks: off the main actor, where the server runs.
    private func client<T: Sendable>(_ body: @escaping @Sendable (ControlSocketClient) throws -> T) async throws -> T {
        let path = path
        return try await Task.detached {
            guard let client = ControlSocketClient.connect(path: path) else { throw ControlSocketClient.Failure("no server") }
            return try body(client)
        }.value
    }

    func testRequestAndReplyRoundTrip() async throws {
        var seen: [ControlCommand] = []
        let server = ControlSocketServer(path: path) { command, reply in
            seen.append(command)
            reply.send(ControlReply(done: true, message: command.name))
        }
        try server.start()
        defer { server.stop() }
        let done = try await client { try $0.run(.start(model: "gemma")) }
        XCTAssertEqual(done.message, "start")
        XCTAssertEqual(seen, [.start(model: "gemma")])
    }

    func testStreamingEventsThenDone() async throws {
        let server = ControlSocketServer(path: path) { _, reply in
            for i in 1...3 { reply.send(ControlReply(event: ControlReply.Event.progress, progress: Double(i) / 3)) }
            reply.send(ControlReply(done: true, image: Data([1, 2, 3]).base64EncodedString()))
        }
        try server.start()
        defer { server.stop() }
        let (events, done) = try await client { client -> ([Double], ControlReply) in
            var events: [Double] = []
            let done = try client.run(.image(.init(prompt: "p"))) { events.append($0.progress ?? -1) }
            return (events, done)
        }
        XCTAssertEqual(events, [1.0 / 3, 2.0 / 3, 1])
        XCTAssertEqual(done.image.flatMap { Data(base64Encoded: $0) }, Data([1, 2, 3]))
    }

    func testErrorsComeBackAsErrorLines() async throws {
        let server = ControlSocketServer(path: path) { _, reply in reply.send(.failure("no model selected")) }
        try server.start()
        defer { server.stop() }
        do {
            _ = try await client { try $0.run(.status) }
            XCTFail("no error")
        } catch let failure as ControlSocketClient.Failure {
            XCTAssertEqual(failure.description, "no model selected")
        }
    }

    func testBadRequestsGetAClearErrorAndTheConnectionStaysUsable() async throws {
        let server = ControlSocketServer(path: path) { _, reply in reply.send(ControlReply(done: true)) }
        try server.start()
        defer { server.stop() }
        let path = path
        let replies = try await Task.detached { () -> [ControlReply] in
            guard let fd = UnixSocket.connect(path) else { throw ControlSocketClient.Failure("no server") }
            defer { close(fd) }
            _ = UnixSocket.writeAll(fd, Data("{\"v\":1,\"cmd\":\"reboot\"}\nnot json\n{\"v\":1,\"cmd\":\"status\"}\n".utf8))
            var buffer = ControlLineBuffer(maxLineBytes: 1 << 20)
            var lines: [Data] = []
            while lines.count < 3 {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let n = read(fd, &chunk, chunk.count)
                guard n > 0 else { break }
                lines += try buffer.append(Data(chunk[0..<n]))
            }
            return try lines.map(ControlProtocol.decodeReply)
        }.value
        XCTAssertEqual(replies.count, 3)
        XCTAssertTrue(replies[0].error?.contains("unknown command \"reboot\"") == true)
        XCTAssertTrue(replies[1].error?.contains("malformed request") == true)
        XCTAssertEqual(replies[2].done, true, "answered in order, after the errors")
    }

    func testTooLongARequestIsRefused() async throws {
        let server = ControlSocketServer(path: path) { _, reply in reply.send(ControlReply(done: true)) }
        try server.start()
        defer { server.stop() }
        let path = path
        let reply = try await Task.detached { () -> String in
            guard let fd = UnixSocket.connect(path) else { throw ControlSocketClient.Failure("no server") }
            defer { close(fd) }
            _ = UnixSocket.writeAll(fd, Data(repeating: 0x61, count: ControlProtocol.maxRequestBytes + 70_000))
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &chunk, chunk.count)
                guard n > 0 else { break }
                data.append(contentsOf: chunk[0..<n])
            }
            return String(decoding: data, as: UTF8.self)
        }.value
        XCTAssertTrue(reply.contains("request too long"), reply)
    }

    func testTheSocketIsOwnerOnly() throws {
        let server = ControlSocketServer(path: path) { _, _ in }
        try server.start()
        defer { server.stop() }
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testAStaleSocketFileIsReplacedAndALiveOneIsLeftAlone() throws {
        // A crashed run's file: nothing listens on it.
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let first = ControlSocketServer(path: path) { _, _ in }
        try first.start()
        XCTAssertTrue(first.isListening)
        // A second copy finds the first one answering.
        let second = ControlSocketServer(path: path) { _, _ in }
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? ControlSocketServer.StartError, .inUse(path))
        }
        XCTAssertNotNil(UnixSocket.connect(path).map { close($0) }, "the first one still answers")
        first.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "stop removes the file")
        XCTAssertNil(UnixSocket.connect(path))
    }

    func testAPathTooLongForAUnixSocketIsRefused() {
        let server = ControlSocketServer(path: "/tmp/" + String(repeating: "x", count: 120)) { _, _ in }
        XCTAssertThrowsError(try server.start()) { error in
            guard case .pathTooLong = error as? ControlSocketServer.StartError else { return XCTFail("\(error)") }
        }
    }

    func testAClientHangingUpIsSeenByTheHandler() async throws {
        var sawClose = false
        let finished = expectation(description: "handler noticed")
        let server = ControlSocketServer(path: path) { _, reply in
            reply.send(ControlReply(event: ControlReply.Event.queued, position: 1))
            // A streaming command polls isClosed, as pull and image do.
            for _ in 0..<100 where !reply.isClosed { try? await Task.sleep(nanoseconds: 20_000_000) }
            sawClose = reply.isClosed
            finished.fulfill()
        }
        try server.start()
        defer { server.stop() }
        try await client { client in
            try client.send(.pull(repo: "a/b"))
            _ = try client.next()   // the first event; then the client goes (deinit closes it)
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertTrue(sawClose)
    }

    func testNoServerMeansNoClient() {
        XCTAssertNil(ControlSocketClient.connect(path: path))
    }
}
