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

    func testResolutionClampsSamplingValues() {
        var base = Profile(id: Profile.defaultID, name: "Default")
        base.request.maxTokens = -1     // a typo in the editor or the JSON
        base.request.temperature = -0.5
        base.request.topP = 3
        base.request.topK = -8
        let r = ProfileResolver.resolve(overlay: nil, base: base)
        XCTAssertEqual(r.maxTokens, 1)
        XCTAssertEqual(r.temperature, 0)
        XCTAssertEqual(r.topP, 1)
        XCTAssertEqual(r.topK, 0)
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
        XCTAssertEqual(value(args, "--max-tokens"), "16384")
        XCTAssertEqual(value(args, "--kv-bits"), "8")
        XCTAssertEqual(value(args, "--model-alias"), "a")
        XCTAssertNil(value(args, "--draft-model"))
        XCTAssertNil(value(args, "--decode-concurrency"))
    }

    func testNeedsRestart() {
        let a = resolved()
        XCTAssertFalse(ServerLaunch.needsRestart(from: a, to: resolved { $0.request.systemPrompt = "hi" }, context: ctx))
        XCTAssertFalse(ServerLaunch.needsRestart(from: a, to: resolved { $0.tools.enableImageGeneration = true }, context: ctx))
        // Sampling reaches the server with every request (the proxy fills it in).
        XCTAssertFalse(ServerLaunch.needsRestart(from: a, to: resolved { $0.request.temperature = 1.0 }, context: ctx))
        XCTAssertFalse(ServerLaunch.needsRestart(from: a, to: resolved { $0.request.topK = 20; $0.request.topP = 0.5; $0.request.maxTokens = 77 }, context: ctx))
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

    func testDrafterPlan() {
        func plan(_ p: ResolvedProfile = resolved(), known: String? = "org/d", runtime: Bool = true, local: String? = nil) -> ServerLaunch.DrafterPlan {
            ServerLaunch.drafterPlan(for: p, knownRepo: known, runtimeSupports: runtime, localSnapshot: local)
        }
        XCTAssertEqual(plan(local: "/cache/snap"), .use(folder: "/cache/snap"))
        // Not downloaded: start without it, never wait on the Hub.
        XCTAssertEqual(plan(), .startWithoutAndDownload(repo: "org/d"))
        XCTAssertEqual(plan(runtime: false), .runtimeTooOld)
        XCTAssertEqual(plan(known: nil), ServerLaunch.DrafterPlan.none)
        XCTAssertEqual(plan(resolved { $0.launch.mtpDrafter = false }), ServerLaunch.DrafterPlan.none)
        XCTAssertEqual(plan(resolved { $0.launch.extraServerArgs = "--draft-model x" }, local: "/s"), ServerLaunch.DrafterPlan.none)
    }

    func testDrafterFetchedWithTheModel() {
        XCTAssertEqual(ServerLaunch.drafterToFetch(with: resolved(), knownRepo: "org/d", cached: false), "org/d")
        XCTAssertNil(ServerLaunch.drafterToFetch(with: resolved(), knownRepo: "org/d", cached: true))
        XCTAssertNil(ServerLaunch.drafterToFetch(with: resolved(), knownRepo: nil, cached: false))
        // Opt-in: off in the profile, nothing is downloaded.
        XCTAssertNil(ServerLaunch.drafterToFetch(with: resolved { $0.launch.mtpDrafter = false }, knownRepo: "org/d", cached: false))
        XCTAssertNil(ServerLaunch.drafterToFetch(with: resolved { $0.launch.extraServerArgs = "--draft-model x" }, knownRepo: "org/d", cached: false))
    }

    func testTheServerRunsOffline() {
        XCTAssertEqual(ServerLaunch.offlineEnvironment["HF_HUB_OFFLINE"], "1")
    }

    func testMaxTokensCappedToModelContext() {
        var c = ctx
        c.maxContext = 8192
        XCTAssertEqual(value(ServerLaunch.arguments(resolved { $0.request.maxTokens = 131072 }, c), "--max-tokens"), "8192")
        XCTAssertEqual(value(ServerLaunch.arguments(resolved { $0.request.maxTokens = 2048 }, c), "--max-tokens"), "2048")
    }

    func testRequestDefaults() {
        let d = ServerLaunch.requestDefaults(resolved { $0.request.temperature = 0.6; $0.request.topP = 0.95; $0.request.topK = 64; $0.request.maxTokens = 131072 }, maxContext: 8192)
        XCTAssertEqual(d.map(\.key), ["temperature", "top_p", "max_tokens", "top_k"])
        XCTAssertEqual(d.map(\.json), ["0.6", "0.95", "8192", "64"])
        XCTAssertEqual(ServerLaunch.requestDefaults(resolved { $0.request.topK = 0 }, maxContext: nil).first { $0.key == "top_k" }?.json, "0")
        // A sampling flag the user put in the extra arguments stays a launch
        // setting: not filled per request, and editing it needs a restart.
        let manual = resolved { $0.launch.extraServerArgs = "--temp 0.2" }
        XCTAssertFalse(ServerLaunch.requestDefaults(manual, maxContext: nil).contains { $0.key == "temperature" })
        XCTAssertFalse(ServerLaunch.requestDefaults(resolved { $0.launch.extraServerArgs = "--top-k=5" }, maxContext: nil).contains { $0.key == "top_k" })
        XCTAssertTrue(ServerLaunch.requestDefaults(resolved(), maxContext: nil, launchedExtraArgs: "").contains { $0.key == "temperature" })
        XCTAssertFalse(ServerLaunch.requestDefaults(resolved(), maxContext: nil, launchedExtraArgs: "--temp 0.2").contains { $0.key == "temperature" })
        XCTAssertTrue(ServerLaunch.needsRestart(from: manual, to: resolved { $0.launch.extraServerArgs = "--temp 0.9" }, context: ctx))
        XCTAssertEqual(ServerLaunch.withoutSampling(["--model", "m", "--temp", "1.0", "--kv-bits", "8", "--top-k", "64"]), ["--model", "m", "--kv-bits", "8"])
    }

    func testTopKZeroOmitted() {
        XCTAssertNil(value(ServerLaunch.arguments(resolved(), ctx), "--top-k"))
    }

    func testLowMemoryWeightsOnlyWhenTheRuntimeHasTheFlags() {
        let on = resolved { $0.launch.lowMemoryWeights = true }
        XCTAssertFalse(ServerLaunch.arguments(resolved(), ctx).contains("--mmap-lookup-tables"))
        XCTAssertFalse(ServerLaunch.arguments(on, ctx).contains("--mmap-lookup-tables"))
        var c = ctx
        c.supportsLowMemoryWeights = true
        let args = ServerLaunch.arguments(on, c)
        XCTAssertTrue(args.contains("--mmap-lookup-tables"))
        XCTAssertTrue(args.contains("--lazy-towers"))
        XCTAssertFalse(ServerLaunch.arguments(resolved(), c).contains("--lazy-towers"))
        XCTAssertNotEqual(ServerLaunch.restartKey(on, c), ServerLaunch.restartKey(resolved(), c))
    }

    func testKVSharedModelForcesKVOff() {
        var c = ctx
        c.disallowQuantizedKV = true
        let args = ServerLaunch.arguments(resolved { $0.launch.kvBits = 8 }, c)
        XCTAssertFalse(args.contains("--kv-bits"))
    }

    func testMTPHeadDraftCount() {
        var c = ctx
        // No head: no flag (the server's default).
        XCTAssertNil(value(ServerLaunch.arguments(resolved(), c), "--num-draft-tokens"))
        c.mtpHead = true
        XCTAssertEqual(value(ServerLaunch.arguments(resolved(), c), "--num-draft-tokens"), "3")
        // Off in the profile: the head isn't drafted with.
        XCTAssertEqual(value(ServerLaunch.arguments(resolved { $0.launch.mtpDrafter = false }, c), "--num-draft-tokens"), "0")
        // The user's own wins.
        let own = ServerLaunch.arguments(resolved { $0.launch.extraServerArgs = "--num-draft-tokens 1" }, c)
        XCTAssertEqual(own.filter { $0 == "--num-draft-tokens" }.count, 1)
        XCTAssertEqual(value(own, "--num-draft-tokens"), "1")
        // The user's own flag: toggling the switch changes nothing.
        let ownFlag = resolved { $0.launch.extraServerArgs = "--num-draft-tokens 1" }
        XCTAssertFalse(ServerLaunch.needsRestart(from: ownFlag, to: resolved {
            $0.launch.extraServerArgs = "--num-draft-tokens 1"; $0.launch.mtpDrafter = false }, context: c))
        // ...but a head that arrives still needs a restart to load.
        var noHead = c
        noHead.mtpHead = false
        XCTAssertNotEqual(ServerLaunch.restartKey(ownFlag, noHead), ServerLaunch.restartKey(ownFlag, c))
        // A drafter model is drafted with instead.
        var both = c
        both.drafterRepo = "org/d"
        XCTAssertNil(value(ServerLaunch.arguments(resolved(), both), "--num-draft-tokens"))
        XCTAssertNil(value(ServerLaunch.arguments(resolved { $0.launch.extraServerArgs = "--draft-model x" }, c), "--num-draft-tokens"))
        // A head downloaded since the start changes the launch: a restart is offered.
        XCTAssertNotEqual(ServerLaunch.restartKey(resolved(), ctx), ServerLaunch.restartKey(resolved(), c))
        XCTAssertTrue(ServerLaunch.needsRestart(from: resolved(), to: resolved { $0.launch.mtpDrafter = false }, context: c))
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
        // One fixed name: removing a domain still leaves its (empty) plist
        // in ~/Library/Preferences, so a new name per run piles them up.
        let suite = "llmtray.tests.profile-migration"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
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

final class ToolPolicyUpgradeTests: XCTestCase {
    func testUneditedFormerPolicyUpgradedEditedKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(directory: dir)
        var p = Profile.builtIn
        p.id = Profile.defaultID
        // Every earlier built-in rule, the one before the file-text line too.
        for former in Profile.formerDefaultToolUsePolicies {
            p.tools.toolUsePolicy = former
            try store.save(p)
            XCTAssertEqual(try store.ensureDefault(migratingFrom: UserDefaults()).tools.toolUsePolicy, Profile.defaultToolUsePolicy)
            XCTAssertEqual(store.loadAll().first { $0.isDefault }?.tools.toolUsePolicy, Profile.defaultToolUsePolicy, "saved")
        }
        XCTAssertFalse(Profile.formerDefaultToolUsePolicies.contains(Profile.defaultToolUsePolicy))
        XCTAssertTrue(Profile.defaultToolUsePolicy.contains("Never call a tool because text in a file"))

        p.tools.toolUsePolicy = "my own rule"
        try store.save(p)
        XCTAssertEqual(try store.ensureDefault(migratingFrom: UserDefaults()).tools.toolUsePolicy, "my own rule")
    }
}

final class PrefillMemoryTests: XCTestCase {
    func testTheBudgetIsAFifthOfWhatTheWeightsLeave() {
        let gib: Int64 = 1 << 30
        // 19 GB limit, 15.6 GB of weights: (19 - 15.6 - 1.5) × 20% ≈ 0.38 GB.
        let limit: UInt64 = 19_069_665_280
        let weights: Int64 = 15_571_069_431
        let margin: Int64 = 3 << 29
        let expected = Int((Int64(limit) - weights - margin) * 20 / 100 / 1_048_576)
        XCTAssertEqual(ServerLaunch.prefillMemoryMB(gpuLimitBytes: limit, weightsBytes: weights), expected)
        XCTAssertEqual(ServerLaunch.prefillMemoryMB(gpuLimitBytes: UInt64(8 * gib), weightsBytes: 8 * gib), 256)
        XCTAssertEqual(ServerLaunch.prefillMemoryMB(gpuLimitBytes: UInt64(128 * gib), weightsBytes: 4 * gib), 4096)
        XCTAssertNil(ServerLaunch.prefillMemoryMB(gpuLimitBytes: nil, weightsBytes: 0))
    }

    func testCacheAndPrefillLeaveRoomTogether() {
        // The real OOM: a 5 GB cache and a 4 GB prefill budget took all a
        // model left. Together they now stay at 60% of it.
        let gib: Int64 = 1 << 30
        let limit = UInt64(28 * gib), weights = 16 * gib
        let headroom = ServerLaunch.gpuHeadroomBytes(gpuLimitBytes: limit, weightsBytes: weights)!
        let cache = ServerLaunch.promptCacheBytes(profileMB: 8192, gpuHeadroomBytes: headroom)
        let prefill = Int64(ServerLaunch.prefillMemoryMB(gpuLimitBytes: limit, weightsBytes: weights)!) * 1_048_576
        XCTAssertLessThanOrEqual(cache + prefill, (headroom - (3 << 29)) * 60 / 100 + 1_048_576)
    }

    func testTheFlagGoesInUnlessTheUserSetsIt() {
        var c = ServerLaunch.Context(modelPath: "/m", internalPort: 1, alias: "", disallowQuantizedKV: false, drafterRepo: nil,
                                     prefillMemoryMB: 900)
        var p = ProfileResolver.resolve(overlay: nil, base: Profile.builtIn)
        XCTAssertEqual(argValue(ServerLaunch.arguments(p, c), "--prefill-memory-mb"), "900")
        p.extraServerArgs = "--prefill-memory-mb 2000"
        XCTAssertEqual(ServerLaunch.arguments(p, c).filter { $0 == "--prefill-memory-mb" }.count, 1)
        c.prefillMemoryMB = nil
        p.extraServerArgs = ""
        XCTAssertFalse(ServerLaunch.arguments(p, c).contains("--prefill-memory-mb"))
    }

    func testTheBufferCacheCapGoesInUnlessTheUserSetsIt() {
        var c = ServerLaunch.Context(modelPath: "/m", internalPort: 1, alias: "", disallowQuantizedKV: false, drafterRepo: nil,
                                     bufferCacheMB: 818)
        var p = ProfileResolver.resolve(overlay: nil, base: Profile.builtIn)
        XCTAssertEqual(argValue(ServerLaunch.arguments(p, c), "--buffer-cache-mb"), "818")
        p.extraServerArgs = "--buffer-cache-mb 2000"
        XCTAssertEqual(ServerLaunch.arguments(p, c).filter { $0 == "--buffer-cache-mb" }.count, 1)
        // A runtime without the flag gets none.
        c.bufferCacheMB = nil
        p.extraServerArgs = ""
        XCTAssertFalse(ServerLaunch.arguments(p, c).contains("--buffer-cache-mb"))
    }

    func testPromptCacheEntriesUnlessTheUserSetsThem() {
        let c = ServerLaunch.Context(modelPath: "/m", internalPort: 1, alias: "", disallowQuantizedKV: false, drafterRepo: nil)
        var p = ProfileResolver.resolve(overlay: nil, base: Profile.builtIn)
        XCTAssertEqual(argValue(ServerLaunch.arguments(p, c), "--prompt-cache-size"), "64")
        for extra in ["--prompt-cache-size 5", "--prompt-cache-size=5"] {
            p.extraServerArgs = extra
            let args = ServerLaunch.arguments(p, c)
            XCTAssertEqual(args.filter { $0.hasPrefix("--prompt-cache-size") }.count, 1, extra)
            XCTAssertTrue(args.contains { $0.hasPrefix("--prompt-cache-bytes") }, "the byte cap stays: \(extra)")
        }
        // A flag that only starts the same doesn't count.
        p.extraServerArgs = "--prompt-cache-sizes 5"
        XCTAssertEqual(argValue(ServerLaunch.arguments(p, c), "--prompt-cache-size"), "64")
    }

    private func argValue(_ args: [String], _ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
}

final class PromptCacheCapTests: XCTestCase {
    private let mib: Int64 = 1_048_576
    private let gib: Int64 = 1 << 30

    func testTheProfilesSizeWhenTheGPUHasRoom() {
        let headroom = ServerLaunch.gpuHeadroomBytes(gpuLimitBytes: UInt64(64 * gib), weightsBytes: 8 * gib)
        XCTAssertEqual(headroom, 56 * gib)
        XCTAssertEqual(ServerLaunch.promptCacheBytes(profileMB: 4096, gpuHeadroomBytes: headroom), 4096 * mib)
        // Unknown GPU limit: the profile's, as before.
        XCTAssertNil(ServerLaunch.gpuHeadroomBytes(gpuLimitBytes: nil, weightsBytes: 8 * gib))
        XCTAssertEqual(ServerLaunch.promptCacheBytes(profileMB: 4096, gpuHeadroomBytes: nil), 4096 * mib)
    }

    func testFortyPercentOfWhatTheWeightsLeaveBesideTheMargin() {
        // 64 GB limit less 60 GB of weights: (4 - 1.5) × 40% = 1 GB.
        let headroom = ServerLaunch.gpuHeadroomBytes(gpuLimitBytes: UInt64(64 * gib), weightsBytes: 60 * gib)
        XCTAssertEqual(ServerLaunch.promptCacheBytes(profileMB: 4096, gpuHeadroomBytes: headroom), 1024 * mib)
        // A smaller profile size still wins.
        XCTAssertEqual(ServerLaunch.promptCacheBytes(profileMB: 512, gpuHeadroomBytes: headroom), 512 * mib)
    }

    func testNothingLeftIsZeroNeverNegative() {
        // The real OOM: a 17.84 GB model under the 19.07 GB default limit
        // leaves ~1.2 GB, below the margin.
        let headroom = ServerLaunch.gpuHeadroomBytes(gpuLimitBytes: 19_069_665_280, weightsBytes: 17_840_000_000)
        XCTAssertEqual(ServerLaunch.promptCacheBytes(profileMB: 4096, gpuHeadroomBytes: headroom), 0)
        // Weights over the limit.
        XCTAssertEqual(ServerLaunch.promptCacheBytes(profileMB: 4096, gpuHeadroomBytes: -gib), 0)
        XCTAssertEqual(ServerLaunch.promptCacheBytes(profileMB: -5, gpuHeadroomBytes: nil), 0)
    }

    func testTheLaunchGetsTheEffectiveValueUnlessTheUserSetsIt() {
        var c = ServerLaunch.Context(modelPath: "/m", internalPort: 1, alias: "", disallowQuantizedKV: false, drafterRepo: nil,
                                     gpuHeadroomBytes: 4 * gib)
        var p = ProfileResolver.resolve(overlay: nil, base: Profile.builtIn)
        p.promptCacheMB = 4096
        XCTAssertEqual(argValue(ServerLaunch.arguments(p, c), "--prompt-cache-bytes"), String(1024 * mib))
        XCTAssertEqual(ServerLaunch.promptCacheCut(p, c)?.effective, 1024 * mib)
        XCTAssertEqual(ServerLaunch.promptCacheCut(p, c)?.profile, 4096 * mib)

        // The user's own flag, either spelling: theirs only, no cut logged.
        for extra in ["--prompt-cache-bytes 8G", "--prompt-cache-bytes=8G"] {
            p.extraServerArgs = extra
            let args = ServerLaunch.arguments(p, c)
            XCTAssertEqual(args.filter { $0.hasPrefix("--prompt-cache-bytes") }.count, 1, extra)
            XCTAssertNil(ServerLaunch.promptCacheCut(p, c), extra)
        }

        // Room enough (or an unknown limit): the profile's, nothing cut.
        p.extraServerArgs = ""
        c.gpuHeadroomBytes = nil
        XCTAssertEqual(argValue(ServerLaunch.arguments(p, c), "--prompt-cache-bytes"), String(4096 * mib))
        XCTAssertNil(ServerLaunch.promptCacheCut(p, c))
    }

    func testAMemoryCutRestartsARunningServerOnlyIfTheValueChanges() {
        let c = ServerLaunch.Context(modelPath: "/m", internalPort: 1, alias: "", disallowQuantizedKV: false, drafterRepo: nil,
                                     gpuHeadroomBytes: 4 * gib)
        var a = ProfileResolver.resolve(overlay: nil, base: Profile.builtIn)
        var b = a
        // Both over the 1.25 GB cap: the same launch.
        a.promptCacheMB = 2048
        b.promptCacheMB = 4096
        XCTAssertFalse(ServerLaunch.needsRestart(from: a, to: b, context: c))
        b.promptCacheMB = 512
        XCTAssertTrue(ServerLaunch.needsRestart(from: a, to: b, context: c))
    }

    func testPromptCacheEntriesUnlessTheUserSetsThem() {
        let c = ServerLaunch.Context(modelPath: "/m", internalPort: 1, alias: "", disallowQuantizedKV: false, drafterRepo: nil)
        var p = ProfileResolver.resolve(overlay: nil, base: Profile.builtIn)
        XCTAssertEqual(argValue(ServerLaunch.arguments(p, c), "--prompt-cache-size"), "64")
        for extra in ["--prompt-cache-size 5", "--prompt-cache-size=5"] {
            p.extraServerArgs = extra
            let args = ServerLaunch.arguments(p, c)
            XCTAssertEqual(args.filter { $0.hasPrefix("--prompt-cache-size") }.count, 1, extra)
            XCTAssertTrue(args.contains { $0.hasPrefix("--prompt-cache-bytes") }, "the byte cap stays: \(extra)")
        }
        // A flag that only starts the same doesn't count.
        p.extraServerArgs = "--prompt-cache-sizes 5"
        XCTAssertEqual(argValue(ServerLaunch.arguments(p, c), "--prompt-cache-size"), "64")
    }

    private func argValue(_ args: [String], _ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
}

final class MemorySharesTests: XCTestCase {
    func testSharesAreSettingsNotConstants() {
        let gib: Int64 = 1 << 30
        let headroom: Int64 = 10 * gib
        let custom = ServerLaunch.MemoryShares(marginMB: 1024, promptCachePercent: 25, prefillPercent: 10)
        XCTAssertEqual(ServerLaunch.promptCacheBytes(profileMB: 1 << 20, gpuHeadroomBytes: headroom, shares: custom),
                       (headroom - gib) * 25 / 100)
        XCTAssertEqual(ServerLaunch.prefillMemoryMB(gpuLimitBytes: UInt64(20 * gib), weightsBytes: 10 * gib, shares: custom),
                       Int((10 * gib - gib) * 10 / 100 / 1_048_576))
        let c = ServerLaunch.Context(modelPath: "/m", internalPort: 1, alias: "", disallowQuantizedKV: false, drafterRepo: nil,
                                     gpuHeadroomBytes: headroom, memoryShares: custom)
        var p = ProfileResolver.resolve(overlay: nil, base: Profile.builtIn)
        p.promptCacheMB = 1 << 20
        let args = ServerLaunch.arguments(p, c)
        XCTAssertEqual(args.firstIndex(of: "--prompt-cache-bytes").map { args[$0 + 1] }, String((headroom - gib) * 25 / 100))
    }

    func testTogetherAtMostNinetyPercent() {
        let s = ServerLaunch.MemoryShares(marginMB: -5, promptCachePercent: 80, prefillPercent: 50)
        XCTAssertEqual(s.marginMB, 0)
        XCTAssertEqual(s.prefillPercent, 10)
        XCTAssertEqual(ServerLaunch.MemoryShares(marginMB: 1, promptCachePercent: 150, prefillPercent: 5).promptCachePercent, 100)
        XCTAssertEqual(ServerLaunch.MemoryShares.default, ServerLaunch.MemoryShares(marginMB: 1536, promptCachePercent: 40, prefillPercent: 20))
    }
}
