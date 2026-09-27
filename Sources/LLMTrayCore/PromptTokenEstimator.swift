import Foundation

/// A chat request's prompt tokens, estimated before it's sent (adr/0012,
/// "Budget"), from its serialized UTF-8 bytes and the server's own
/// `usage.prompt_tokens` of the chat's last request. mlx_lm.server (the
/// app's fork) sends that in the stream's last chunk when asked with
/// `stream_options.include_usage`, the full prompt count even when most of
/// it came from its prompt cache.
///
/// Only the counted request's own tokens are trusted: what was added since
/// counts at the default ratio. A ratio averaged over the chat so far
/// isn't applied to new text -- dense file text in a request that got
/// smaller (tools no longer declared) would be undercounted.
public struct PromptTokenEstimator: Equatable {
    /// Until the first response, and for text added since the counted
    /// request: deliberately low. The chat models' tokenizers measured
    /// 2.1-6.9 bytes a token on Russian, 4.1-4.6 on English, 2.8-3.6 on
    /// code (PromptTokenEstimatorTests), so this overcounts, never under.
    public static let defaultBytesPerToken = 2.0
    /// What an image counts as: its data URI's bytes say nothing about the
    /// tokens a vision model spends on it (a few hundred to ~1,500).
    public static let tokensPerImage = 1536

    /// A request's size: its serialized bytes without the images' data
    /// URIs, and how many images it carries.
    public struct Measure: Equatable {
        public var bytes: Int
        public var images: Int

        public init(bytes: Int, images: Int = 0) {
            self.bytes = bytes
            self.images = images
        }
    }

    /// The last request the server counted, and its count.
    public struct Calibration: Equatable {
        public var bytes: Int
        public var tokens: Int
    }
    public private(set) var calibration: Calibration?

    public init() {}

    /// The prompt tokens of a whole request, uncounted: at the default ratio.
    public func estimate(_ m: Measure) -> Int {
        Self.tokens(m)
    }

    /// The prompt tokens of the counted request plus what was `added` to it
    /// since (a tool round's call and results, declarations that grew): the
    /// server's count plus the new part at the default ratio -- new file
    /// text may tokenize worse than the chat so far (code after Russian).
    /// nil when nothing was counted yet.
    public func estimate(countedPlus added: Measure) -> Int? {
        calibration.map { $0.tokens + Self.tokens(added) }
    }

    private static func tokens(_ m: Measure) -> Int {
        Int((Double(max(0, m.bytes)) / defaultBytesPerToken).rounded(.up)) + max(0, m.images) * tokensPerImage
    }

    /// The server counted `promptTokens` for a request of this size. A
    /// request with images isn't used: their tokens aren't in its bytes.
    public mutating func calibrate(_ m: Measure, promptTokens: Int) {
        guard m.images == 0, promptTokens > 0, m.bytes > 0 else { return }
        calibration = Calibration(bytes: m.bytes, tokens: promptTokens)
    }
}
