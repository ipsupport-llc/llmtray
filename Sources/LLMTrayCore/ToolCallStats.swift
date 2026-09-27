import Foundation

/// How the chat's tool calls went, per app version and tool: counts only,
/// kept on this Mac (Settings shows them, a bug report includes them),
/// never sent anywhere by themselves. Bounded: a few versions, a fixed set
/// of tool names (anything else counts as "(unknown)").
public struct ToolCallStats: Codable, Equatable, Sendable {
    public struct Counts: Codable, Equatable, Sendable {
        public var calls = 0
        public var successes = 0
        public var refusals = 0
        /// ToolRepair raw value -> calls it was applied to.
        public var repairs: [String: Int] = [:]
        /// Error kind (bad_json, missing_field, bad_type, bad_value,
        /// unknown_tool, unavailable, failed) -> calls.
        public var errors: [String: Int] = [:]

        public init() {}

        public var errorCount: Int { errors.values.reduce(0, +) }
        /// Calls that needed at least one fix.
        public var repairedCalls = 0

        enum CodingKeys: String, CodingKey { case calls, successes, refusals, repairs, errors, repairedCalls }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            calls = try c.decodeIfPresent(Int.self, forKey: .calls) ?? 0
            successes = try c.decodeIfPresent(Int.self, forKey: .successes) ?? 0
            refusals = try c.decodeIfPresent(Int.self, forKey: .refusals) ?? 0
            repairs = try c.decodeIfPresent([String: Int].self, forKey: .repairs) ?? [:]
            errors = try c.decodeIfPresent([String: Int].self, forKey: .errors) ?? [:]
            repairedCalls = try c.decodeIfPresent(Int.self, forKey: .repairedCalls) ?? 0
        }
    }

    public enum Outcome: Equatable, Sendable {
        case success
        case refused
        case error(String)
    }

    public struct Version: Codable, Equatable, Sendable {
        public var updated: Date
        public var tools: [String: Counts]
    }

    public static let unknownTool = "(unknown)"
    public static let maxVersions = 5
    public static let maxTools = 48
    public static let errorKinds: Set<String> = ["bad_json", "missing_field", "bad_type", "bad_value", "unknown_tool", "unavailable", "failed"]

    public var versions: [String: Version] = [:]

    public init() {}

    /// One call of `tool` (a declared name; nil or anything unrecognised
    /// counts as unknown) in `version`.
    public mutating func record(tool: String?, known: Bool, version: String, repairs: [ToolRepair], outcome: Outcome, now: Date = Date()) {
        var entry = versions[version] ?? Version(updated: now, tools: [:])
        var name = known ? (tool ?? Self.unknownTool) : Self.unknownTool
        if entry.tools[name] == nil, entry.tools.count >= Self.maxTools { name = Self.unknownTool }
        var counts = entry.tools[name] ?? Counts()
        counts.calls += 1
        if !repairs.isEmpty { counts.repairedCalls += 1 }
        for repair in Set(repairs) { counts.repairs[repair.rawValue, default: 0] += 1 }
        switch outcome {
        case .success: counts.successes += 1
        case .refused: counts.refusals += 1
        case .error(let kind): counts.errors[Self.errorKinds.contains(kind) ? kind : "failed", default: 0] += 1
        }
        entry.tools[name] = counts
        entry.updated = now
        versions[version] = entry
        trim()
    }

    /// The newest versions only.
    mutating func trim() {
        guard versions.count > Self.maxVersions else { return }
        let keep = versions.sorted { $0.value.updated > $1.value.updated }.prefix(Self.maxVersions).map(\.key)
        versions = versions.filter { keep.contains($0.key) }
    }

    /// A tool's line for a bug report or a tooltip:
    /// "12 calls, 11 ok, 2 repaired (fieldAlias 1, fenced 1), 1 error (missing_field 1), 0 refused".
    public static func summary(_ c: Counts) -> String {
        func breakdown(_ d: [String: Int]) -> String {
            d.isEmpty ? "" : " (" + d.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")"
        }
        return "\(c.calls) calls, \(c.successes) ok, \(c.repairedCalls) repaired\(breakdown(c.repairs)), "
            + "\(c.errorCount) errors\(breakdown(c.errors)), \(c.refusals) refused"
    }

    /// The bug report's lines for `version`, busiest tool first.
    public func reportLines(version: String) -> [(String, String)] {
        guard let entry = versions[version], !entry.tools.isEmpty else { return [("Tool calls", "none recorded")] }
        return entry.tools.sorted { $0.value.calls != $1.value.calls ? $0.value.calls > $1.value.calls : $0.key < $1.key }
            .map { ($0.key, Self.summary($0.value)) }
    }

    // MARK: - File

    public static func load(from url: URL) -> ToolCallStats {
        guard let data = try? Data(contentsOf: url) else { return ToolCallStats() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ToolCallStats.self, from: data)) ?? ToolCallStats()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
