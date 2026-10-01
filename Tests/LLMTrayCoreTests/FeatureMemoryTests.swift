import XCTest
@testable import LLMTrayCore

final class FeatureMemoryTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    /// The measuring Mac: 24 GB, Metal's default 19.07 GB limit.
    private var m5: HardwareInfo { HardwareInfo(physicalMemoryBytes: 24 * gib, gpuWorkingSetBytes: 19_069_665_280, wiredLimitMB: 0) }

    /// A Mac with `gb` of RAM and Metal's usual two thirds of it.
    private func mac(_ gb: UInt64) -> HardwareInfo {
        HardwareInfo(physicalMemoryBytes: gb * gib, gpuWorkingSetBytes: gb * gib / 3 * 2, wiredLimitMB: 0)
    }

    private func shipped() throws -> FeatureMemory {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runtime").appendingPathComponent(FeatureMemory.fileName)
        return try FeatureMemory.load(contentsOf: url)
    }

    func testUnderTheGPULimitFits() {
        let fit = FeatureFit(peakBytes: 7_773_890_806, hardware: m5)
        XCTAssertEqual(fit.level, .fits)
        XCTAssertTrue(fit.isAvailable)
        XCTAssertNil(fit.reason)
    }

    func testOverTheLimitButWithinTheRAMIsTight() {
        // Z-Image's 19.69 GB peak ran on the 24 GB Mac over its 17.76 GB limit.
        let fit = FeatureFit(peakBytes: 21_141_976_515, hardware: m5)
        XCTAssertEqual(fit.level, .tight)
        XCTAssertTrue(fit.isAvailable)
        XCTAssertEqual(fit.reason, "Needs about 20 GB, more than the 17.8 GB the GPU may use: it may run out of memory with other apps open.")
    }

    func testOverTheRAMLessMacOSDoesntFit() {
        let fit = FeatureFit(peakBytes: 21_141_976_515, hardware: mac(16))
        XCTAssertEqual(fit.level, .doesNotFit)
        XCTAssertFalse(fit.isAvailable)
        XCTAssertEqual(fit.reason, "Needs about 20 GB; this Mac has 16 GB.")
    }

    func testARaisedLimitCounts() {
        let raised = HardwareInfo(physicalMemoryBytes: 24 * gib, gpuWorkingSetBytes: 19_069_665_280, wiredLimitMB: 20480)
        XCTAssertEqual(FeatureFit(peakBytes: 21_141_976_515, hardware: raised).level, .fits)
        // Raised past RAM less 4 GB: the limit is the ceiling then.
        let high = HardwareInfo(physicalMemoryBytes: 24 * gib, gpuWorkingSetBytes: 19_069_665_280, wiredLimitMB: 22528)
        XCTAssertEqual(FeatureFit(peakBytes: Int64(21 * gib), hardware: high).level, .fits)
    }

    func testWithoutAGPULimitOnlyTheRAMCounts() {
        let noGPU = HardwareInfo(physicalMemoryBytes: 16 * gib)
        XCTAssertEqual(FeatureFit(peakBytes: Int64(11 * gib), hardware: noGPU).level, .fits)
        XCTAssertEqual(FeatureFit(peakBytes: Int64(13 * gib), hardware: noGPU).level, .doesNotFit)
    }

    func testAFeaturesPeakIsItsHighestCase() throws {
        let table = FeatureMemory(cases: [
            FeatureMemoryCase(name: "music-turbo-30s", feature: "music.turbo", peakBytes: 7),
            FeatureMemoryCase(name: "music-turbo-120s", feature: "music.turbo", peakBytes: 9),
        ])
        XCTAssertEqual(table.peakBytes("music.turbo"), 9)
        XCTAssertNil(table.peakBytes("music.sft8bit"))
        XCTAssertNil(table.fit("music.sft8bit", on: m5), "not measured: not gated")
    }

    func testABrokenEntryDropsOnlyItself() throws {
        let json = #"{"cases": [{"case": "a", "feature": "image.x", "peakBytes": 5}, {"case": "b", "feature": "image.y"}, {"case": "c", "feature": "image.z", "peakBytes": 0}]}"#
        let table = try FeatureMemory.parse(Data(json.utf8))
        XCTAssertEqual(table.cases.map(\.name), ["a"])
    }

    /// The shipped table covers every heavy model, and the measuring Mac
    /// can run each of them (they ran there).
    func testTheShippedTable() throws {
        let table = try shipped()
        let features = ["gptq8bit", "gptq4bit", "gptqMixed", "klein4b"].map(FeatureMemory.image)
            + [FeatureMemory.imageEdit("klein4b")]
            + ["turbo", "sftGPTQ4", "sft8bit", "sftBF16"].map(FeatureMemory.music)
        for feature in features {
            XCTAssertNotNil(table.peakBytes(feature), feature)
        }
        for model in [VoiceLabModel.voiceChat11BGPTQ3, .voiceChat11BMixed] {
            XCTAssertNotNil(table.peakBytes(FeatureMemory.voice(model.id)), model.id)
        }
        for c in table.cases where c.estimatedFrom == nil {
            XCTAssertNotEqual(table.fit(c.feature, on: m5)?.level, .doesNotFit, c.name)
        }
        // Estimates name a measured case.
        let measured = Set(table.cases.filter { $0.estimatedFrom == nil }.map(\.name))
        for c in table.cases {
            if let from = c.estimatedFrom { XCTAssertTrue(measured.contains(from), c.feature) }
        }
    }

    func testWhatA16GBMacGets() throws {
        let table = try shipped()
        let mac16 = mac(16)
        // Z-Image and klein's edits need more; klein generates, music runs.
        XCTAssertEqual(table.fit(FeatureMemory.image("gptqMixed"), on: mac16)?.level, .doesNotFit)
        XCTAssertEqual(table.fit(FeatureMemory.imageEdit("klein4b"), on: mac16)?.level, .doesNotFit)
        XCTAssertEqual(table.fit(FeatureMemory.image("klein4b"), on: mac16)?.level, .tight)
        XCTAssertEqual(table.fit(FeatureMemory.music("turbo"), on: mac16)?.level, .fits)
        // 8 GB: no music either.
        XCTAssertEqual(table.fit(FeatureMemory.music("sftGPTQ4"), on: mac(8))?.level, .doesNotFit)
    }
}
