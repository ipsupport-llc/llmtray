import Foundation

/// How an answer was made (its info popover): the model, the server's
/// usage and the client's clock, per request of its turn. Saved with the
/// chat. Every field optional: an older chat has none, and what a server
/// doesn't report stays unknown -- never estimated.
public struct AnswerStats: Codable, Equatable, Sendable {
    /// One request of the turn (a tool round, or the answer itself).
    public struct Request: Codable, Equatable, Sendable {
        /// The whole prompt, cached part included.
        public var promptTokens: Int?
        /// The part of the prompt the server's cache already had.
        public var cachedTokens: Int?
        public var completionTokens: Int?
        public var reasoningTokens: Int?
        /// Request sent -> its first token.
        public var firstTokenSeconds: Double?
        /// First token -> last.
        public var generationSeconds: Double?

        public init(promptTokens: Int? = nil, cachedTokens: Int? = nil, completionTokens: Int? = nil,
                    reasoningTokens: Int? = nil, firstTokenSeconds: Double? = nil, generationSeconds: Double? = nil) {
            self.promptTokens = promptTokens
            self.cachedTokens = cachedTokens
            self.completionTokens = completionTokens
            self.reasoningTokens = reasoningTokens
            self.firstTokenSeconds = firstTokenSeconds
            self.generationSeconds = generationSeconds
        }

        /// The timings from the client's clock: sent, first token, last.
        public mutating func time(sent: Date?, firstToken: Date?, lastToken: Date?) {
            guard let firstToken else { return }
            if let sent { firstTokenSeconds = max(0, firstToken.timeIntervalSince(sent)) }
            if let lastToken { generationSeconds = max(0, lastToken.timeIntervalSince(firstToken)) }
        }
    }

    public var date: Date?
    /// As the chat header names it.
    public var model: String?
    public var modelFolder: String?
    public var profile: String?
    /// The model's context (its max tokens cap).
    public var contextTokens: Int?
    /// Oldest first; the last one wrote the answer.
    public var requests: [Request]?
    public var toolCalls: Int?
    /// First request sent -> the answer's last token, tool runs included.
    public var totalSeconds: Double?

    public init(date: Date? = nil, model: String? = nil, modelFolder: String? = nil, profile: String? = nil,
                contextTokens: Int? = nil, requests: [Request]? = nil, toolCalls: Int? = nil, totalSeconds: Double? = nil) {
        self.date = date
        self.model = model
        self.modelFolder = modelFolder
        self.profile = profile
        self.contextTokens = contextTokens
        self.requests = requests
        self.toolCalls = toolCalls
        self.totalSeconds = totalSeconds
    }

    /// Sub-50ms spans are measurement noise, not a rate.
    static let minRateSeconds = 0.05

    public var requestCount: Int { requests?.count ?? 0 }
    private var last: Request? { requests?.last }

    /// The answer's decoding speed: its tokens over first -> last token.
    public var generationTokensPerSecond: Double? {
        guard let tokens = last?.completionTokens, tokens > 0,
              let seconds = last?.generationSeconds, seconds >= Self.minRateSeconds else { return nil }
        return Double(tokens) / seconds
    }

    /// Prefill: the prompt tokens not cached over the time to first token.
    public var promptTokensPerSecond: Double? {
        guard let prompt = last?.promptTokens, let seconds = last?.firstTokenSeconds, seconds >= Self.minRateSeconds else { return nil }
        let uncached = prompt - (last?.cachedTokens ?? 0)
        return uncached > 0 ? Double(uncached) / seconds : nil
    }

    public var firstTokenSeconds: Double? { last?.firstTokenSeconds }
    public var promptTokens: Int? { last?.promptTokens }
    public var cachedTokens: Int? { last?.cachedTokens }
    /// Across the turn's requests: only when every one reported it.
    public var answerTokens: Int? { sum(\.completionTokens) }
    public var reasoningTokens: Int? { sum(\.reasoningTokens) }

    /// The last request's prompt and answer: what the context held.
    public var contextUsed: Int? {
        guard let prompt = last?.promptTokens, let answer = last?.completionTokens else { return nil }
        return prompt + answer
    }

    public var contextFraction: Double? {
        guard let used = contextUsed, let cap = contextTokens, cap > 0 else { return nil }
        return min(1, Double(used) / Double(cap))
    }

    private func sum(_ field: KeyPath<Request, Int?>) -> Int? {
        guard let requests, !requests.isEmpty else { return nil }
        let values = requests.compactMap { $0[keyPath: field] }
        return values.count == requests.count ? values.reduce(0, +) : nil
    }
}

// MARK: - Presentation

extension AnswerStats {
    /// `date`: the answer's time, a footer without a heading.
    public enum SectionKind: Equatable, Sendable { case model, speed, tokens, context, date }

    public enum RowKind: Equatable, Sendable {
        case model, folder, profile
        case generation, promptProcessing, firstToken, totalTime
        case prompt, promptLast, cached, answer, answerTotal, reasoning, toolCalls
        case context
        case date
    }

    public struct Row: Equatable, Sendable {
        public var kind: RowKind
        public var value: String
    }

    public struct Section: Equatable, Sendable {
        public var kind: SectionKind
        public var rows: [Row]
    }

    /// What the popover lists: only what is known, sections without rows
    /// left out.
    public func sections(locale: Locale = .current) -> [Section] {
        func row(_ kind: RowKind, _ value: String?) -> Row? { value.map { Row(kind: kind, value: $0) } }
        let multi = requestCount > 1
        let int = { (n: Int?) in n.map { Self.format($0, locale) } }
        let all: [Section] = [
            Section(kind: .model, rows: [
                row(.model, model), row(.folder, modelFolder == model ? nil : modelFolder), row(.profile, profile),
            ].compactMap { $0 }),
            Section(kind: .speed, rows: [
                row(.generation, generationTokensPerSecond.map { Self.rate($0, locale) }),
                row(.promptProcessing, promptTokensPerSecond.map { Self.rate($0, locale) }),
                row(.firstToken, firstTokenSeconds.map { Self.duration($0, locale) }),
                row(.totalTime, totalSeconds.map { Self.duration($0, locale) }),
            ].compactMap { $0 }),
            Section(kind: .tokens, rows: [
                row(multi ? .promptLast : .prompt, int(promptTokens)),
                row(.cached, cachedTokens.flatMap { $0 > 0 ? int($0) : nil }),
                row(multi ? .answerTotal : .answer, int(answerTokens)),
                row(.reasoning, reasoningTokens.flatMap { $0 > 0 ? int($0) : nil }),
                row(.toolCalls, toolCalls.flatMap { $0 > 0 ? int($0) : nil }),
            ].compactMap { $0 }),
            Section(kind: .context, rows: [
                row(.context, contextUsed.map { used in
                    guard let cap = contextTokens, let fraction = contextFraction else { return Self.format(used, locale) }
                    return "\(Self.format(used, locale)) / \(Self.format(cap, locale)) (\(Self.percent(fraction, locale)))"
                }),
            ].compactMap { $0 }),
        ]
        var shown = all.filter { !$0.rows.isEmpty }
        if let date, !shown.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            shown.append(Section(kind: .date, rows: [Row(kind: .date, value: formatter.string(from: date))]))
        }
        return shown
    }

    /// The details as plain text (Copy): a heading per section, then
    /// "label: value" lines.
    public func plainText(locale: Locale = .current, heading: (SectionKind) -> String, label: (RowKind) -> String) -> String {
        sections(locale: locale).map { section in
            let lines = section.rows.map { "\(label($0.kind)): \($0.value)" }
            let title = section.kind == .date ? nil : heading(section.kind)
            return ([title].compactMap { $0 } + lines).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func format(_ n: Int, _ locale: Locale) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func rate(_ perSecond: Double, _ locale: Locale) -> String {
        "\(decimal(perSecond, digits: perSecond < 100 ? 1 : 0, locale)) tok/s"
    }

    /// 0.42 s, 3.1 s, 2:05 min.
    static func duration(_ seconds: Double, _ locale: Locale) -> String {
        if seconds < 1 { return "\(decimal(seconds, digits: 2, locale)) s" }
        if seconds < 60 { return "\(decimal(seconds, digits: 1, locale)) s" }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d min", whole / 60, whole % 60)
    }

    static func percent(_ fraction: Double, _ locale: Locale) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .percent
        f.maximumFractionDigits = fraction > 0 && fraction < 0.01 ? 1 : 0
        return f.string(from: NSNumber(value: fraction)) ?? "\(Int(fraction * 100))%"
    }

    private static func decimal(_ value: Double, digits: Int, _ locale: Locale) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }
}
