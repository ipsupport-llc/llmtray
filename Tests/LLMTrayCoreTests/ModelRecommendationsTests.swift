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

    private func model(_ repo: String, gb: Double, min: Int, tiers: [Int], recommended: Bool = false) -> RecommendedModel {
        RecommendedModel(repo: repo, title: repo, summary: "", approxBytes: Int64(gb * 1e9), minMemoryGB: min,
                         recommended: recommended, tiers: tiers)
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

    func testFilterAndOrder() {
        let list = [
            model("a/small", gb: 3, min: 8, tiers: [8, 16]),
            model("a/mid", gb: 7, min: 16, tiers: [16], recommended: true),
            model("a/big", gb: 15.6, min: 24, tiers: [24, 32], recommended: true),
            model("a/other", gb: 13, min: 24, tiers: [24, 32]),
        ]
        XCTAssertEqual(repos(ModelRecommendations.picks(from: list, for: mac(8))), ["a/small"])
        XCTAssertEqual(repos(ModelRecommendations.picks(from: list, for: mac(16))), ["a/mid", "a/small"], "recommended first")
        XCTAssertEqual(repos(ModelRecommendations.picks(from: list, for: mac(24))), ["a/big", "a/other"])
        XCTAssertEqual(repos(ModelRecommendations.picks(from: list, for: mac(64))), ["a/big", "a/other"])
        // An 18 GB Mac is in the 16 tier, but has the memory.
        XCTAssertEqual(repos(ModelRecommendations.picks(from: list, for: mac(18))), ["a/mid", "a/small"])
    }

    func testMinimumMemory() {
        let list = [model("a/needs20", gb: 3, min: 20, tiers: [16])]
        XCTAssertTrue(ModelRecommendations.picks(from: list, for: mac(16)).isEmpty)
        XCTAssertEqual(repos(ModelRecommendations.picks(from: list, for: mac(18))), [], "18 < 20")
    }

    func testFitAndGPULimit() {
        let big = model("a/big", gb: 15.6, min: 24, tiers: [24])
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
        let huge = model("a/huge", gb: 19, min: 24, tiers: [24])
        XCTAssertTrue(ModelRecommendations.picks(from: [huge], for: mac(24, workingSet: 22 * gib)).isEmpty)
    }

    func testLiveSizes() {
        let m = model("a/m", gb: 3, min: 8, tiers: [8])
        let picks = ModelRecommendations.picks(from: [m], for: mac(8), liveSizes: ["a/m": 3_500_000_000])
        XCTAssertEqual(picks.first?.sizeBytes, 3_500_000_000)
        XCTAssertTrue(ModelRecommendations.picks(from: [m], for: mac(8), liveSizes: ["a/m": 7_000_000_000]).isEmpty,
                      "grown past what fits")
    }

    func testParseIsLenient() throws {
        let json = #"""
        {"version": 2, "future": true, "models": [
          {"repo": "a/ok", "title": "OK", "summary": "Fine.", "capabilities": ["vision", "telepathy"],
           "approxBytes": 100, "tiers": [8], "newField": 1},
          {"repo": "no-slash", "title": "Bad", "approxBytes": 100, "tiers": [8]},
          {"repo": "a/nosize", "title": "Bad", "tiers": [8]},
          {"repo": "a/notiers", "title": "Bad", "approxBytes": 100, "tiers": []},
          {"repo": "a/", "title": "Bad", "approxBytes": 100, "tiers": [8]}
        ]}
        """#
        let models = try ModelRecommendations.parse(Data(json.utf8))
        XCTAssertEqual(models.map(\.repo), ["a/ok"])
        XCTAssertEqual(models.first?.capabilities, [.vision], "an unknown capability is dropped")
        XCTAssertEqual(models.first?.recommended, false)
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
            XCTAssertTrue(m.tiers.allSatisfy(MemoryTier.all.contains), m.repo)
            XCTAssertTrue(m.tiers.allSatisfy { $0 >= m.minMemoryGB || $0 == 32 }, "\(m.repo): offered below its minimum")
            XCTAssertFalse(m.summary.isEmpty, m.repo)
            XCTAssertTrue(m.summary.hasSuffix("."), "\(m.repo): a sentence")
            XCTAssertEqual(m.summary.filter { $0 == "." }.count, 1, "\(m.repo): one sentence")
            XCTAssertFalse(m.summary.contains("!"), m.repo)
            XCTAssertNotNil(m.license, m.repo)
            XCTAssertFalse(m.languages.isEmpty, m.repo)
        }
        for tier in MemoryTier.all {
            let offered = models.filter { $0.tiers.contains(tier) }
            XCTAssertFalse(offered.isEmpty, "tier \(tier)")
            XCTAssertEqual(offered.filter(\.recommended).count, 1, "one recommended model in tier \(tier)")
        }
    }

    /// The user's decision (adr/0013): our own GPTQ checkpoints lead.
    func testShippedListLeadsWithOurGemmas() throws {
        let models = try shipped()
        let big = "roman220220/gemma-4-26B-A4B-it-gptq-mlx-jang"
        let small = "roman220220/gemma-4-E4B-it-gptq-mlx-jang"
        XCTAssertEqual(ModelRecommendations.picks(from: models, for: mac(16)).first?.model.repo, small)
        XCTAssertEqual(ModelRecommendations.picks(from: models, for: mac(18)).first?.model.repo, small)
        XCTAssertEqual(ModelRecommendations.picks(from: models, for: mac(24)).first?.model.repo, big)
        XCTAssertEqual(ModelRecommendations.picks(from: models, for: mac(36)).first?.model.repo, big)
        XCTAssertEqual(ModelRecommendations.picks(from: models, for: mac(128)).first?.model.repo, big)
        XCTAssertTrue(ModelRecommendations.picks(from: models, for: mac(24)).first?.model.recommended == true)
        // Every tier offers something on a typical Mac of it.
        for gb: UInt64 in [8, 16, 24, 32, 64] {
            let picks = ModelRecommendations.picks(from: models, for: mac(gb))
            XCTAssertFalse(picks.isEmpty, "\(gb) GB")
            XCTAssertTrue(picks.allSatisfy { $0.fit != .unlikely })
        }
    }
}
