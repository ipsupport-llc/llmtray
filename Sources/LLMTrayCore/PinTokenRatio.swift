import Foundation

/// A model's bytes a token, learned from the server's counts, for sizing
/// pinned files (adr/0012, "Pinned files"). The estimator's 2 bytes a token
/// overcounts English about twice: a book of 242,712 bytes was ≈121K by it
/// and 57K by Gemma 4's tokenizer, refused at an 83K limit it fits.
///
/// A sample is a counted request's bytes (as `measure` counts them) over
/// the server's `prompt_tokens`. One ratio a model, of whole requests: the
/// chat template's tokens aren't in the bytes, so the sample is lower than
/// the text's own ratio -- on the safe side. The learned value is the
/// lowest of the last few samples: undercounting a pin overflows the
/// request (a failed answer), overcounting only leaves a file out, and a
/// denser text (Russian after English) takes the ratio down at its first
/// counted request, while a lighter one lifts it within a few.
/// The request-level estimate (PromptTokenEstimator) doesn't use it.
public enum PinTokenRatio {
    /// Smaller requests don't count: template and tool-declaration tokens
    /// weigh too much in them.
    public static let minimumPromptTokens = 2_000
    public static let samplesKept = 5
    /// Of the learned ratio, what sizes a pin.
    public static let safety = 0.9
    /// What a pin is sized at, at most and at least (the estimator's default).
    public static let range = PromptTokenEstimator.defaultBytesPerToken...6.0

    /// A counted request's ratio; nil when it doesn't count: images (their
    /// tokens aren't in the bytes), or a request under the minimum.
    public static func sample(_ m: PromptTokenEstimator.Measure, promptTokens: Int) -> Double? {
        guard m.images == 0, m.bytes > 0, promptTokens >= minimumPromptTokens else { return nil }
        return Double(m.bytes) / Double(promptTokens)
    }

    /// The samples kept after `sample`: the last few.
    public static func adding(_ sample: Double, to samples: [Double]) -> [Double] {
        Array((samples + [sample]).suffix(samplesKept))
    }

    /// The lowest of the samples; nil without any.
    public static func learned(_ samples: [Double]) -> Double? {
        samples.filter { $0.isFinite && $0 > 0 }.min()
    }

    /// What pins are sized at: the learned ratio less the safety margin,
    /// within `range`; the estimator's default for a model not counted yet.
    public static func effective(_ learned: Double?) -> Double {
        guard let learned else { return range.lowerBound }
        return min(max(learned * safety, range.lowerBound), range.upperBound)
    }

    /// Tokens of `bytes` at `bytesPerToken`, rounded up.
    public static func tokens(bytes: Int, bytesPerToken: Double) -> Int {
        let ratio = bytesPerToken.isFinite && bytesPerToken > 0 ? bytesPerToken : range.lowerBound
        return Int((Double(max(0, bytes)) / ratio).rounded(.up))
    }

    /// Each document's bytes as tokens.
    public static func tokens(_ bytes: [Int64: Int], bytesPerToken: Double) -> [Int64: Int] {
        bytes.mapValues { tokens(bytes: $0, bytesPerToken: bytesPerToken) }
    }
}

/// The learned ratios, by model path, kept in UserDefaults
/// (`Pref.pinTokenSamples`: each model's last samples).
public struct PinTokenRatios {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var all: [String: [Double]] { defaults[Pref.pinTokenSamples] }

    /// Records a counted request of `model`'s; true when it was a sample.
    @discardableResult
    public func record(model: String?, _ m: PromptTokenEstimator.Measure, promptTokens: Int) -> Bool {
        guard let model, let sample = PinTokenRatio.sample(m, promptTokens: promptTokens) else { return false }
        var all = all
        all[model] = PinTokenRatio.adding(sample, to: all[model] ?? [])
        defaults[Pref.pinTokenSamples] = all
        return true
    }

    public func learned(model: String?) -> Double? {
        model.flatMap { PinTokenRatio.learned(all[$0] ?? []) }
    }

    /// What `model`'s pins are sized at.
    public func bytesPerToken(model: String?) -> Double {
        PinTokenRatio.effective(learned(model: model))
    }
}
