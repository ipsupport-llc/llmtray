import Foundation

/// The voice that reads answers aloud (adr/0016, spoken answers).
public enum SpokenVoiceKind: String, CaseIterable, Sendable {
    /// macOS's own voices (AVSpeechSynthesizer): no download.
    case system
    /// Chatterbox Multilingual V3 through mlx-audio: opt-in download.
    case chatterbox
}

/// One download the Chatterbox voice needs, into the models folder under
/// its repo's name.
public struct SpokenVoiceFile: Hashable, Sendable {
    public var repo: String
    public var name: String
    /// Only these files of the repo; nil: all of it.
    public var patterns: [String]?
    public var downloadBytes: Int64
    public var license: String

    /// Chatterbox Multilingual V3, converted to MLX (MIT, Resemble AI).
    public static let model = SpokenVoiceFile(
        repo: "mlx-community/chatterbox-multilingual-v3", name: "Chatterbox Multilingual V3",
        patterns: nil, downloadBytes: 2_713_107_406, license: "MIT")
    /// Its speech tokenizer, which mlx-audio otherwise fetches by name
    /// (Apache-2.0: converted from CosyVoice2-0.5B).
    public static let tokenizer = SpokenVoiceFile(
        repo: "mlx-community/S3TokenizerV2", name: "S3 speech tokenizer V2",
        patterns: ["model.safetensors", "config.json"], downloadBytes: 494_869_110, license: "Apache-2.0")
    /// The built-in voice: the multilingual repo has no conds.safetensors;
    /// this is Resemble's own conds.pt (which their multilingual model
    /// loads too), converted. Copied into the model's folder.
    public static let builtInVoice = SpokenVoiceFile(
        repo: "mlx-community/chatterbox-fp16", name: "Chatterbox built-in voice",
        patterns: ["conds.safetensors"], downloadBytes: 105_316, license: "MIT")
    /// Russian stress (ruaccent, MIT): fetched at a pinned revision and
    /// built by runtime/llmtray_ru_stress.py; ~84 MB once built.
    public static let russianStress = SpokenVoiceFile(
        repo: "ruaccent/accentuator", name: "Russian stress (ruaccent)",
        patterns: nil, downloadBytes: 82_124_897, license: "MIT")

    /// What goes in the models folder as folders of their own.
    public static let folders: [SpokenVoiceFile] = [model, tokenizer, russianStress]
    public static var totalDownloadBytes: Int64 { (folders + [builtInVoice]).reduce(0) { $0 + $1.downloadBytes } }

    /// Written by llmtray_ru_stress.py once the stress folder is complete.
    public static let russianStressStamp = "llmtray-ru-stress.json"
}

/// The voice clip a user picks for Chatterbox: its checks before it's
/// copied in.
public enum VoiceClipCheck {
    public static let minSeconds = 5.0
    public static let maxSeconds = 30.0
    public static let goodSeconds = 10.0

    public enum Verdict: Equatable, Sendable {
        case ok
        /// Usable, but shorter than `goodSeconds`.
        case short
        case tooShort
        case tooLong
    }

    public static func verdict(seconds: Double) -> Verdict {
        if seconds < minSeconds { return .tooShort }
        if seconds > maxSeconds { return .tooLong }
        return seconds < goodSeconds ? .short : .ok
    }
}
