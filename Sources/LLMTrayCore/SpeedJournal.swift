import Foundation

/// One request as mlx_lm.server reports it when it ends ("Request stats:
/// prompt=N cached=M first_token_s=X tokens=K decode_s=Y drafted=D"),
/// whoever sent it: the chat, a coding agent through the proxy, curl.
public struct RequestStats: Codable, Equatable, Sendable {
    public var prompt: Int
    /// The part of the prompt the server's cache already had.
    public var cached: Int
    /// Request in -> first token: the queue and the uncached prompt.
    public var firstTokenSeconds: Double
    public var tokens: Int
    /// First token -> last.
    public var decodeSeconds: Double
    /// Tokens that came from accepted drafts (speculative decoding).
    public var drafted: Int

    public init(prompt: Int, cached: Int, firstTokenSeconds: Double, tokens: Int, decodeSeconds: Double, drafted: Int) {
        self.prompt = prompt
        self.cached = cached
        self.firstTokenSeconds = firstTokenSeconds
        self.tokens = tokens
        self.decodeSeconds = decodeSeconds
        self.drafted = drafted
    }

    public var uncached: Int { max(0, prompt - cached) }

    /// Prompt tokens a second over the uncached part; nil for a short one,
    /// whose wait is mostly not prefill.
    public var prefillTokensPerSecond: Double? {
        uncached >= 256 && firstTokenSeconds > 0 ? Double(uncached) / firstTokenSeconds : nil
    }

    /// Generated tokens a second after the first; nil for a short answer.
    public var decodeTokensPerSecond: Double? {
        tokens >= 16 && decodeSeconds > 0 ? Double(tokens - 1) / decodeSeconds : nil
    }

    static let pattern = try! NSRegularExpression(pattern:
        #"Request stats: prompt=(\d+) cached=(\d+) first_token_s=([\d.]+) tokens=(\d+) decode_s=([\d.]+) drafted=(\d+)"#)

    /// From the text after a log record's prefix.
    public static func parse(_ text: String) -> RequestStats? {
        let ns = text as NSString
        guard let m = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func s(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
        guard let prompt = Int(s(1)), let cached = Int(s(2)), let first = Double(s(3)), let tokens = Int(s(4)),
              let decode = Double(s(5)), let drafted = Int(s(6)) else { return nil }
        return RequestStats(prompt: prompt, cached: cached, firstTokenSeconds: first, tokens: tokens,
                            decodeSeconds: decode, drafted: drafted)
    }
}

/// Real-world speed, kept locally: every request the server served, with
/// the model and the launch settings it ran under, summarized per model and
/// settings (medians, so a request stuck behind another doesn't skew it).
public struct SpeedJournal: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var date: Date
        /// The model folder's name.
        public var model: String
        /// The launch settings that change speed, in words (settings(of:)).
        public var settings: String
        public var stats: RequestStats

        public init(date: Date, model: String, settings: String, stats: RequestStats) {
            self.date = date
            self.model = model
            self.settings = settings
            self.stats = stats
        }
    }

    public struct Summary: Equatable, Sendable {
        public var model: String
        public var settings: String
        public var requests: Int
        public var prefillTokensPerSecond: Double?
        public var decodeTokensPerSecond: Double?
        public var firstTokenSeconds: Double?
        /// Share of generated tokens that came from drafts; nil without any.
        public var draftedShare: Double?
        public var lastUsed: Date
    }

    public static let limit = 5000
    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = Array(entries.suffix(Self.limit))
    }

    public mutating func add(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    public mutating func clear() { entries.removeAll() }

    /// Per model and settings, the most recently used first.
    public func summaries() -> [Summary] {
        var groups: [String: [Entry]] = [:]
        var order: [String] = []
        for e in entries {
            let key = e.model + "\u{1}" + e.settings
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(e)
        }
        return order.compactMap { key -> Summary? in
            guard let g = groups[key], let last = g.last else { return nil }
            let tokens = g.reduce(0) { $0 + $1.stats.tokens }
            let drafted = g.reduce(0) { $0 + $1.stats.drafted }
            return Summary(
                model: last.model, settings: last.settings, requests: g.count,
                prefillTokensPerSecond: Self.median(g.compactMap(\.stats.prefillTokensPerSecond)),
                decodeTokensPerSecond: Self.median(g.compactMap(\.stats.decodeTokensPerSecond)),
                firstTokenSeconds: Self.median(g.map(\.stats.firstTokenSeconds)),
                draftedShare: drafted > 0 && tokens > 0 ? Double(drafted) / Double(tokens) : nil,
                lastUsed: last.date)
        }.sorted { $0.lastUsed > $1.lastUsed }
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The launch settings that change speed, in words, from mlx_lm.server's
    /// arguments: KV quantization, speculative decoding (an MTP head or a
    /// drafter), decode concurrency, the prefill step. As the server reads
    /// them: the last occurrence wins (the profile's extra arguments come
    /// after the generated ones), "--flag=value" and "--flag_name" too.
    public static func settings(of arguments: [String]) -> String {
        var values: [String: String] = [:]
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            guard arg.hasPrefix("--") else { i += 1; continue }
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            let flag = parts[0].replacingOccurrences(of: "_", with: "-")
            if parts.count == 2 {
                values[flag] = parts[1]
            } else if i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") {
                values[flag] = arguments[i + 1]
                i += 1
            } else {
                values[flag] = ""
            }
            i += 1
        }
        func number(_ flag: String) -> Int? { values[flag].flatMap { Int($0) } }
        var parts: [String] = []
        if let bits = number("--kv-bits"), bits > 0 { parts.append("KV \(bits)-bit") } else { parts.append("KV full") }
        let drafter = values["--draft-model"].map { !$0.isEmpty } ?? false
        if drafter || (number("--num-draft-tokens").map { $0 > 0 } ?? false) { parts.append("MTP") }
        if let n = number("--decode-concurrency"), n > 1 { parts.append("concurrency \(n)") }
        if let step = number("--prefill-step-size") { parts.append("prefill \(step)") }
        return parts.joined(separator: " · ")
    }
}
