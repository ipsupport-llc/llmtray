import XCTest
@testable import LLMTrayCore

final class VoiceLabTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000

    func testTheDefaultModel() {
        let model = VoiceLabModel.default
        XCTAssertEqual(model.repo, "mlx-community/NemotronLabs-VoiceChat-11B-4bit")
        XCTAssertEqual(model.licenseName, "OpenMDW 1.1")
        XCTAssertEqual(model.cardURL.absoluteString, "https://huggingface.co/" + model.repo)
        XCTAssertGreaterThan(model.footprintBytes, model.downloadBytes)
        XCTAssertEqual(model.downloadFraction(bytesOnDisk: 0), 0)
        XCTAssertEqual(model.downloadFraction(bytesOnDisk: model.downloadBytes / 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(model.downloadFraction(bytesOnDisk: model.downloadBytes * 2), 1)
        XCTAssertEqual(model.downloadFraction(bytesOnDisk: -5), 0)
    }

    func testUnknownLimit() {
        let fit = VoiceMemoryFit(voiceBytes: 15 * gb, chatBytes: 17 * gb, gpuLimitBytes: nil, physicalMemoryBytes: 26 << 30)
        XCTAssertEqual(fit.verdict, .unknown)
        XCTAssertNil(fit.sysctlCommand)
    }

    func testFitsBesideASmallChatModel() {
        // 64 GB Mac, ~48 GB limit: 15.6 + 5 + 1.5 fits.
        let fit = VoiceMemoryFit(voiceBytes: 15_600_000_000, chatBytes: 5 * gb, gpuLimitBytes: 48 * 1 << 30, physicalMemoryBytes: 64 << 30)
        XCTAssertEqual(fit.verdict, .fitsBesideChat)
    }

    func testOnlyAloneOnThe26GBMac() {
        // The 26 GB M5 with its default 19.07 GB limit and Gemma 26B's 17.8 GB.
        let limit = UInt64(19.07 * 1_073_741_824)
        let fit = VoiceMemoryFit(voiceBytes: 15_600_000_000, chatBytes: 17_800_000_000, gpuLimitBytes: limit, physicalMemoryBytes: 26 << 30)
        XCTAssertEqual(fit.verdict, .fitsAlone)
        XCTAssertNil(fit.sysctlCommand)
    }

    func testNoChatModelFitsBeside() {
        let fit = VoiceMemoryFit(voiceBytes: 15 * gb, chatBytes: nil, gpuLimitBytes: 20 << 30, physicalMemoryBytes: 26 << 30)
        XCTAssertEqual(fit.verdict, .fitsBesideChat)
        XCTAssertNil(fit.chatBytes)
        // A folder with no weights read counts as none.
        XCTAssertNil(VoiceMemoryFit(voiceBytes: 15 * gb, chatBytes: 0, gpuLimitBytes: 20 << 30, physicalMemoryBytes: 26 << 30).chatBytes)
    }

    func testTooBigSuggestsARaiseWhenRAMAllows() {
        // 24 GB Mac, 16 GB limit: 15.6 + 1.5 GB doesn't fit; 24 GB - 4 GB could.
        let fit = VoiceMemoryFit(voiceBytes: 15_600_000_000, chatBytes: 8 * gb, gpuLimitBytes: 16 << 30, physicalMemoryBytes: 24 << 30)
        XCTAssertEqual(fit.verdict, .tooBig)
        let mb = Int((15_600_000_000 + Int64(VoiceMemoryFit.marginBytes) + 1_048_575) / 1_048_576)
        XCTAssertEqual(fit.suggestedWiredLimitMB, mb)
        XCTAssertEqual(fit.sysctlCommand, "sudo sysctl iogpu.wired_limit_mb=\(mb)")
    }

    func testTooBigWithoutEnoughRAM() {
        // 16 GB Mac: even all of it less 4 GB isn't enough.
        let fit = VoiceMemoryFit(voiceBytes: 15_600_000_000, chatBytes: nil, gpuLimitBytes: 11 << 30, physicalMemoryBytes: 16 << 30)
        XCTAssertEqual(fit.verdict, .tooBig)
        XCTAssertNil(fit.suggestedWiredLimitMB)
    }
}
