import XCTest
@testable import LLMTrayCore

final class ModelRecommendationsTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    /// A Mac with `gb` of RAM and Metal's usual working set for it (about
    /// two thirds below 36 GB, three quarters from there).
    private func mac(_ gb: UInt64, workingSet: UInt64? = nil, wiredMB: Int64? = 0) -> HardwareInfo {
        let memory = gb * gib
        return HardwareInfo(physicalMemoryBytes: memory,
                            gpuWorkingSetBytes: workingSet ?? (gb >= 36 ? memory / 4 * 3 : memory / 3 * 2),
                            wiredLimitMB: wiredMB)
    }

    /// The shipped list.
    private func shipped() throws -> [RecommendedModel] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runtime").appendingPathComponent(ModelRecommendations.fileName)
        return try ModelRecommendations.load(contentsOf: url)
    }

    private func repos(_ picks: [ModelRecommendations.Pick]) -> [String] { picks.map(\.model.repo) }

    private func model(_ repo: String, gb: Double, min: Int, recommendedFor: [Int] = [],
                       capabilities: [RecommendedModel.Capability] = []) -> RecommendedModel {
        RecommendedModel(repo: repo, title: repo, summary: "", capabilities: capabilities, approxBytes: Int64(gb * 1e9),
                         minMemoryGB: min, recommendedFor: recommendedFor)
    }

    private func roles(_ picks: [ModelRecommendations.Pick]) -> [String: ModelRecommendations.Pick.Role] {
        Dictionary(uniqueKeysWithValues: picks.map { ($0.model.repo, $0.role) })
    }

    func testTiers() {
        XCTAssertEqual(MemoryTier.tier(physicalMemoryBytes: 8 * gib), 8)
        XCTAssertEqual(MemoryTier.tier(physicalMemoryBytes: 16 * gib), 16)
        XCTAssertEqual(MemoryTier.tier(physicalMemoryBytes: 18 * gib), 16)
        XCTAssertEqual(MemoryTier.tier(physicalMemoryBytes: 24 * gib), 24)
        XCTAssertEqual(MemoryTier.tier(physicalMemoryBytes: 28 * gib), 24)
        XCTAssertEqual(MemoryTier.tier(physicalMemoryBytes: 32 * gib), 32)
        XCTAssertEqual(MemoryTier.tier(physicalMemoryBytes: 128 * gib), 32)
    }

    /// The ladder: a bigger Mac sees the smaller models too, its
    /// recommended one first, then the general ones from the biggest down,
    /// then the ones for code.
    func testLadderAndOrder() {
        let list = [
            model("a/small", gb: 3, min: 8, recommendedFor: [8]),
            model("a/code", gb: 4, min: 8, capabilities: [.code]),
            model("a/mid", gb: 7, min: 16, recommendedFor: [16]),
            model("a/big", gb: 15.6, min: 24, recommendedFor: [24, 32]),
            model("a/dense", gb: 18, min: 32),
        ]
        XCTAssertEqual(repos(ModelRecommendations.picks(from: list, for: mac(8))), ["a/small", "a/code"])
        XCTAssertEqual(repos(ModelRecommendations.picks(from: list, for: mac(16))), ["a/mid", "a/small", "a/code"])
        XCTAssertEqual(repos(ModelRecommendations.picks(from: list, for: mac(24))), ["a/big", "a/mid", "a/small", "a/code"])
        XCTAssertEqual(repos(ModelRecommendations.picks(from: list, for: mac(64))), ["a/big", "a/dense", "a/mid", "a/small", "a/code"])
        // An 18 GB Mac is in the 16 tier.
        XCTAssertEqual(repos(ModelRecommendations.picks(from: list, for: mac(18))), ["a/mid", "a/small", "a/code"])
    }

    func testRoles() {
        let list = [
            model("a/small", gb: 3, min: 8, recommendedFor: [8]),
            model("a/code", gb: 4, min: 8, capabilities: [.code]),
            model("a/big", gb: 15.6, min: 24, recommendedFor: [24, 32]),
            model("a/dense", gb: 18, min: 32),
        ]
        XCTAssertEqual(roles(ModelRecommendations.picks(from: list, for: mac(64))),
                       ["a/big": .recommended, "a/dense": .larger, "a/small": .lighter, "a/code": .forCode])
        XCTAssertEqual(roles(ModelRecommendations.picks(from: list, for: mac(8))), ["a/small": .recommended, "a/code": .forCode])
        // The recommended one doesn't fit this GPU: nothing to compare with.
        let noRec = ModelRecommendations.picks(from: list, for: mac(24, workingSet: 10 * gib))
        XCTAssertEqual(roles(noRec)["a/small"], .alternative)
        XCTAssertNil(roles(noRec)["a/big"])
    }

    func testMinimumMemory() {
        let list = [model("a/needs20", gb: 3, min: 20)]
        XCTAssertTrue(ModelRecommendations.picks(from: list, for: mac(16)).isEmpty)
        XCTAssertEqual(repos(ModelRecommendations.picks(from: list, for: mac(18))), [], "18 < 20")
    }

    func testFitAndGPULimit() {
        let big = model("a/big", gb: 15.6, min: 24)
        let picks = ModelRecommendations.picks(from: [big], for: mac(24))
        XCTAssertEqual(picks.first?.fit, .tight, "15.6 GB of 24 GiB: the browser's tight")
        XCTAssertEqual(picks.first?.sizeBytes, big.approxBytes)
        // The GPU may keep less than the weights: not offered.
        XCTAssertTrue(ModelRecommendations.picks(from: [big], for: mac(24, workingSet: 14 * gib)).isEmpty)
        // A wired limit the user raised counts instead of the working set.
        XCTAssertEqual(ModelRecommendations.picks(from: [big], for: mac(24, workingSet: 14 * gib, wiredMB: 20 * 1024)).count, 1)
        // No Metal device (a VM): only the memory estimate.
        XCTAssertEqual(ModelRecommendations.picks(from: [big], for: HardwareInfo(physicalMemoryBytes: 24 * gib)).count, 1)
        // "unlikely" by the estimate is left out even if the GPU limit allows it.
        let huge = model("a/huge", gb: 19, min: 24)
        XCTAssertTrue(ModelRecommendations.picks(from: [huge], for: mac(24, workingSet: 22 * gib)).isEmpty)
    }

    func testLiveSizes() {
        let m = model("a/m", gb: 3, min: 8)
        let picks = ModelRecommendations.picks(from: [m], for: mac(8), liveSizes: ["a/m": 3_500_000_000])
        XCTAssertEqual(picks.first?.sizeBytes, 3_500_000_000)
        XCTAssertTrue(ModelRecommendations.picks(from: [m], for: mac(8), liveSizes: ["a/m": 7_000_000_000]).isEmpty,
                      "grown past what fits")
    }

    func testParseIsLenient() throws {
        let json = #"""
        {"version": 2, "future": true, "models": [
          {"repo": "a/ok", "title": "OK", "summary": "Fine.", "capabilities": ["vision", "telepathy"],
           "approxBytes": 100, "newField": 1},
          {"repo": "a/old", "title": "Old", "approxBytes": 100, "recommended": true, "tiers": [8, 16]},
          {"repo": "no-slash", "title": "Bad", "approxBytes": 100},
          {"repo": "a/nosize", "title": "Bad"},
          {"repo": "a/", "title": "Bad", "approxBytes": 100}
        ]}
        """#
        let models = try ModelRecommendations.parse(Data(json.utf8))
        XCTAssertEqual(models.map(\.repo), ["a/ok", "a/old"])
        XCTAssertEqual(models.first?.capabilities, [.vision], "an unknown capability is dropped")
        XCTAssertEqual(models.first?.recommendedFor, [])
        XCTAssertEqual(models.last?.recommendedFor, [8, 16], "a list from before the ladder")
        XCTAssertEqual(models.first?.gated, false)
        XCTAssertEqual(models.first?.minMemoryGB, 0)
        XCTAssertThrowsError(try ModelRecommendations.parse(Data("[]".utf8)))
    }

    // MARK: - The shipped list

    func testShippedListIsWellFormed() throws {
        let models = try shipped()
        XCTAssertGreaterThanOrEqual(models.count, 5)
        XCTAssertEqual(Set(models.map(\.repo)).count, models.count, "no repo twice")
        for m in models {
            XCTAssertFalse(m.gated, "\(m.repo): the wizard downloads without a token")
            XCTAssertTrue(m.recommendedFor.allSatisfy(MemoryTier.all.contains), m.repo)
            XCTAssertTrue(m.recommendedFor.allSatisfy { $0 >= m.minMemoryGB }, "\(m.repo): recommended below its minimum")
            XCTAssertFalse(m.summary.isEmpty, m.repo)
            XCTAssertTrue(m.summary.hasSuffix("."), "\(m.repo): a sentence")
            XCTAssertEqual(m.summary.filter { $0 == "." }.count, 1, "\(m.repo): one sentence")
            XCTAssertFalse(m.summary.contains("!"), m.repo)
            XCTAssertNotNil(m.license, m.repo)
            XCTAssertFalse(m.languages.isEmpty, m.repo)
        }
        for tier in MemoryTier.all {
            XCTAssertEqual(models.filter { $0.recommendedFor.contains(tier) }.count, 1, "one recommended model in tier \(tier)")
        }
    }

    /// The user's decision (adr/0013): our own GPTQ checkpoints lead.
    func testShippedListLeadsWithOurGemmas() throws {
        let models = try shipped()
        let big = "roman220220/gemma-4-26B-A4B-it-gptq-mlx-jang"
        let small = "roman220220/gemma-4-E4B-it-qat-mlx"
        XCTAssertEqual(ModelRecommendations.picks(from: models, for: mac(16)).first?.model.repo, small)
        XCTAssertEqual(ModelRecommendations.picks(from: models, for: mac(18)).first?.model.repo, small)
        XCTAssertEqual(ModelRecommendations.picks(from: models, for: mac(24)).first?.model.repo, big)
        XCTAssertEqual(ModelRecommendations.picks(from: models, for: mac(36)).first?.model.repo, big)
        XCTAssertEqual(ModelRecommendations.picks(from: models, for: mac(128)).first?.model.repo, big)
        XCTAssertEqual(ModelRecommendations.picks(from: models, for: mac(24)).first?.role, .recommended)
        // The ladder: a 24 GB Mac may still pick the smallest.
        XCTAssertTrue(repos(ModelRecommendations.picks(from: models, for: mac(24))).contains("roman220220/gemma-4-E2B-it-qat-mlx"))
        // The phone build: offered from 8 GB, as lighter than the 8 GB pick.
        let phone = "roman220220/gemma-4-E2B-it-qat-phone-mlx"
        XCTAssertEqual(ModelRecommendations.picks(from: models, for: mac(8)).first { $0.model.repo == phone }?.role, .lighter)
        // The dense 12B: bigger than a 16 GB Mac's pick, lighter than 24's.
        let twelve = "roman220220/gemma-4-12B-it-qat-mlx"
        XCTAssertEqual(ModelRecommendations.picks(from: models, for: mac(16)).first { $0.model.repo == twelve }?.role, .larger)
        XCTAssertEqual(ModelRecommendations.picks(from: models, for: mac(24)).first { $0.model.repo == twelve }?.role, .lighter)
        XCTAssertFalse(repos(ModelRecommendations.picks(from: models, for: mac(8))).contains(twelve))
        // Our 31B fits a 32 GB Mac's GPU limit.
        XCTAssertTrue(repos(ModelRecommendations.picks(from: models, for: mac(32))).contains("roman220220/gemma-4-31B-it-qat-mlx"))
        XCTAssertFalse(repos(ModelRecommendations.picks(from: models, for: mac(24))).contains("roman220220/gemma-4-31B-it-qat-mlx"))
        // Every tier offers something on a typical Mac of it.
        for gb: UInt64 in [8, 16, 24, 32, 64] {
            let picks = ModelRecommendations.picks(from: models, for: mac(gb))
            XCTAssertFalse(picks.isEmpty, "\(gb) GB")
            XCTAssertTrue(picks.allSatisfy { $0.fit != .unlikely })
        }
    }
}

/// A pick already in the models folder isn't offered for download again.
extension ModelRecommendationsTests {
    private func pick(_ repo: String, recommended: Bool = false) -> ModelRecommendations.Pick {
        ModelRecommendations.Pick(model: model(repo, gb: 3, min: 8), sizeBytes: 3_000_000_000, fit: .fits,
                                  role: recommended ? .recommended : .alternative)
    }

    func testLocalPathMatchesTheRepoCaseInsensitively() {
        let paths = ["/m/lmstudio-community/Other", "/m/Roman220220/Gemma-4-26B-A4B-it-gptq-mlx-jang"]
        XCTAssertEqual(ModelRecommendations.localPath(of: "roman220220/gemma-4-26B-A4B-it-gptq-mlx-jang", in: paths), paths[1])
        XCTAssertNil(ModelRecommendations.localPath(of: "roman220220/gemma-4-26B-A4B-it-gptq-mlx", in: paths), "a prefix isn't it")
        XCTAssertNil(ModelRecommendations.localPath(of: "x/gemma-4-26B-A4B-it-gptq-mlx-jang", in: paths), "another org")
        XCTAssertNil(ModelRecommendations.localPath(of: "man220220/gemma-4-26B-A4B-it-gptq-mlx-jang", in: paths), "whole components")
    }

    func testCapabilitiesOfALocalModel() {
        let list = [RecommendedModel(repo: "o/coder", title: "Coder", summary: "", capabilities: [.code, .tools],
                                     approxBytes: 1, minMemoryGB: 8)]
        XCTAssertEqual(ModelRecommendations.capabilities(ofLocalPath: "/m/O/Coder", in: list, vision: false), [.tools, .code],
                       "the list's, in its order")
        XCTAssertEqual(ModelRecommendations.capabilities(ofLocalPath: "/m/o/coder", in: list, vision: true), [.vision, .tools, .code])
        XCTAssertEqual(ModelRecommendations.capabilities(ofLocalPath: "/m/x/other", in: list, vision: true), [.vision],
                       "one the list doesn't know: only what its config says")
        XCTAssertEqual(ModelRecommendations.capabilities(ofLocalPath: "/m/x/other", in: list, vision: false), [])
        // Audio from the config, in the list's order (after vision)...
        XCTAssertEqual(ModelRecommendations.capabilities(ofLocalPath: "/m/o/coder", in: list, vision: true, audio: true), [.vision, .audio, .tools, .code])
        // ...and only from it: a listed audio model converted text-only hears nothing.
        let listedAudio = [model("o/talker", gb: 3, min: 8, capabilities: [.vision, .audio])]
        XCTAssertEqual(ModelRecommendations.capabilities(ofLocalPath: "/m/o/talker", in: listedAudio, vision: true, audio: false), [.vision])
    }

    func testOfferMovesCompleteLocalCopiesOutOfDownloads() {
        let picks = [pick("o/rec", recommended: true), pick("o/partial"), pick("o/plain"), pick("o/missing")]
        let local = ["/m/a/first", "/m/o/plain", "/m/o/partial", "/m/O/Rec"]
        let offer = ModelRecommendations.offer(picks, localPaths: local, isComplete: { $0 != "/m/o/partial" })
        XCTAssertEqual(repos(offer.downloads), ["o/partial", "o/missing"], "an incomplete copy resumes")
        XCTAssertEqual(offer.local["/m/O/Rec"]?.model.repo, "o/rec")
        XCTAssertEqual(offer.local["/m/o/plain"]?.model.repo, "o/plain")
        XCTAssertTrue(offer.isRecommended(localPath: "/m/O/Rec"))
        XCTAssertFalse(offer.isRecommended(localPath: "/m/o/plain"), "the badge is the recommended picks'")
        XCTAssertEqual(offer.ordered(local, path: { $0 }), ["/m/O/Rec", "/m/a/first", "/m/o/plain", "/m/o/partial"])
    }

    func testModelFolderCompleteness() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("llmtray-models-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: dir) }
        func folder(_ name: String, _ files: [String: String]) throws -> String {
            let path = dir + "/" + name
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            for (file, text) in files { fm.createFile(atPath: path + "/" + file, contents: Data(text.utf8)) }
            return path
        }
        let index = #"{"weight_map": {"a": "model-1.safetensors", "b": "model-2.safetensors"}}"#
        XCTAssertTrue(ModelFolder.isComplete(atPath: try folder("done", [ModelFolder.completionMarkerName: "", ModelFolder.manifestName: "{}"])))
        XCTAssertFalse(ModelFolder.isComplete(atPath: try folder("downloading", [ModelFolder.manifestName: "{}", "config.json": "{}",
                                                                                "model.safetensors": ""])), "our download, not finished")
        XCTAssertTrue(ModelFolder.isComplete(atPath: try folder("foreign", ["config.json": "{}", "model.safetensors": ""])))
        XCTAssertFalse(ModelFolder.isComplete(atPath: try folder("configOnly", ["config.json": "{}"])))
        XCTAssertFalse(ModelFolder.isComplete(atPath: try folder("noConfig", ["model.safetensors": ""])))
        XCTAssertFalse(ModelFolder.isComplete(atPath: try folder("shardMissing", ["config.json": "{}", "model.safetensors.index.json": index,
                                                                                 "model-1.safetensors": ""])))
        XCTAssertTrue(ModelFolder.isComplete(atPath: try folder("sharded", ["config.json": "{}", "model.safetensors.index.json": index,
                                                                           "model-1.safetensors": "", "model-2.safetensors": ""])))
    }
}
