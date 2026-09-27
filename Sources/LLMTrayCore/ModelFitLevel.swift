import Foundation

/// A rough, honest heuristic -- not a promise. Compares a repo's on-disk
/// size against total (not currently-free) physical memory, since "will
/// this machine ever run this comfortably" is the more useful question
/// while browsing than "is there room for it this exact second," and free
/// memory fluctuates with whatever else happens to be running. Doesn't
/// account for KV-cache/activation overhead on top of the weights
/// themselves, which is real but depends on context length and isn't
/// knowable in advance -- the thresholds leave headroom for it, but a
/// model right at the "fits" boundary can still fail on a long context.
/// The HF browser's dot and the wizard's recommendations (adr/0013).
public enum ModelFitLevel: Equatable, Sendable, CaseIterable {
    case fits
    case tight
    case unlikely

    public static func estimate(sizeBytes: Int64, physicalMemoryBytes: UInt64) -> ModelFitLevel {
        let ratio = Double(sizeBytes) / Double(physicalMemoryBytes)
        if ratio < 0.45 { return .fits }
        if ratio < 0.70 { return .tight }
        return .unlikely
    }
}
