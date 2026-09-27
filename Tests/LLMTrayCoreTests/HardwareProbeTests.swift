import XCTest
@testable import LLMTrayCore

final class HardwareProbeTests: XCTestCase {
    func testReadsThisMac() {
        let info = HardwareProbe.current()
        XCTAssertGreaterThan(info.physicalMemoryBytes, 0)
        XCTAssertEqual(info.physicalMemoryBytes, ProcessInfo.processInfo.physicalMemory)
        XCTAssertFalse(HardwareProbe.modelIdentifier?.isEmpty ?? true, "hw.model")
        XCTAssertFalse(HardwareProbe.chipBrand?.isEmpty ?? true, "machdep.cpu.brand_string")
        // A CI VM may have no Metal device; where there is one, the working
        // set is a real, bounded number.
        if let workingSet = info.gpuWorkingSetBytes {
            XCTAssertGreaterThan(workingSet, 0)
        }
        XCTAssertNotNil(HardwareProbe.freeDiskBytes(at: NSTemporaryDirectory() + "not/there/yet"), "nearest existing parent")
    }

    func testSysctlMissing() {
        XCTAssertNil(HardwareProbe.sysctlString("llmtray.no.such.name"))
        XCTAssertNil(HardwareProbe.sysctlInteger("llmtray.no.such.name"))
        XCTAssertEqual(HardwareProbe.sysctlInteger("hw.memsize").map(UInt64.init), ProcessInfo.processInfo.physicalMemory)
    }

    func testGPULimit() {
        let gb: UInt64 = 1024 * 1024 * 1024
        XCTAssertEqual(HardwareInfo(physicalMemoryBytes: 24 * gb, gpuWorkingSetBytes: 18 * gb, wiredLimitMB: 0).gpuLimitBytes, 18 * gb,
                       "the default limit: Metal's working set")
        XCTAssertEqual(HardwareInfo(physicalMemoryBytes: 24 * gb, gpuWorkingSetBytes: 18 * gb, wiredLimitMB: 22 * 1024).gpuLimitBytes, 22 * gb,
                       "a limit the user set wins")
        XCTAssertEqual(HardwareInfo(physicalMemoryBytes: 24 * gb, wiredLimitMB: nil).gpuLimitBytes, nil)
    }
}
