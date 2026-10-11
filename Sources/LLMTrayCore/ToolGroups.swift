import Foundation

/// Tools declared only when a chat needs them (adr/0020, "Tools loaded when
/// needed"): a group is `always` declared, or `onDemand` -- then the model
/// loads it with `load_tools`, or the user from the composer's + menu, once
/// per chat, and it stays: a changed tool list is a changed prompt prefix.
public enum ToolLoading: String, Codable, Sendable, CaseIterable {
    case always
    case onDemand

    /// A hand-edited value, leniently: any case, `on_demand`, `on-demand`.
    init?(lenient raw: String) {
        switch raw.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") {
        case "always": self = .always
        case "ondemand": self = .onDemand
        default: return nil
        }
    }
}

/// The groups there are, their tools, and the phrase `load_tools` offers.
public enum ToolGroups {
    public static let documents = "documents"

    public struct Group: Sendable {
        public let name: String
        public let tools: [String]
        public let phrase: String
    }

    public static let all: [Group] = [
        Group(name: documents, tools: [DocumentSpec.schema.name], phrase: "PDF documents with tables and charts"),
    ]

    public static func group(ofTool name: String) -> Group? { all.first { $0.tools.contains(name) } }
    public static func named(_ name: String) -> Group? { all.first { $0.name == name } }

    /// Every group's setting with nothing set anywhere.
    public static let builtIn: [String: ToolLoading] = [documents: .onDemand]

    /// Per group, not per field: the overlay's value, else the base's, else
    /// on demand -- an overlay that sets one group keeps the base's others.
    public static func merged(overlay: ToolLoadingMap?, base: ToolLoadingMap?) -> [String: ToolLoading] {
        var out = builtIn
        for (k, v) in base?.groups ?? [:] { out[k] = v }
        for (k, v) in overlay?.groups ?? [:] { out[k] = v }
        return out
    }

    /// `load_tools`: one string field, its values the groups offered now.
    public static func loaderSchema(groups: [Group]) -> ToolSchema {
        let list = groups.map { "\($0.name): \($0.phrase)" }.joined(separator: "; ")
        return ToolSchema("load_tools", "Make more tools available in this chat when the user's request needs them (\(list)). They work from the next step on.",
                          [.init("group", .oneOf(groups.map(\.name)), required: true, aliases: ["name", "tools"])])
    }
}

/// A profile's `toolLoading`: group → always | onDemand. Decoded leniently
/// (adr/0020): values in any case, an unknown group or value skipped with a
/// log line -- never failing the whole profile, as synthesized decoding of
/// an enum dictionary would on one bad value.
public struct ToolLoadingMap: Codable, Equatable, Sendable {
    public var groups: [String: ToolLoading]

    public init(_ groups: [String: ToolLoading]) { self.groups = groups }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        var groups: [String: ToolLoading] = [:]
        // Each entry on its own: one bad value (a number, a typo) is
        // skipped, the rest kept; not an object at all reads as none.
        if let c = try? decoder.container(keyedBy: Key.self) {
            for key in c.allKeys {
                let value = try? c.decode(String.self, forKey: key)
                guard ToolGroups.named(key.stringValue) != nil, let value, let loading = ToolLoading(lenient: value) else {
                    NSLog("LLMTray: profile toolLoading: skipped %@", key.stringValue)
                    continue
                }
                groups[key.stringValue] = loading
            }
        }
        self.groups = groups
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(groups.mapValues(\.rawValue))
    }
}
