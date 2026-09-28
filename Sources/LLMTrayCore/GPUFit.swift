import Foundation

/// A model that barely fits the GPU: its weights leave less than 2.5 GB of
/// the GPU limit for the KV cache, the prompt cache and a prefill's
/// activations, so a long prompt may run out of memory (a 17.8 GB model
/// under a 19.1 GB limit did at 20K tokens). Only a notice -- the model
/// still loads; the advice is a smaller model or a raised GPU limit.
public struct GPUFit: Equatable, Sendable {
    /// Less left beside the weights than this is a tight fit.
    public static let tightHeadroomBytes: Int64 = 5 << 29   // 2.5 GB

    public var weightsBytes: Int64
    public var gpuLimitBytes: UInt64
    /// `iogpu.wired_limit_mb` to suggest: the weights and 6 GB, but at most
    /// all of the RAM less 4 GB for macOS; nil when that's no more than
    /// the limit already is (nothing to raise).
    public var suggestedWiredLimitMB: Int?

    /// nil unless the model barely fits (or doesn't): no GPU limit known,
    /// or the weights' size not (yet) known, is no notice either.
    public init?(weightsBytes: Int64, hardware: HardwareInfo) {
        guard weightsBytes > 0, let limit = hardware.gpuLimitBytes,
              let headroom = ServerLaunch.gpuHeadroomBytes(gpuLimitBytes: limit, weightsBytes: weightsBytes),
              headroom < Self.tightHeadroomBytes else { return nil }
        self.weightsBytes = weightsBytes
        self.gpuLimitBytes = limit
        let mb: Int64 = 1_048_576
        let suggested = min(Int64(clamping: hardware.physicalMemoryBytes) / mb - 4096, (weightsBytes + mb - 1) / mb + 6144)
        suggestedWiredLimitMB = suggested > Int64(clamping: limit) / mb ? Int(suggested) : nil
    }

    /// What to type in Terminal for the suggested limit (it lasts until
    /// the Mac restarts). LLMTray never runs it itself.
    public var sysctlCommand: String? {
        suggestedWiredLimitMB.map { "sudo sysctl iogpu.wired_limit_mb=\($0)" }
    }

    /// "17.8": decimal GB with one digit, as the notice shows sizes.
    public static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1e9)
    }
}
