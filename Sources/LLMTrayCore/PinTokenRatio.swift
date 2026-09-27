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

    /// Until a request that carried pinned text was counted, the ratio of
    /// the others is taken at most at this: English prose's ~4.3 would
    /// undercount a pinned code, CSV or digit-heavy file by 40% and more.
    public static let unpinnedCap = 3.0
    /// What a failed request that carried pinned text counts as.
    public static let failureSample = PromptTokenEstimator.defaultBytesPerToken

    /// The ratio for pinned text: the lowest of the samples of requests
    /// that carried some; without any, the others' at most `unpinnedCap`.
    public static func learned(_ samples: [Double], pinned: [Double]) -> Double? {
        if let fromPinned = learned(pinned) { return fromPinned }
        return learned(samples).map { min($0, unpinnedCap) }
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

/// Each model's samples (by path): of every counted request, and of those
/// that carried pinned text -- the ones that say how pinned text tokenizes.
public struct PinTokenSamples: Equatable {
    public var all: [String: [Double]]
    public var pinned: [String: [Double]]

    public init(all: [String: [Double]] = [:], pinned: [String: [Double]] = [:]) {
        self.all = all
        self.pinned = pinned
    }

    public func learned(model: String?) -> Double? {
        model.flatMap { PinTokenRatio.learned(all[$0] ?? [], pinned: pinned[$0] ?? []) }
    }

    /// Whether pinned text of `model`'s was counted (or failed): its sizes
    /// are the pinned text's own from then on.
    public func isMeasured(model: String?) -> Bool {
        model.map { !(pinned[$0] ?? []).isEmpty } ?? false
    }

    /// The probe (the user's choice): before any pinned text of `model`'s
    /// was counted, a file that fits only past the cap is sized at the
    /// other requests' own ratio, uncapped -- so it goes out once, and that
    /// request's count sizes it exactly after. A failed probe adds the 2.0
    /// sample (PinTokenRatios.recordFailure), which ends the probing. nil
    /// when not probing: measured, nothing counted, or the cap doesn't bind.
    public func probeBytesPerToken(model: String?) -> Double? {
        guard let model, !isMeasured(model: model), let general = PinTokenRatio.learned(all[model] ?? []) else { return nil }
        let uncapped = PinTokenRatio.effective(general)
        return uncapped > PinTokenRatio.effective(learned(model: model)) ? uncapped : nil
    }

    /// What `model`'s pins are sized at: the probe's ratio while probing,
    /// else the learned one (capped until pinned text is counted).
    public func bytesPerToken(model: String?) -> Double {
        probeBytesPerToken(model: model) ?? PinTokenRatio.effective(learned(model: model))
    }
}

/// The samples kept in UserDefaults (`Pref.pinTokenSamples`,
/// `Pref.pinTokenPinnedSamples`).
public struct PinTokenRatios {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var samples: PinTokenSamples {
        PinTokenSamples(all: defaults[Pref.pinTokenSamples], pinned: defaults[Pref.pinTokenPinnedSamples])
    }

    /// Records a counted request of `model`'s (`carriedPins`: with pinned
    /// text in it); true when it was a sample.
    @discardableResult
    public func record(model: String?, _ m: PromptTokenEstimator.Measure, promptTokens: Int, carriedPins: Bool = false) -> Bool {
        guard let model, let sample = PinTokenRatio.sample(m, promptTokens: promptTokens) else { return false }
        add(sample, model: model, to: Pref.pinTokenSamples)
        if carriedPins { add(sample, model: model, to: Pref.pinTokenPinnedSamples) }
        return true
    }

    /// A request of `model`'s that carried pinned text failed (the server
    /// refused it, likely past its context): no count comes back, so the
    /// ratio would never drop by itself; the next turns size pins at the
    /// estimator's rate until a few counted pinned requests replace it.
    public func recordFailure(model: String?) {
        guard let model else { return }
        add(PinTokenRatio.failureSample, model: model, to: Pref.pinTokenPinnedSamples)
    }

    private func add(_ sample: Double, model: String, to key: PrefKey<[String: [Double]]>) {
        var all = defaults[key]
        all[model] = PinTokenRatio.adding(sample, to: all[model] ?? [])
        defaults[key] = all
    }

    public func learned(model: String?) -> Double? { samples.learned(model: model) }

    /// What `model`'s pins are sized at.
    public func bytesPerToken(model: String?) -> Double { samples.bytesPerToken(model: model) }
}
