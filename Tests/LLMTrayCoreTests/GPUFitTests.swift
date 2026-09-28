import XCTest
@testable import LLMTrayCore

final class GPUFitTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    func testAModelThatBarelyFitsGetsTheNoticeAndASuggestedLimit() throws {
        // The real OOM: 17.84 GB of weights, 19.07 GB default limit, 24 GB Mac.
        let mac = HardwareInfo(physicalMemoryBytes: 24 * gib, gpuWorkingSetBytes: 19_069_665_280, wiredLimitMB: 0)
        let fit = try XCTUnwrap(GPUFit(weightsBytes: 17_840_000_000, hardware: mac))
        XCTAssertEqual(GPUFit.gigabytes(fit.weightsBytes), "17.8")
        XCTAssertEqual(GPUFit.gigabytes(Int64(fit.gpuLimitBytes)), "19.1")
        // min(24 GB - 4 GB, weights + 6 GB): the RAM bound.
        XCTAssertEqual(fit.suggestedWiredLimitMB, 20480)
        XCTAssertEqual(fit.sysctlCommand, "sudo sysctl iogpu.wired_limit_mb=20480")
    }

    func testTheSuggestionIsTheWeightsAndSixGBOnABigMac() throws {
        let mac = HardwareInfo(physicalMemoryBytes: 64 * gib, gpuWorkingSetBytes: 48 * gib, wiredLimitMB: 0)
        let weights = Int64(47 * gib)
        let fit = try XCTUnwrap(GPUFit(weightsBytes: weights, hardware: mac))
        XCTAssertEqual(fit.suggestedWiredLimitMB, 47 * 1024 + 6144)
    }

    func testRoomEnoughOrUnknownIsNoNotice() {
        let mac = HardwareInfo(physicalMemoryBytes: 24 * gib, gpuWorkingSetBytes: 19_069_665_280, wiredLimitMB: 0)
        XCTAssertNil(GPUFit(weightsBytes: 15_000_000_000, hardware: mac), "4 GB left")
        XCTAssertNil(GPUFit(weightsBytes: 0, hardware: mac), "size not known yet")
        XCTAssertNil(GPUFit(weightsBytes: 17_840_000_000, hardware: HardwareInfo(physicalMemoryBytes: 24 * gib)), "no GPU limit")
    }

    func testARaisedLimitCounts() {
        // The user already raised it to 22 GB: 4 GB left, no notice.
        let raised = HardwareInfo(physicalMemoryBytes: 24 * gib, gpuWorkingSetBytes: 19_069_665_280, wiredLimitMB: 22 * 1024)
        XCTAssertNil(GPUFit(weightsBytes: 17_840_000_000, hardware: raised))
    }

    func testNoSuggestionWhenItWouldntRaiseTheLimit() throws {
        // A 16 GB Mac already at 12 GB: RAM less 4 GB is no higher.
        let mac = HardwareInfo(physicalMemoryBytes: 16 * gib, gpuWorkingSetBytes: 12 * gib, wiredLimitMB: 0)
        let fit = try XCTUnwrap(GPUFit(weightsBytes: Int64(11 * gib), hardware: mac))
        XCTAssertNil(fit.suggestedWiredLimitMB)
        XCTAssertNil(fit.sysctlCommand)
    }
}
