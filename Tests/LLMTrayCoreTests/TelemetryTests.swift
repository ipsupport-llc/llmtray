import Foundation
@testable import LLMTrayCore
import XCTest

private var utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private let env = TelemetryEnvironment(appVersion: "0.7.2", osVersion: "15.1.1", chip: "Apple M3 Pro", memoryGB: 36, locale: "de-DE")
private let installID = UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!

final class TelemetryFamilyTests: XCTestCase {
    func testFamiliesFromPathsAndRepos() {
        let cases: [(String, TelemetryModelFamily)] = [
            ("/Users/a/models/mlx-community/Qwen3-8B-4bit", .qwen),
            ("mlx-community/QwQ-32B-4bit", .qwen),
            ("mlx-community/gemma-3-27b-it-qat-4bit", .gemma),
            ("google/codegemma-7b", .gemma),
            ("mlx-community/Llama-3.2-3B-Instruct-4bit", .llama),
            ("mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit", .mistral),
            ("mlx-community/Devstral-Small-2507-4bit", .mistral),
            ("mlx-community/Mixtral-8x7B", .mistral),
            ("mlx-community/phi-4-4bit", .phi),
            ("microsoft/Phi-3.5-mini-instruct", .phi),
            ("cognitivecomputations/dolphin-2.9", .other),
            ("mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit", .deepseek),
            ("mlx-community/DeepSeek-R1-Distill-Llama-8B", .deepseek),
            ("mlx-community/gpt-oss-20b-MXFP4-Q8", .gptOSS),
            ("mlx-community/GLM-4.5-Air-4bit", .glm),
            ("roman220220/flux2-klein-4b-mlx-mixed", .flux),
            ("roman220220/z-image-turbo-gptq-mlx-8bit", .zImage),
            ("mlx-community/ACE-Step1.5-MLX-4bit", .aceStep),
            ("roman220220/ACE-Step1.5-sft-MLX-bf16", .aceStep),
            ("nvidia/Nemotron-Nano-9B-v2", .other),
            ("", .other),
        ]
        for (model, family) in cases {
            XCTAssertEqual(TelemetryModelFamily.of(model: model), family, model)
        }
    }

    func testOnlyTheLastTwoComponentsCount() {
        // The folder the user keeps models in is not the model.
        XCTAssertEqual(TelemetryModelFamily.of(model: "/Users/llama/qwen-stuff/acme/SuperModel-7B"), .other)
    }

    func testFamiliesMatchTheServersEnum() {
        XCTAssertEqual(TelemetryModelFamily.allCases.map(\.rawValue),
                       ["gemma", "qwen", "llama", "mistral", "phi", "deepseek", "gpt-oss", "glm", "flux", "z-image", "ace-step", "other"])
        XCTAssertEqual(TelemetryFeature.allCases.map(\.rawValue),
                       ["chat", "tool_calls", "api_server", "image_generate", "image_edit", "music", "lora", "model_download"])
    }
}

final class TelemetryReportTests: XCTestCase {
    private func report(day: String = "2026-09-26", today: String = "2026-09-27", env: TelemetryEnvironment = env,
                        usage: TelemetryUsage = TelemetryUsage(features: ["chat": 12, "music": 1], families: ["qwen", "flux"])) throws -> TelemetryReport {
        try TelemetryReport(installID: installID, day: day, today: today, environment: env, usage: usage, calendar: utc)
    }

    func testBodyIsExactlyTheSpecFields() throws {
        let body = try report().body()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json as NSDictionary, [
            "product": "llmtray", "install_id": "7c9e6679-7425-40de-944b-e07fc1f90ae7", "day": "2026-09-26",
            "app_version": "0.7.2", "os_version": "15.1.1", "chip": "Apple M3 Pro", "memory_gb": 36, "locale": "de",
            "features": ["chat": 12, "music": 1], "model_families": ["flux", "qwen"],
        ] as NSDictionary)
    }

    func testNormalization() throws {
        let r = try report(usage: TelemetryUsage(features: ["chat": 0, "tool_calls": 3, "future_thing": 9],
                                                 families: ["Qwen", "whatever", "qwen", "other"]))
        XCTAssertEqual(r.features, ["tool_calls": 3])   // zeros and unknown keys left out
        XCTAssertEqual(r.modelFamilies, ["other", "qwen"])
        XCTAssertEqual(TelemetryReport.chip(brand: "Apple M5"), "Apple M5")
        XCTAssertEqual(TelemetryReport.chip(brand: " Apple M4 Max "), "Apple M4 Max")
        XCTAssertEqual(TelemetryReport.chip(brand: "Intel(R) Core(TM) i9"), "other")
        XCTAssertEqual(TelemetryReport.language("de-DE"), "de")
        XCTAssertEqual(TelemetryReport.language("zh_Hant_TW"), "zh")
        XCTAssertEqual(TelemetryReport.language("en"), "en")
        XCTAssertEqual(TelemetryReport.language("x"), "")
        XCTAssertEqual(TelemetryReport.osVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)), "26.1.0")
        XCTAssertEqual(TelemetryReport.memoryGB(bytes: 36 * 1_073_741_824), 36)
        XCTAssertEqual(TelemetryReport.memoryGB(bytes: 25_769_803_776), 24)
    }

    func testValidationMirrorsTheServer() {
        func code(_ make: () throws -> TelemetryReport) -> String? {
            do { _ = try make(); return nil } catch { return (error as? TelemetryValidationError)?.code }
        }
        var e = env
        XCTAssertNil(code { try self.report() })
        XCTAssertEqual(code { try self.report(day: "2026-9-26") }, "invalid_day")
        XCTAssertEqual(code { try self.report(day: "2026-02-30", today: "2026-03-01") }, "invalid_day")
        XCTAssertEqual(code { try self.report(day: "2026-09-19") }, "invalid_day")   // 8 days back
        XCTAssertNil(code { try self.report(day: "2026-09-20") })                    // 7 days back
        XCTAssertEqual(code { try self.report(day: "2026-09-28") }, "invalid_day")   // the future
        e.appVersion = ""
        XCTAssertEqual(code { try self.report(env: e) }, "invalid_app_version")
        e.appVersion = "0.7.2 beta"
        XCTAssertEqual(code { try self.report(env: e) }, "invalid_app_version")
        e.appVersion = "0.7.2-beta.1"
        XCTAssertNil(code { try self.report(env: e) })
        e.osVersion = "15.1.1.1"
        XCTAssertEqual(code { try self.report(env: e) }, "invalid_os_version")
        e.osVersion = "123"
        XCTAssertEqual(code { try self.report(env: e) }, "invalid_os_version")
        e.osVersion = "26"
        XCTAssertNil(code { try self.report(env: e) })
        e.memoryGB = 4097
        XCTAssertEqual(code { try self.report(env: e) }, "invalid_memory")
        e.memoryGB = 36
        XCTAssertEqual(code { try self.report(usage: TelemetryUsage(features: ["chat": -1])) }, "invalid_features")
        XCTAssertEqual(code { try self.report(usage: TelemetryUsage(features: ["chat": 10_000_001])) }, "invalid_features")
    }

    func testCountsSaturateAtTheServersMaximum() {
        var usage = TelemetryUsage(features: ["chat": TelemetryReport.maxFeatureCount])
        usage.add(.chat)
        XCTAssertEqual(usage.features["chat"], TelemetryReport.maxFeatureCount)
    }
}

final class TelemetryOutcomeTests: XCTestCase {
    func testClassification() {
        func c(_ status: Int?, _ body: String = "", retryAfter: String? = nil) -> TelemetryOutcome {
            TelemetryOutcome.classify(status: status, body: Data(body.utf8), retryAfter: retryAfter)
        }
        XCTAssertEqual(c(204), .sent)
        XCTAssertEqual(c(400, #"{"error":"invalid_day"}"#), .dropped(code: "invalid_day"))
        XCTAssertEqual(c(400), .dropped(code: "http_400"))
        XCTAssertEqual(c(413), .dropped(code: "payload_too_large"))
        XCTAssertEqual(c(415), .dropped(code: "unsupported_media_type"))
        XCTAssertEqual(c(429, #"{"error":"rate_limited"}"#, retryAfter: "7200"), .retryLater(seconds: 7200))
        XCTAssertEqual(c(429, retryAfter: "soon"), .retryLater(seconds: nil))
        XCTAssertEqual(c(500), .retryLater(seconds: nil))
        XCTAssertEqual(c(503), .retryLater(seconds: nil))
        XCTAssertEqual(c(nil), .retryLater(seconds: nil))
    }
}

final class TelemetryCountersTests: XCTestCase {
    func testRecordsPerDay() {
        var c = TelemetryCounters()
        c.record(.chat, family: .qwen, on: "2026-09-26")
        c.record(.chat, family: .qwen, on: "2026-09-26")
        c.record(.imageGenerate, family: .flux, on: "2026-09-26")
        c.record(.chat, family: nil, on: "2026-09-27")
        c.touch("2026-09-27")
        XCTAssertEqual(c.days["2026-09-26"], TelemetryUsage(features: ["chat": 2, "image_generate": 1], families: ["flux", "qwen"]))
        XCTAssertEqual(c.days["2026-09-27"], TelemetryUsage(features: ["chat": 1]))
    }

    func testRolloverKeepsSevenDaysBack() {
        var c = TelemetryCounters()
        for day in ["2026-09-18", "2026-09-19", "2026-09-20", "2026-09-26", "2026-09-27", "2026-09-28"] { c.touch(day) }
        c.days["garbage"] = TelemetryUsage()
        c.prune(today: "2026-09-27", calendar: utc)
        // 8 and 9 days back dropped, 7 back kept; tomorrow (a clock set back) dropped.
        XCTAssertEqual(c.days.keys.sorted(), ["2026-09-20", "2026-09-26", "2026-09-27"])
        // Today's isn't sent until the day is over.
        XCTAssertEqual(c.pending(today: "2026-09-27"), ["2026-09-20", "2026-09-26"])
    }

    func testApply() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var c = TelemetryCounters()
        c.touch("2026-09-25"); c.touch("2026-09-26")
        XCTAssertTrue(c.apply(.sent, day: "2026-09-25", now: now))
        XCTAssertFalse(c.apply(.retryLater(seconds: 60), day: "2026-09-26", now: now))
        XCTAssertEqual(c.notBefore, now.addingTimeInterval(60))
        XCTAssertEqual(Array(c.days.keys), ["2026-09-26"])
        XCTAssertTrue(c.apply(.dropped(code: "invalid_day"), day: "2026-09-26", now: now))
        XCTAssertTrue(c.days.isEmpty)
        XCTAssertNil(c.notBefore)
    }

    @MainActor
    func testStorePersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-\(UUID().uuidString)/telemetry.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = TelemetryCounterStore(url: url)
        store.update { $0.record(.music, family: .aceStep, on: "2026-09-26") }
        XCTAssertEqual(TelemetryCounterStore(url: url).counters, store.counters)
        store.erase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(TelemetryCounterStore(url: url).counters, TelemetryCounters())
    }
}

/// The client and the uploader against a stub: nothing reaches ipsupport.us.
@MainActor
final class TelemetryUploaderTests: XCTestCase {
    final class Stub: URLProtocol {
        static var statuses: [Int] = []
        static var headers: [String: String] = [:]
        static var requests: [URLRequest] = []
        static var bodies: [Data] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
            Self.bodies.append(ReviewClientTests.Stub.readBody(request))
            let status = Self.statuses.isEmpty ? 204 : Self.statuses.removeFirst()
            if status == 0 {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: Self.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private let endpoint = URL(string: "http://telemetry-stub.invalid/api/telemetry")!
    private var storeURL: URL!
    private var uploader: TelemetryUploader!
    /// 2026-09-27 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_510_400)

    override func setUp() async throws {
        Stub.statuses = []
        Stub.headers = [:]
        Stub.requests = []
        Stub.bodies = []
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-\(UUID().uuidString)/telemetry.json")
        let client = TelemetryClient(endpoint: endpoint, session: ReviewClient.makeSession { $0.protocolClasses = [Stub.self] },
                                     userAgent: "LLMTray/0.7.2")
        uploader = TelemetryUploader(client: client, calendar: utc)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }

    private func store(_ days: [String]) -> TelemetryCounterStore {
        let store = TelemetryCounterStore(url: storeURL)
        for day in days { store.update { $0.record(.chat, family: .qwen, on: day) } }
        return store
    }

    func testNowIsTheTwentySeventh() {
        XCTAssertEqual(TelemetryDay.string(for: now, calendar: utc), "2026-09-27")
    }

    func testSendsPastDaysOldestFirstNotToday() async throws {
        let store = store(["2026-09-15", "2026-09-20", "2026-09-26", "2026-09-27"])
        let done = await uploader.run(store: store, now: { self.now }, installID: { installID }, environment: { env })
        XCTAssertEqual(done, ["2026-09-20", "2026-09-26"])
        // Older than 7 days: dropped without a send. Today: kept for tomorrow.
        XCTAssertEqual(Stub.requests.count, 2)
        XCTAssertEqual(store.counters.days.keys.sorted(), ["2026-09-27"])
        let request = try XCTUnwrap(Stub.requests.first)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "LLMTray/0.7.2")
        let days = try Stub.bodies.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])["day"] as? String }
        XCTAssertEqual(days, ["2026-09-20", "2026-09-26"])
    }

    func testBadRequestDropsTheDayAndGoesOn() async {
        Stub.statuses = [400, 204]
        let store = store(["2026-09-25", "2026-09-26"])
        await uploader.run(store: store, now: { self.now }, installID: { installID }, environment: { env })
        XCTAssertEqual(Stub.requests.count, 2)
        XCTAssertTrue(store.counters.pending(today: "2026-09-27").isEmpty)
    }

    func testRateLimitWaitsForRetryAfter() async {
        Stub.statuses = [429]
        Stub.headers = ["Retry-After": "7200"]
        let store = store(["2026-09-25", "2026-09-26"])
        await uploader.run(store: store, now: { self.now }, installID: { installID }, environment: { env })
        XCTAssertEqual(Stub.requests.count, 1)
        XCTAssertEqual(store.counters.pending(today: "2026-09-27"), ["2026-09-25", "2026-09-26"])
        XCTAssertEqual(store.counters.notBefore, now.addingTimeInterval(7200))
        // Too early: nothing sent.
        await uploader.run(store: store, now: { self.now.addingTimeInterval(3600) }, installID: { installID }, environment: { env })
        XCTAssertEqual(Stub.requests.count, 1)
        // After it: the same days again (the server replaces a day it has).
        await uploader.run(store: store, now: { self.now.addingTimeInterval(7201) }, installID: { installID }, environment: { env })
        XCTAssertEqual(Stub.requests.count, 3)
        XCTAssertTrue(store.counters.days.isEmpty)
    }

    func testServerErrorAndNoNetworkRetryLater() async {
        Stub.statuses = [503]
        let store = store(["2026-09-26"])
        await uploader.run(store: store, now: { self.now }, installID: { installID }, environment: { env })
        XCTAssertEqual(store.counters.pending(today: "2026-09-27"), ["2026-09-26"])
        XCTAssertEqual(store.counters.notBefore, now.addingTimeInterval(TimeInterval(TelemetryOutcome.defaultBackoff)))
        Stub.statuses = [0]
        await uploader.run(store: store, now: { self.now.addingTimeInterval(4000) }, installID: { installID }, environment: { env })
        XCTAssertEqual(store.counters.pending(today: "2026-09-27"), ["2026-09-26"])
    }

    func testTurnedOffSendsNothing() async {
        let store = store(["2026-09-26"])
        await uploader.run(store: store, now: { self.now }, installID: { nil }, environment: { env })
        XCTAssertTrue(Stub.requests.isEmpty)
    }

    func testTurnedOffMidSendLeavesTheStoreAlone() async {
        let store = store(["2026-09-25", "2026-09-26"])
        var calls = 0
        // On before the first send, off by the time its answer is in.
        await uploader.run(store: store, now: { self.now }, installID: {
            calls += 1
            return calls == 1 ? installID : nil
        }, environment: { env })
        XCTAssertEqual(Stub.requests.count, 1)
        XCTAssertEqual(store.counters.pending(today: "2026-09-27").count, 2)
    }
}
