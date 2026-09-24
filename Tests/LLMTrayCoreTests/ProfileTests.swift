import XCTest
@testable import LLMTrayCore

final class ProfileTests: XCTestCase {
    func testBuiltInSetsEveryField() {
        for field in Profile.allFields {
            XCTAssertTrue(field.isSet(Profile.builtIn), "Profile.builtIn must set \(field.name)")
        }
        // allFields must cover every stored field: a new field added to
        // Profile but not to allFields wouldn't be counted/reset.
        let json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(Profile.builtIn)) as! [String: Any]
        let n = ["request", "tools", "launch"].reduce(0) { $0 + (json[$1] as! [String: Any]).count }
        XCTAssertEqual(n, Profile.allFields.count)
    }

    func testLayeredResolution() {
        var base = Profile(id: Profile.defaultID, name: "Default")
        base.request.temperature = 1.0
        base.launch.kvBits = 8
        var overlay = Profile(name: "Nemotron coding")
        overlay.request.temperature = 0.6
        overlay.tools.toolUsePolicy = "custom"

        let r = ProfileResolver.resolve(overlay: overlay, base: base)
        XCTAssertEqual(r.temperature, 0.6)          // overlay
        XCTAssertEqual(r.kvBits, 8)                 // base
        XCTAssertEqual(r.topP, 0.95)                // built-in
        XCTAssertEqual(r.toolUsePolicy, "custom")
        XCTAssertEqual(r.profileName, "Nemotron coding")

        XCTAssertEqual(ProfileResolver.source(\.request.temperature, overlay: overlay, base: base), .overlay)
        XCTAssertEqual(ProfileResolver.source(\.launch.kvBits, overlay: overlay, base: base), .base)
        XCTAssertEqual(ProfileResolver.source(\.request.topP, overlay: overlay, base: base), .builtIn)
        XCTAssertEqual(overlay.overrideCount, 2)

        let d = ProfileResolver.resolve(overlay: nil, base: base)
        XCTAssertEqual(d.temperature, 1.0)
        XCTAssertEqual(d.profileID, Profile.defaultID)
    }

    func testResolutionSanitizesInvalidKV() {
        var base = Profile(id: Profile.defaultID, name: "Default")
        base.launch.kvBits = 7          // mx.quantize can't do 7
        base.launch.kvGroupSize = 48    // nor 48
        let r = ProfileResolver.resolve(overlay: nil, base: base)
        XCTAssertEqual(r.kvBits, 8)
        XCTAssertEqual(r.kvGroupSize, 32)
    }

    func testOldFileWithRemovedFieldDecodes() throws {
        let json = #"{"id":"x","name":"Old","launch":{"verboseServerLogging":true,"kvBits":4}}"#
        let p = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(p.launch.kvBits, 4)
    }

    func testPartialFileDecodes() throws {
        // A hand-written overlay with only a couple of fields.
        let json = #"{"id":"x","name":"Hot","request":{"temperature":1.3}}"#
        let p = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(p.request.temperature, 1.3)
        XCTAssertNil(p.launch.kvBits)
        XCTAssertEqual(p.overrideCount, 1)
    }

    func testClearField() {
        var p = Profile(name: "x")
        p.request.topK = 64
        Profile.allFields.first { $0.name == "topK" }!.clear(&p)
        XCTAssertNil(p.request.topK)
    }
}

final class ServerLaunchTests: XCTestCase {
    private func resolved(_ mutate: (inout Profile) -> Void = { _ in }) -> ResolvedProfile {
        var base = Profile.builtIn
        base.id = Profile.defaultID
        mutate(&base)
        return ProfileResolver.resolve(overlay: nil, base: base)
    }

    private let ctx = ServerLaunch.Context(modelPath: "/m", internalPort: 18765, alias: "a", disallowQuantizedKV: false, drafterRepo: nil)

    private func value(_ args: [String], _ flag: String) -> String? {
        args.firstIndex(of: flag).map { args[$0 + 1] }
    }

    func testSamplingDefaultsAndKV() {
        let args = ServerLaunch.arguments(resolved { $0.request.temperature = 1.0; $0.request.topK = 64 }, ctx)
        XCTAssertEqual(value(args, "--temp"), "1.0")
        XCTAssertEqual(value(args, "--top-p"), "0.95")
        XCTAssertEqual(value(args, "--top-k"), "64")
        XCTAssertEqual(value(args, "--max-tokens"), "1024")
        XCTAssertEqual(value(args, "--kv-bits"), "8")
        XCTAssertEqual(value(args, "--model-alias"), "a")
        XCTAssertNil(value(args, "--draft-model"))
        XCTAssertNil(value(args, "--decode-concurrency"))
    }

    func testNeedsRestart() {
        let a = resolved()
        XCTAssertFalse(ServerLaunch.needsRestart(from: a, to: resolved { $0.request.systemPrompt = "hi" }, context: ctx))
        XCTAssertFalse(ServerLaunch.needsRestart(from: a, to: resolved { $0.tools.enableImageGeneration = true }, context: ctx))
        XCTAssertTrue(ServerLaunch.needsRestart(from: a, to: resolved { $0.request.temperature = 1.0 }, context: ctx))
        XCTAssertTrue(ServerLaunch.needsRestart(from: a, to: resolved { $0.launch.kvBits = 0 }, context: ctx))
    }

    func testNoRestartForDifferencesThatDontApplyToThisModel() {
        // KV bits differ, but the model is KV-shared: KV is off either way.
        var kvShared = ctx
        kvShared.disallowQuantizedKV = true
        XCTAssertFalse(ServerLaunch.needsRestart(from: resolved(), to: resolved { $0.launch.kvBits = 0 }, context: kvShared))
        // Drafter toggled, but the model has no drafter.
        XCTAssertFalse(ServerLaunch.needsRestart(from: resolved(), to: resolved { $0.launch.mtpDrafter = false }, context: ctx))
        // ...and does restart when it has one.
        var withDrafter = ctx
        withDrafter.drafterRepo = "org/drafter"
        XCTAssertTrue(ServerLaunch.needsRestart(from: resolved(), to: resolved { $0.launch.mtpDrafter = false }, context: withDrafter))
    }

    func testDrafterDecision() {
        XCTAssertEqual(ServerLaunch.drafter(for: resolved(), available: "d"), "d")
        XCTAssertNil(ServerLaunch.drafter(for: resolved { $0.launch.mtpDrafter = false }, available: "d"))
        XCTAssertNil(ServerLaunch.drafter(for: resolved { $0.launch.extraServerArgs = "--draft-model x" }, available: "d"))
        XCTAssertNil(ServerLaunch.drafter(for: resolved(), available: nil))
    }

    func testMaxTokensCappedToModelContext() {
        var c = ctx
        c.maxContext = 8192
        XCTAssertEqual(value(ServerLaunch.arguments(resolved { $0.request.maxTokens = 131072 }, c), "--max-tokens"), "8192")
        XCTAssertEqual(value(ServerLaunch.arguments(resolved { $0.request.maxTokens = 2048 }, c), "--max-tokens"), "2048")
    }

    func testTopKZeroOmitted() {
        XCTAssertNil(value(ServerLaunch.arguments(resolved(), ctx), "--top-k"))
    }

    func testKVSharedModelForcesKVOff() {
        var c = ctx
        c.disallowQuantizedKV = true
        let args = ServerLaunch.arguments(resolved { $0.launch.kvBits = 8 }, c)
        XCTAssertFalse(args.contains("--kv-bits"))
    }

    func testDrafterConcurrencyVerboseExtra() {
        var c = ctx
        c.drafterRepo = "org/drafter"
        c.verboseLogging = true
        let r = resolved {
            $0.launch.decodeConcurrency = 4
            $0.launch.extraServerArgs = "--foo 1  --bar"
        }
        let args = ServerLaunch.arguments(r, c)
        XCTAssertEqual(value(args, "--draft-model"), "org/drafter")
        XCTAssertEqual(value(args, "--decode-concurrency"), "4")
        XCTAssertEqual(value(args, "--log-level"), "DEBUG")
        XCTAssertEqual(Array(args.suffix(3)), ["--foo", "1", "--bar"])
        XCTAssertFalse(ServerLaunch.extraArgsSetDrafter(r))
    }
}

final class ProfileStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMigrationFromOldSettings() throws {
        let suite = "llmtray-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set(1.0, forKey: "llmtray.temperature")
        d.set(131072.0, forKey: "llmtray.maxTokens")      // stored as Double by the old slider
        d.set(4, forKey: "llmtray.decodeConcurrency")
        d.set(7, forKey: "llmtray.kvBits")                // invalid, sanitized
        d.set(true, forKey: "llmtray.enableImageGeneration")

        let store = ProfileStore(directory: dir)
        let p = try store.ensureDefault(migratingFrom: d)
        XCTAssertEqual(p.id, Profile.defaultID)
        XCTAssertEqual(p.request.temperature, 1.0)
        XCTAssertEqual(p.request.maxTokens, 131072)
        XCTAssertEqual(p.launch.decodeConcurrency, 4)
        XCTAssertEqual(p.launch.kvBits, 8)
        XCTAssertEqual(p.tools.enableImageGeneration, true)
        XCTAssertEqual(p.request.topP, 0.95)              // untouched key -> built-in
        XCTAssertEqual(p.request.systemPrompt, Profile.defaultSystemPrompt)  // never set -> visible default
        XCTAssertEqual(p.overrideCount, Profile.allFields.count)

        // Second call reads the file instead of re-migrating.
        d.set(0.2, forKey: "llmtray.temperature")
        XCTAssertEqual(try store.ensureDefault(migratingFrom: d).request.temperature, 1.0)
    }

    func testSaveLoadDeleteAndAssignments() throws {
        let store = ProfileStore(directory: dir)
        var def = Profile.builtIn
        def.id = Profile.defaultID
        def.name = "Default"
        try store.save(def)
        var a = Profile(name: "Zeta")
        a.request.temperature = 0.3
        var b = Profile(name: "alpha")
        b.launch.kvBits = 0
        try store.save(a)
        try store.save(b)
        try store.saveAssignments(["/m1": a.id, "/m2": b.id])

        XCTAssertEqual(store.loadAll().map(\.name), ["Default", "alpha", "Zeta"])
        XCTAssertEqual(store.loadAll().first { $0.id == a.id }?.request.temperature, 0.3)

        try store.delete(id: a.id)
        XCTAssertEqual(store.loadAll().map(\.name), ["Default", "alpha"])
        XCTAssertEqual(store.loadAssignments(), ["/m2": b.id])   // dangling assignment removed

        try store.delete(id: Profile.defaultID)                  // refused
        XCTAssertTrue(store.loadAll().contains { $0.isDefault })
    }

    func testBrokenDefaultIsNotOverwritten() throws {
        let store = ProfileStore(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let broken = Data(#"{"id":"default","name": "Default"  "request": {}}"#.utf8)   // missing comma
        let file = dir.appendingPathComponent("default.json")
        try broken.write(to: file)
        XCTAssertThrowsError(try store.ensureDefault(migratingFrom: UserDefaults(suiteName: "x-\(UUID())")!))
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }

    func testBrokenFileSkipped() throws {
        let store = ProfileStore(directory: dir)
        try store.save(Profile(name: "ok"))
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        var errors = 0
        XCTAssertEqual(store.loadAll(onError: { _, _ in errors += 1 }).map(\.name), ["ok"])
        XCTAssertEqual(errors, 1)
    }
}
