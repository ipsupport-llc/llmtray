import Foundation
import Metal

/// What this Mac has, for choosing models (adr/0013) and for the bug
/// report: one place that reads it, instead of each caller's own `sysctl`.
public struct HardwareInfo: Equatable, Sendable {
    /// "Apple M3 Pro" (`machdep.cpu.brand_string`).
    public var chip: String?
    /// "Mac15,6" (`hw.model`).
    public var modelIdentifier: String?
    public var physicalMemoryBytes: UInt64
    /// Metal's `recommendedMaxWorkingSetSize`: how much the GPU may keep
    /// resident -- a model's weights must fit under it. nil without a
    /// Metal device (a VM without GPU access).
    public var gpuWorkingSetBytes: UInt64?
    /// `iogpu.wired_limit_mb`: 0 is macOS's default limit, a positive value
    /// one the user raised with `sysctl`. nil when it can't be read.
    public var wiredLimitMB: Int64?

    public init(chip: String? = nil, modelIdentifier: String? = nil, physicalMemoryBytes: UInt64,
                gpuWorkingSetBytes: UInt64? = nil, wiredLimitMB: Int64? = nil) {
        self.chip = chip
        self.modelIdentifier = modelIdentifier
        self.physicalMemoryBytes = physicalMemoryBytes
        self.gpuWorkingSetBytes = gpuWorkingSetBytes
        self.wiredLimitMB = wiredLimitMB
    }

    /// How much GPU memory a model may use: the wired limit where the user
    /// set one (it's what the GPU is then allowed to wire), else Metal's
    /// working set; nil when neither is known.
    public var gpuLimitBytes: UInt64? {
        if let wiredLimitMB, wiredLimitMB > 0 { return UInt64(wiredLimitMB) * 1024 * 1024 }
        return gpuWorkingSetBytes
    }
}

public enum HardwareProbe {
    /// Everything at once (the Metal device is created once per call).
    public static func current() -> HardwareInfo {
        HardwareInfo(
            chip: chipBrand, modelIdentifier: modelIdentifier,
            physicalMemoryBytes: physicalMemoryBytes,
            gpuWorkingSetBytes: metalWorkingSetBytes, wiredLimitMB: wiredLimitMB
        )
    }

    public static var chipBrand: String? { sysctlString("machdep.cpu.brand_string") }
    public static var modelIdentifier: String? { sysctlString("hw.model") }
    public static var physicalMemoryBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }
    public static var wiredLimitMB: Int64? { sysctlInteger("iogpu.wired_limit_mb") }

    public static var metalWorkingSetBytes: UInt64? {
        MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize
    }

    /// Free space for a download into `path` (it need not exist yet).
    public static func freeDiskBytes(at path: String) -> Int64? {
        DiskUsage.freeSpace(at: path)
    }

    /// A string sysctl (a C string).
    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// A numeric sysctl, 4 or 8 bytes.
    public static func sysctlInteger(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        if size == 4 {
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int64(value)
        }
        var value: Int64 = 0
        guard size == 8, sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
