import Foundation

/// Who sent a request, in a word, for the usage statistics: LLMTray's own
/// chat and background work, else the client its User-Agent names.
public enum UsageClient {
    /// The header LLMTray's proxy sends the runtime with the name; the
    /// runtime ends its stats line with it (fork: "client=<name>").
    public static let header = "X-LLMTray-Client"

    public static let app = "LLMTray"
    public static let appBackground = "LLMTray (background)"

    /// Known clients by a part of their User-Agent, first match wins.
    static let known: [(match: String, name: String)] = [
        ("codex", "Codex"),
        ("claude-cli", "Claude Code"),
        ("claude-code", "Claude Code"),
        ("opencode", "OpenCode"),
        ("cline", "Cline"),
        ("kilo-code", "Kilo Code"),
        ("roo-code", "Roo Code"),
        ("continue", "Continue"),
        ("aider", "Aider"),
        ("zed", "Zed"),
        ("cursor", "Cursor"),
        ("jetbrains", "JetBrains"),
        ("xcode", "Xcode"),
        ("openwebui", "Open WebUI"),
        ("open-webui", "Open WebUI"),
        ("librechat", "LibreChat"),
        ("anthropic/python", "Anthropic SDK (Python)"),
        ("anthropic/js", "Anthropic SDK (JS)"),
        ("openai/python", "OpenAI SDK (Python)"),
        ("openai/js", "OpenAI SDK (JS)"),
        ("python-requests", "Python"),
        ("python-httpx", "Python"),
        ("aiohttp", "Python"),
        ("curl/", "curl"),
        ("wget/", "wget"),
        ("postman", "Postman"),
        ("insomnia", "Insomnia"),
        ("mozilla/", "Browser"),
    ]

    /// The name for a request: the app's own (its token) by whether it's
    /// background work, anyone else's by its User-Agent -- a known client's
    /// name, else the agent's first product name ("Foo/1.2 (…)" → "Foo"),
    /// else "Other".
    public static func name(userAgent: String?, fromApp: Bool, background: Bool) -> String {
        if fromApp { return background ? appBackground : app }
        guard let agent = userAgent?.trimmingCharacters(in: .whitespaces), !agent.isEmpty else { return "Other" }
        let lower = agent.lowercased()
        if let hit = known.first(where: { lower.contains($0.match) }) { return hit.name }
        let product = agent.split(whereSeparator: { $0 == "/" || $0 == " " || $0 == "(" }).first.map(String.init) ?? ""
        let clean = String(product.filter { $0.isLetter || $0.isNumber || " ._-".contains($0) }.prefix(24))
        return clean.isEmpty ? "Other" : clean
    }
}

/// Usage statistics, kept on this Mac when turned on: per day, model and
/// client, how many requests and tokens and how fast. Sums, not each
/// request: small for years of use.
public struct UsageLedger: Codable, Equatable, Sendable {
    public struct Key: Codable, Hashable, Sendable {
        /// "2026-10-18", the local day.
        public var day: String
        /// The model folder's name.
        public var model: String
        public var client: String
    }

    public struct Counts: Codable, Equatable, Sendable {
        public var requests = 0
        public var promptTokens = 0
        public var cachedTokens = 0
        public var generatedTokens = 0
        /// Waits for the first token, summed (mean = / requests).
        public var firstTokenSeconds = 0.0
        /// For prefill speed: prompts long enough to measure (RequestStats).
        public var prefillTokens = 0
        public var prefillSeconds = 0.0
        /// For decode speed: answers long enough to measure.
        public var decodeTokens = 0
        public var decodeSeconds = 0.0
        /// Requests whose first-token wait is in `firstTokenSeconds`: all of
        /// them.
        public init() {}

        mutating func add(_ s: RequestStats) {
            requests += 1
            promptTokens += s.prompt
            cachedTokens += min(s.cached, s.prompt)
            generatedTokens += s.tokens
            firstTokenSeconds += s.firstTokenSeconds
            if s.prefillTokensPerSecond != nil {
                prefillTokens += s.uncached
                prefillSeconds += s.firstTokenSeconds
            }
            if s.decodeTokensPerSecond != nil {
                decodeTokens += s.tokens - 1
                decodeSeconds += s.decodeSeconds
            }
        }

        public mutating func add(_ other: Counts) {
            requests += other.requests
            promptTokens += other.promptTokens
            cachedTokens += other.cachedTokens
            generatedTokens += other.generatedTokens
            firstTokenSeconds += other.firstTokenSeconds
            prefillTokens += other.prefillTokens
            prefillSeconds += other.prefillSeconds
            decodeTokens += other.decodeTokens
            decodeSeconds += other.decodeSeconds
        }

        /// Share of prompt tokens the cache already had.
        public var cachedShare: Double? { promptTokens > 0 ? Double(cachedTokens) / Double(promptTokens) : nil }
        public var prefillTokensPerSecond: Double? { prefillSeconds > 0 ? Double(prefillTokens) / prefillSeconds : nil }
        public var decodeTokensPerSecond: Double? { decodeSeconds > 0 ? Double(decodeTokens) / decodeSeconds : nil }
        public var meanFirstTokenSeconds: Double? { requests > 0 ? firstTokenSeconds / Double(requests) : nil }
    }

    /// Stored as a list (a dictionary with struct keys isn't JSON).
    public struct Row: Codable, Equatable, Sendable {
        public var key: Key
        public var counts: Counts
    }

    public private(set) var rows: [Row] = []

    public init(rows: [Row] = []) { self.rows = rows }

    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public mutating func record(_ stats: RequestStats, model: String, at date: Date, calendar: Calendar = .current) {
        let key = Key(day: Self.day(date, calendar: calendar), model: model, client: stats.client ?? "Other")
        if let i = rows.lastIndex(where: { $0.key == key }) {
            rows[i].counts.add(stats)
        } else {
            var counts = Counts()
            counts.add(stats)
            rows.append(Row(key: key, counts: counts))
        }
    }

    public mutating func clear() { rows.removeAll() }

    public enum Period: String, CaseIterable, Sendable { case today, week, all }
    public enum Grouping: String, CaseIterable, Sendable { case model, client, day }

    public struct Line: Equatable, Sendable, Identifiable {
        public var name: String
        public var counts: Counts
        public var id: String { name }
    }

    /// The rows of `period` (ending `now`), summed per model, client or
    /// day: the most requests first, days newest first.
    public func lines(_ period: Period, by grouping: Grouping, now: Date = Date(), calendar: Calendar = .current) -> [Line] {
        let first: String? = {
            switch period {
            case .all: return nil
            case .today: return Self.day(now, calendar: calendar)
            case .week:
                let start = calendar.date(byAdding: .day, value: -6, to: now) ?? now
                return Self.day(start, calendar: calendar)
            }
        }()
        var sums: [String: Counts] = [:]
        for row in rows where first.map({ row.key.day >= $0 }) ?? true {
            let name: String
            switch grouping {
            case .model: name = row.key.model
            case .client: name = row.key.client
            case .day: name = row.key.day
            }
            sums[name, default: Counts()].add(row.counts)
        }
        let lines = sums.map { Line(name: $0.key, counts: $0.value) }
        if grouping == .day { return lines.sorted { $0.name > $1.name } }
        return lines.sorted { $0.counts.requests != $1.counts.requests ? $0.counts.requests > $1.counts.requests : $0.name < $1.name }
    }

    /// The whole period in one.
    public func total(_ period: Period, now: Date = Date(), calendar: Calendar = .current) -> Counts {
        var total = Counts()
        for line in lines(period, by: .day, now: now, calendar: calendar) { total.add(line.counts) }
        return total
    }
}
