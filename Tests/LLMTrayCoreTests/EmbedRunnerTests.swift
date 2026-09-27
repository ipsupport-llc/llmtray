import XCTest
@testable import LLMTrayCore

final class EmbedRunnerMessageTests: XCTestCase {
    func line(_ s: String) -> EmbedRunnerMessage? { EmbedRunnerMessage(line: Data(s.utf8)) }

    func testParsesTheRunnersLines() {
        XCTAssertEqual(line(#"{"event":"ready","protocol":1,"entry":"bge-m3","dim":1024,"max_length":8192,"load_ms":665,"verify_min_cos":0.99999,"pid":42,"limits":{"max_texts":256}}"#),
                       .ready(EmbedRunnerReady(entry: "bge-m3", dim: 1024, maxLength: 8192, loadMilliseconds: 665, verifyMinCosine: 0.99999, pid: 42)))
        XCTAssertEqual(line(#"{"event":"fatal","error":{"code":"verify_failed","message":"min cosine nan"}}"#),
                       .fatal(code: "verify_failed", message: "min cosine nan"))
        XCTAssertEqual(line(#"{"id":"r1","ok":false,"error":{"code":"timeout","message":"deadline"}}"#),
                       .failure(id: "r1", code: "timeout", message: "deadline"))
        XCTAssertEqual(line(#"{"id":null,"ok":false,"error":{"code":"too_large","message":"line"}}"#),
                       .failure(id: nil, code: "too_large", message: "line"))
        XCTAssertEqual(line(#"{"id":"p","ok":true,"pong":true,"queue":3}"#), .pong(id: "p", queued: 3))
        let v: [Float16] = [1, -0.5, 0.25, 2]
        let b64 = DenseVectors.encode(vectors: v).base64EncodedString()
        XCTAssertEqual(line(#"{"id":"r2","ok":true,"dim":2,"count":2,"dtype":"f16","vectors":"\#(b64)","tokens":[3,5],"truncated":[1],"ms":1.5}"#),
                       .result(id: "r2", EmbedResult(dim: 2, count: 2, vectors: v, tokens: [3, 5], truncated: [1], milliseconds: 1.5)))
    }

    func testRejectsMalformedLines() {
        let b64 = DenseVectors.encode(vectors: [1, 2, 3]).base64EncodedString()
        for bad in ["", "not json", "[]", #"{"event":"other"}"#, #"{"id":"r"}"#,
                    #"{"id":"r","ok":true,"dim":2,"count":2,"dtype":"f16","vectors":"\#(b64)"}"#,   // 3 values for 2×2
                    #"{"id":"r","ok":true,"dim":1,"count":3,"dtype":"f32","vectors":"\#(b64)"}"#,
                    #"{"id":"r","ok":true,"dim":1,"count":3,"dtype":"f16","vectors":"%%%"}"#,
                    #"{"event":"ready","dim":0,"entry":"x","max_length":1,"pid":1}"#] {
            XCTAssertNil(line(bad), bad)
        }
    }

    func testEncodesRequests() throws {
        let data = EmbedRunnerMessage.embedRequest(id: "r1", kind: .query, texts: ["a \"b\"\n", "ё/"], timeoutMilliseconds: 500)
        XCTAssertEqual(data.last, 0x0A)
        XCTAssertEqual(data.dropLast().filter { $0 == 0x0A }.count, 0, "one line")
        let o = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(o?["op"] as? String, "embed")
        XCTAssertEqual(o?["kind"] as? String, "query")
        XCTAssertEqual(o?["texts"] as? [String], ["a \"b\"\n", "ё/"])
        XCTAssertEqual(o?["timeout_ms"] as? Int, 500)
        let c = try JSONSerialization.jsonObject(with: EmbedRunnerMessage.cancel(id: "c", target: "r1")) as? [String: String]
        XCTAssertEqual(c, ["id": "c", "op": "cancel", "target": "r1"])
        XCTAssertEqual(String(decoding: EmbedRunnerMessage.shutdown, as: UTF8.self), "{\"op\":\"shutdown\"}\n")
    }
}

/// The managed runner against a stand-in speaking the same protocol (the
/// real one needs MLX and the model: EmbedRunnerIntegrationTests).
final class EmbedRunnerTests: XCTestCase {
    static let fake = #"""
    import sys, os, json, base64, struct, threading, time, collections
    mode = sys.argv[1]
    out = sys.stdout.buffer
    lock = threading.Lock()
    def send(o):
        with lock:
            out.write((json.dumps(o) + "\n").encode()); out.flush()
    if mode == "fatal":
        send({"event": "fatal", "error": {"code": "verify_failed", "message": "min cosine 0.5"}}); sys.exit(1)
    if mode == "slowready":
        time.sleep(30)
    if mode == "dies":
        sys.exit(4)
    parent = os.getppid()
    def watchdog():
        while True:
            time.sleep(0.1)
            if os.getppid() != parent: os._exit(3)
    threading.Thread(target=watchdog, daemon=True).start()
    cond = threading.Condition(); q = collections.deque(); d = collections.deque(); cancelled = set(); closing = [False]
    def reader():
        for line in sys.stdin.buffer:
            m = json.loads(line)
            op = m.get("op")
            if op == "cancel":
                with cond: cancelled.add(m["target"])
            elif op == "ping":
                send({"id": m.get("id"), "ok": True, "pong": True, "queue": len(q) + len(d)})
            elif op == "shutdown":
                break
            else:
                m["_t"] = time.monotonic()
                with cond:
                    m["_docs"] = len(d)
                    (q if m["kind"] == "query" else d).append(m); cond.notify()
        with cond:
            closing[0] = True; cond.notify()
    threading.Thread(target=reader, daemon=True).start()
    send({"event": "ready", "protocol": 1, "entry": os.environ.get("LLMTRAY_EMBED_RUNNER", "-"), "dim": 4,
          "max_length": 512, "load_ms": 1, "verify_min_cos": 1.0, "pid": os.getpid(), "limits": {}})
    def fail(rid, code):
        send({"id": rid, "ok": False, "error": {"code": code, "message": code}})
    def handle(m):
        rid = m["id"]; deadline = m["_t"] + m["timeout_ms"] / 1000; v = []
        for t in m["texts"]:
            with cond:
                if rid in cancelled:
                    cancelled.discard(rid); return fail(rid, "cancelled")
                if closing[0]: return fail(rid, "cancelled")
            if time.monotonic() > deadline: return fail(rid, "timeout")
            if t == "crash": os._exit(9)
            if t == "hang":
                while True: time.sleep(1)
            if t == "huge":
                with lock:
                    out.write(b"x" * 100000); out.flush()
                time.sleep(10)
            if t == "bad": return fail(rid, "bad_request")
            if t.startswith("slow:"): time.sleep(float(t[5:]))
            while m["kind"] == "document":
                with cond: qq = q.popleft() if q else None
                if qq is None: break
                handle(qq)
            v += [float(len(t)), float(sum(map(ord, t)) % 97), 1.0, -1.0]
        b = base64.b64encode(struct.pack("<%de" % len(v), *v)).decode()
        send({"id": rid, "ok": True, "dim": 4, "count": len(m["texts"]), "dtype": "f16", "vectors": b,
              "tokens": [len(t) for t in m["texts"]], "truncated": [], "ms": m["_docs"]})
    while True:
        with cond:
            while not q and not d and not closing[0]: cond.wait()
            if closing[0]:
                for m in list(q) + list(d): fail(m["id"], "cancelled")
                break
            m = q.popleft() if q else d.popleft()
        handle(m)
    sys.exit(0)
    """#

    static var script: URL?

    override class func setUp() {
        super.setUp()
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("llmtray-fake-embed-runner-\(UUID().uuidString).py")
        try? fake.write(to: url, atomically: true, encoding: .utf8)
        script = url
    }

    func runner(_ mode: String = "normal", configure: (inout EmbedRunner.Configuration) -> Void = { _ in }) throws -> EmbedRunner {
        guard let script = Self.script else { throw XCTSkip("no /usr/bin/python3") }
        var c = EmbedRunner.Configuration(executable: "/usr/bin/python3", arguments: ["-u", script.path, mode])
        c.readyTimeout = 20
        c.grace = 0.5
        c.restartBackoff = [0.05, 0.3]
        configure(&c)
        return EmbedRunner(configuration: c)
    }

    func testEmbedsAndMatchesAnswersById() async throws {
        let r = try runner()
        let ready = try await r.start()
        XCTAssertEqual(ready.dim, 4)
        XCTAssertEqual(ready.entry, "1", "the orphan marker is in its environment")
        let texts = (0..<12).map { "текст \($0)" + String(repeating: "x", count: $0) }
        try await withThrowingTaskGroup(of: (String, EmbedResult).self) { group in
            for t in texts { group.addTask { (t, try await r.embed([t, t + "!"], kind: .query)) } }
            for try await (t, result) in group {
                XCTAssertEqual(result.count, 2)
                XCTAssertEqual(result.floats(0)[0], Float(t.count), "the answer to this request")
                XCTAssertEqual(result.floats(1)[0], Float(t.count + 1))
                XCTAssertEqual(result.tokens, [t.count, t.count + 1])
            }
        }
        let empty = try await r.embed([], kind: .document)
        XCTAssertEqual(empty.count, 0)
        XCTAssertTrue(r.ping())
        r.stop()
    }

    func testQueriesGoAheadOfIndexBatches() async throws {
        let r = try runner()
        try await r.start()
        let batch = Task { () -> Date in
            _ = try await r.embed((0..<6).map { _ in "slow:0.15" }, kind: .document)
            return Date()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await r.embed(["как сбросить пароль?"], kind: .query)
        let queryDone = Date()
        let batchDone = try await batch.value
        XCTAssertLessThan(queryDone, batchDone, "the query didn't wait for the whole batch")
        // Index batches go one at a time: the runner never has another queued.
        let results = try await withThrowingTaskGroup(of: EmbedResult.self) { group -> [EmbedResult] in
            for i in 0..<4 { group.addTask { try await r.embed(["slow:0.05", "d\(i)"], kind: .document) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(results.map(\.milliseconds), [0, 0, 0, 0])
        r.stop()
    }

    func testRunnerTimeoutAndErrors() async throws {
        let r = try runner()
        do {
            _ = try await r.embed(["slow:0.3", "b"], kind: .document, timeout: 0.1)
            XCTFail("timeout")
        } catch EmbedRunner.Failure.runner(let code, _) {
            XCTAssertEqual(code, "timeout")
        }
        do {
            _ = try await r.embed(["bad"], kind: .query)
            XCTFail("bad_request")
        } catch EmbedRunner.Failure.runner(let code, _) {
            XCTAssertEqual(code, "bad_request")
        }
        do {
            _ = try await r.embed(Array(repeating: "x", count: 300), kind: .document)
            XCTFail("too many")
        } catch EmbedRunner.Failure.runner(let code, _) {
            XCTAssertEqual(code, "too_large")
        }
        let ok = try await r.embed(["still alive"], kind: .query)
        XCTAssertEqual(ok.count, 1)
        r.stop()
    }

    func testCancelAnswersAtTheNextBatchBoundary() async throws {
        let r = try runner()
        try await r.start()
        let pid = r.pid
        let task = Task { try await r.embed((0..<20).map { _ in "slow:0.1" }, kind: .document) }
        try await Task.sleep(nanoseconds: 250_000_000)
        let t0 = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
        let after = try await r.embed(["next"], kind: .query)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(r.pid, pid, "the runner survived the cancel")
        r.stop()
    }

    func testAStuckRunnerIsKilledAfterTheGraceAndReplaced() async throws {
        let r = try runner()
        try await r.start()
        let pid = r.pid!
        let t0 = Date()
        do {
            _ = try await r.embed(["hang"], kind: .document, timeout: 0.2)
            XCTFail("hang")
        } catch EmbedRunner.Failure.unresponsive {}
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
        XCTAssertNotEqual(kill(pid, 0), 0, "killed")
        try await Task.sleep(nanoseconds: 100_000_000)
        let again = try await r.embed(["after"], kind: .query)
        XCTAssertEqual(again.count, 1)
        XCTAssertNotEqual(r.pid, pid)
        r.stop()
    }

    func testCrashFailsInFlightAndRestartsWithBackoff() async throws {
        let r = try runner { $0.restartBackoff = [0.05, 5] }
        try await r.start()
        let slow = Task { try await r.embed(["slow:0.3", "x"], kind: .document) }
        try await Task.sleep(nanoseconds: 50_000_000)
        do {
            _ = try await r.embed(["crash"], kind: .query)
            XCTFail("crash")
        } catch EmbedRunner.Failure.died(let why) {
            XCTAssertTrue(why.contains("exit 9"), why)
        }
        do {
            _ = try await slow.value
            XCTFail("in flight when it crashed")
        } catch EmbedRunner.Failure.died {}
        try await Task.sleep(nanoseconds: 150_000_000)
        _ = try await r.embed(["back"], kind: .query)   // first backoff (0.05 s) passed: restarted
        do {
            _ = try await r.embed(["crash"], kind: .query)
            XCTFail("crash")
        } catch EmbedRunner.Failure.died {}
        do {
            _ = try await r.embed(["x"], kind: .query)
            XCTFail("the second crash backs off longer")
        } catch EmbedRunner.Failure.unavailable {}
        r.resetBackoff()
        _ = try await r.embed(["x"], kind: .query)
        r.stop()
    }

    func testFatalAtLoadIsReportedNotRetriedAtOnce() async throws {
        let r = try runner("fatal")
        do {
            _ = try await r.embed(["x"], kind: .query)
            XCTFail("fatal")
        } catch EmbedRunner.Failure.fatal(let why) {
            XCTAssertTrue(why.contains("min cosine 0.5"), why)
        }
        do {
            _ = try await r.embed(["x"], kind: .query)
            XCTFail("backing off")
        } catch EmbedRunner.Failure.unavailable(let why) {
            XCTAssertTrue(why.contains("verify_failed"), why)
        }
        let silent = try runner("dies")
        do {
            _ = try await silent.start()
            XCTFail("dies")
        } catch EmbedRunner.Failure.died(let why) {
            XCTAssertTrue(why.contains("exit 4"), why)
        }
        let slow = try runner("slowready") { $0.readyTimeout = 0.3 }
        do {
            _ = try await slow.start()
            XCTFail("never ready")
        } catch EmbedRunner.Failure.died(let why) {
            XCTAssertTrue(why.contains("not ready"), why)
        }
    }

    func testStopEndsItAndTheNextRequestStartsAnother() async throws {
        let r = try runner()
        try await r.start()
        let pid = r.pid!
        let batch = Task { try await r.embed((0..<10).map { _ in "slow:0.1" }, kind: .document) }
        try await Task.sleep(nanoseconds: 150_000_000)
        r.stop()
        do {
            _ = try await batch.value
            XCTFail("stopped")
        } catch EmbedRunner.Failure.stopped {}
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotEqual(kill(pid, 0), 0, "exited on stdin EOF")
        XCTAssertFalse(r.isRunning)
        _ = try await r.embed(["again"], kind: .query)
        XCTAssertNotEqual(r.pid, pid)
        // stop() while a start waits: the new runner replaces it.
        r.stop()
        let again = try await r.embed(["once more"], kind: .query)
        XCTAssertEqual(again.count, 1)
        r.stop()
    }

    func testExitsWhenIdle() async throws {
        let r = try runner { $0.idleTimeout = 0.3 }
        _ = try await r.embed(["x"], kind: .query)
        let pid = r.pid!
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertFalse(r.isRunning)
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    func testARunawayLineEndsTheRunner() async throws {
        let r = try runner { $0.maxLineBytes = 4096 }
        do {
            _ = try await r.embed(["huge"], kind: .query)
            XCTFail("violation")
        } catch EmbedRunner.Failure.protocolViolation {}
    }
}
