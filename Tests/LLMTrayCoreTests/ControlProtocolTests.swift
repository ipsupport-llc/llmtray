import XCTest
@testable import LLMTrayCore

final class ControlProtocolTests: XCTestCase {
    private func decode(_ json: String) -> Result<ControlRequest, ControlRequestError> {
        ControlProtocol.decodeRequest(Data(json.utf8))
    }

    private func roundTrip(_ command: ControlCommand, file: StaticString = #filePath, line: UInt = #line) throws {
        var data = try ControlProtocol.line(ControlRequest(command))
        XCTAssertEqual(data.last, 0x0A, file: file, line: line)
        data.removeLast()
        XCTAssertFalse(data.contains(0x0A), "one line on the wire", file: file, line: line)
        XCTAssertEqual(try ControlProtocol.decodeRequest(data).get(), ControlRequest(command), file: file, line: line)
    }

    func testEveryCommandRoundTrips() throws {
        try roundTrip(.status)
        try roundTrip(.models)
        try roundTrip(.start(model: nil))
        try roundTrip(.start(model: "gemma"))
        try roundTrip(.stop)
        try roundTrip(.pull(repo: "mlx-community/Qwen3-4B-4bit"))
        try roundTrip(.image(.init(prompt: "a cat\non two lines", width: 512, height: 768, model: "klein4b")))
        try roundTrip(.image(.init(prompt: "just a prompt")))
    }

    func testWireShapeIsFlat() throws {
        let data = try ControlProtocol.line(ControlRequest(.pull(repo: "a/b")))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"cmd\":\"pull\",\"repo\":\"a/b\",\"v\":1}\n")
    }

    func testUnknownFieldsAreIgnored() throws {
        XCTAssertEqual(try decode(#"{"v":1,"cmd":"start","model":"m","colour":"blue","nested":{"x":[1,2]}}"#).get(),
                       ControlRequest(.start(model: "m")))
    }

    func testUnknownCommandIsAClearError() {
        guard case .failure(let error) = decode(#"{"v":1,"cmd":"reboot"}"#) else { return XCTFail("decoded") }
        XCTAssertEqual(error, .unknownCommand("reboot"))
        XCTAssertTrue(error.localizedDescription.contains("unknown command \"reboot\""))
        XCTAssertTrue(error.localizedDescription.contains("status"), "lists the known ones")
    }

    func testVersionIsRequiredAndChecked() {
        XCTAssertEqual(decode(#"{"cmd":"status"}"#), .failure(.missingVersion))
        XCTAssertEqual(decode(#"{"v":2,"cmd":"status"}"#), .failure(.unsupportedVersion(2)))
        XCTAssertEqual(decode(#"{"v":0,"cmd":"status"}"#), .failure(.unsupportedVersion(0)))
        XCTAssertEqual(decode(#"{"v":"1","cmd":"status"}"#), .failure(.malformed))
    }

    func testMissingAndMalformedFields() {
        XCTAssertEqual(decode(#"{"v":1}"#), .failure(.missingField(command: "request", field: "cmd")))
        XCTAssertEqual(decode(#"{"v":1,"cmd":"pull"}"#), .failure(.missingField(command: "pull", field: "repo")))
        XCTAssertEqual(decode(#"{"v":1,"cmd":"image","prompt":"  "}"#), .failure(.missingField(command: "image", field: "prompt")))
        XCTAssertEqual(decode(#"{"v":1,"cmd":"image","prompt":"x","width":"big"}"#), .failure(.malformed))
        XCTAssertEqual(decode("[1,2]"), .failure(.malformed))
        XCTAssertEqual(decode("not json"), .failure(.malformed))
        // An empty model is no model (the selected one).
        XCTAssertEqual(try decode(#"{"v":1,"cmd":"start","model":""}"#).get(), ControlRequest(.start(model: nil)))
    }

    func testRepliesRoundTripAndToleratesUnknownFields() throws {
        let status = ControlStatus(state: ControlStatus.running, model: "gemma", modelPath: "/m/g", selectedModel: "gemma",
                                   port: 8765, idleUnloaded: false, appVersion: "0.9.0",
                                   baseURL: ControlStatus.baseURL(port: 8765), appTokenHeader: "X-LLMTray-App", appToken: "secret")
        let replies = [
            ControlReply(done: true, status: status),
            ControlReply(done: true, models: [ControlModel(path: "/m/g", name: "gemma", displayName: "org/g", sizeBytes: 42, selected: true, loaded: false)]),
            ControlReply(event: ControlReply.Event.progress, message: "1 GB of 2", progress: 0.5),
            ControlReply(event: ControlReply.Event.queued, position: 2),
            ControlReply.failure("nope"),
        ]
        for reply in replies {
            var line = try ControlProtocol.line(reply)
            line.removeLast()
            XCTAssertEqual(try ControlProtocol.decodeReply(line), reply)
        }
        // Absent optionals aren't written at all.
        XCTAssertEqual(String(decoding: try ControlProtocol.line(ControlReply.failure("x")), as: UTF8.self), "{\"error\":\"x\"}\n")
        // A newer app's extra fields and event kinds.
        let newer = try ControlProtocol.decodeReply(Data(#"{"event":"thermal","level":3,"done":null}"#.utf8))
        XCTAssertEqual(newer.event, "thermal")
        XCTAssertFalse(newer.isFinal)
        let newerStatus = try ControlProtocol.decodeReply(Data(#"{"done":true,"status":{"state":"paused","port":1,"idleUnloaded":false,"appVersion":"9","baseURL":"u","appTokenHeader":"h","appToken":"t","gpu":"x"}}"#.utf8))
        XCTAssertEqual(newerStatus.status?.state, "paused")
        XCTAssertTrue(newerStatus.isFinal)
    }

    func testFinalLines() {
        XCTAssertTrue(ControlReply(done: true).isFinal)
        XCTAssertTrue(ControlReply.failure("x").isFinal)
        XCTAssertFalse(ControlReply(event: ControlReply.Event.state, state: "starting").isFinal)
    }

    func testStatusCanAnswer() {
        func status(_ state: String, idle: Bool = false) -> ControlStatus {
            ControlStatus(state: state, port: 1, idleUnloaded: idle, appVersion: "", baseURL: "", appTokenHeader: "", appToken: "")
        }
        XCTAssertTrue(status(ControlStatus.running).canAnswer)
        XCTAssertTrue(status(ControlStatus.stopped, idle: true).canAnswer)
        XCTAssertFalse(status(ControlStatus.stopped).canAnswer)
        XCTAssertFalse(status(ControlStatus.starting).canAnswer)
        XCTAssertFalse(status(ControlStatus.failed).canAnswer)
    }

    func testSocketPath() {
        XCTAssertEqual(ControlProtocol.socketPath(applicationSupport: "/Users/u/Library/Application Support"),
                       "/Users/u/Library/Application Support/LLMTray/control.sock")
        XCTAssertEqual(ControlProtocol.socketPath(environment: [ControlProtocol.socketPathEnvironment: "/tmp/x.sock"]), "/tmp/x.sock")
        XCTAssertTrue(ControlProtocol.socketPath(environment: [:]).hasSuffix("/Library/Application Support/LLMTray/control.sock"))
    }

    // MARK: - Lines

    func testLineBufferSplitsAcrossChunks() throws {
        var buffer = ControlLineBuffer(maxLineBytes: 100)
        XCTAssertEqual(try buffer.append(Data("{\"a\":".utf8)), [])
        XCTAssertTrue(buffer.hasPartialLine)
        XCTAssertEqual(try buffer.append(Data("1}\n{\"b\":2}\r\n\n{\"c\"".utf8)), [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
        XCTAssertEqual(try buffer.append(Data(":3}\n".utf8)), [Data("{\"c\":3}".utf8)])
        XCTAssertFalse(buffer.hasPartialLine)
    }

    func testLineBufferRefusesOverlongLines() {
        var buffer = ControlLineBuffer(maxLineBytes: 8)
        XCTAssertThrowsError(try buffer.append(Data("0123456789".utf8)), "no newline yet, already too long")
        var other = ControlLineBuffer(maxLineBytes: 8)
        XCTAssertThrowsError(try other.append(Data("0123456789\n".utf8)))
        var fits = ControlLineBuffer(maxLineBytes: 8)
        XCTAssertEqual(try fits.append(Data("01234567\n".utf8)), [Data("01234567".utf8)])
    }

    // MARK: - Helpers

    func testHubRepoNames() {
        for valid in ["mlx-community/Qwen3-4B-4bit", "roman220220/flux2-klein-4b-mlx-mixed", "a/b", "Org_1/model.v2"] {
            XCTAssertTrue(HubRepoName.isValid(valid), valid)
        }
        for invalid in ["", "model", "a/b/c", "/abs", "a/", "../x", "a/..", "a/.hidden", "a b/c", "org/naïve", "a\\b/c", "org/name\n"] {
            XCTAssertFalse(HubRepoName.isValid(invalid), invalid)
        }
    }

    func testStartPlan() {
        func plan(_ server: ActivitySnapshot.Server, loaded: String? = "/m/a", target: String = "/m/a",
                  suspended: Bool = false, benchmark: Bool = false) -> ControlStartPlan {
            ControlStartPlan.decide(OperationAvailability(ActivitySnapshot(server: server, benchmarkRunning: benchmark)),
                                    suspendedForMedia: suspended, loaded: loaded, target: target)
        }
        XCTAssertEqual(plan(.stopped), .start)
        XCTAssertEqual(plan(.failed), .start)
        XCTAssertEqual(plan(.starting), .wait)
        XCTAssertEqual(plan(.running), .alreadyRunning)
        XCTAssertEqual(plan(.running, target: "/m/b"), .load)
        XCTAssertEqual(plan(.idleUnloaded), .load, "an idle-unloaded model is reloaded, not restarted")
        XCTAssertEqual(plan(.idleUnloaded, target: "/m/b"), .load)
        guard case .refuse = plan(.running, target: "/m/b", benchmark: true) else { return XCTFail("switch under auto-tune") }
        guard case .refuse = plan(.stopped, suspended: true) else { return XCTFail("start next to an image") }
    }
}
