import Foundation

/// The KV-cache quantization values mlx_lm.server can actually run with.
///
/// MLX's `mx.quantize` supports bits {2, 3, 4, 5, 6, 8} and group sizes
/// {32, 64, 128} only -- the old Steppers (bits 0...8, group 16...128 step
/// 16) offered 1 and 7 bits and 16/48/80/96/112 groups, every one of which
/// crashes the server on the first request that quantizes its cache. Of the
/// valid values only off / 4 / 8 are worth offering: 2-3 bits visibly hurt
/// the model, 5-6 save little over 8.
enum KVSettings {
    static let bitsChoices = [0, 4, 8]
    static let groupSizeChoices = [32, 64, 128]
    static let defaultBits = 8
    static let defaultGroupSize = 64

    static func validBits(_ bits: Int) -> Int {
        bitsChoices.contains(bits) ? bits : (bits <= 0 ? 0 : (bits <= 5 ? 4 : 8))
    }

    static func validGroupSize(_ size: Int) -> Int {
        groupSizeChoices.min { abs($0 - size) < abs($1 - size) } ?? defaultGroupSize
    }

    /// One-time settings migration. The old default was 4-bit KV from the
    /// first token, which degrades long-context quality; 8-bit is nearly
    /// lossless and still halves KV memory, so the old default moves to 8.
    /// Anything invalid is snapped to the nearest valid value.
    static func migrateIfNeeded(_ defaults: UserDefaults = .standard) {
        let key = "llmtray.kvSettingsMigrated.v1"
        guard !defaults.bool(forKey: key) else { return }
        if let bits = defaults.object(forKey: "llmtray.kvBits") as? Int {
            defaults.set(bits == 4 ? defaultBits : validBits(bits), forKey: "llmtray.kvBits")
        }
        if let size = defaults.object(forKey: "llmtray.kvGroupSize") as? Int {
            defaults.set(validGroupSize(size), forKey: "llmtray.kvGroupSize")
        }
        defaults.set(true, forKey: key)
    }
}
