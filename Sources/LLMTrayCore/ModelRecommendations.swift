import Foundation

/// One chat model of the curated list (runtime/recommended_models.json,
/// adr/0013).
public struct RecommendedModel: Codable, Equatable, Sendable, Identifiable {
    public enum Capability: String, Codable, Sendable, CaseIterable {
        case vision, tools, reasoning
    }

    public var id: String { repo }
    /// Hugging Face repo, "org/name".
    public var repo: String
    public var title: String
    /// One plain sentence: what it's good at.
    public var summary: String
    public var capabilities: [Capability]
    public var languages: [String]
    public var license: String?
    /// The repo's files, until the Hub's live size is read.
    public var approxBytes: Int64
    /// Never offered on a Mac with less memory.
    public var minMemoryGB: Int
    /// Marked, and listed first.
    public var recommended: Bool
    /// The memory tiers it's offered in (MemoryTier).
    public var tiers: [Int]
    /// Needs a license accepted on its page and a token to download.
    public var gated: Bool

    public init(repo: String, title: String, summary: String, capabilities: [Capability] = [], languages: [String] = [],
                license: String? = nil, approxBytes: Int64, minMemoryGB: Int, recommended: Bool = false,
                tiers: [Int], gated: Bool = false) {
        self.repo = repo
        self.title = title
        self.summary = summary
        self.capabilities = capabilities
        self.languages = languages
        self.license = license
        self.approxBytes = approxBytes
        self.minMemoryGB = minMemoryGB
        self.recommended = recommended
        self.tiers = tiers
        self.gated = gated
    }

    private enum CodingKeys: String, CodingKey {
        case repo, title, summary, capabilities, languages, license, approxBytes, minMemoryGB, recommended, tiers, gated
    }

    /// Lenient where a newer list may say more: a capability this version
    /// doesn't know is left out; optional fields default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decode(String.self, forKey: .repo)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        capabilities = (try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []).compactMap(Capability.init)
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? []
        license = try c.decodeIfPresent(String.self, forKey: .license)
        approxBytes = try c.decode(Int64.self, forKey: .approxBytes)
        minMemoryGB = try c.decodeIfPresent(Int.self, forKey: .minMemoryGB) ?? 0
        recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
        tiers = try c.decode([Int].self, forKey: .tiers)
        gated = try c.decodeIfPresent(Bool.self, forKey: .gated) ?? false
    }
}

/// The curated list's memory tiers, by installed RAM: 8, 16, 24 and 32
/// (32 GB and up).
public enum MemoryTier {
    public static let all = [8, 16, 24, 32]

    /// A Mac's tier: an 18 GB Mac is a 16, 36 GB and up a 32.
    public static func tier(physicalMemoryBytes: UInt64) -> Int {
        let gb = Double(physicalMemoryBytes) / Double(1 << 30)
        if gb < 12 { return 8 }
        if gb < 20 { return 16 }
        if gb < 32 { return 24 }
        return 32
    }
}

public enum ModelRecommendations {
    /// In the app bundle's runtime folder (build_app.sh copies it).
    public static let fileName = "recommended_models.json"

    /// A model offered to this Mac: its size (live from the Hub when
    /// known) and how it fits.
    public struct Pick: Equatable, Sendable, Identifiable {
        public var id: String { model.id }
        public var model: RecommendedModel
        public var sizeBytes: Int64
        public var fit: ModelFitLevel
    }

    private struct List: Decodable {
        var models: [Entry]
    }

    /// One broken entry (a hand edit) drops that entry, not the list.
    private struct Entry: Decodable {
        var model: RecommendedModel?
        init(from decoder: Decoder) throws {
            model = try? RecommendedModel(from: decoder)
        }
    }

    /// The list's models, in its order; entries without a valid "org/name"
    /// repo, a size or a tier are left out.
    public static func parse(_ data: Data) throws -> [RecommendedModel] {
        try JSONDecoder().decode(List.self, from: data).models.compactMap(\.model).filter(isValid)
    }

    public static func load(contentsOf url: URL) throws -> [RecommendedModel] {
        try parse(Data(contentsOf: url))
    }

    private static func isValid(_ m: RecommendedModel) -> Bool {
        let parts = m.repo.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && m.approxBytes > 0
            && !m.title.isEmpty && !m.tiers.isEmpty
    }

    /// What to offer on `hardware`: the models of its memory tier that it
    /// has the memory for, whose weights fit the GPU's limit (when known)
    /// and that aren't "unlikely" by the HF browser's fit estimate.
    /// Recommended first, otherwise in the list's order. `liveSizes`: repo
    /// -> the Hub's current size, over the list's approxBytes.
    public static func picks(from models: [RecommendedModel], for hardware: HardwareInfo,
                             liveSizes: [String: Int64] = [:]) -> [Pick] {
        let memory = hardware.physicalMemoryBytes
        let tier = MemoryTier.tier(physicalMemoryBytes: memory)
        let gpuLimit = hardware.gpuLimitBytes
        let offered: [Pick] = models.compactMap { model in
            guard model.tiers.contains(tier), memory >= UInt64(max(0, model.minMemoryGB)) << 30 else { return nil }
            let size = liveSizes[model.repo] ?? model.approxBytes
            if let gpuLimit, size >= Int64(clamping: gpuLimit) { return nil }
            let fit = ModelFitLevel.estimate(sizeBytes: size, physicalMemoryBytes: memory)
            guard fit != .unlikely else { return nil }
            return Pick(model: model, sizeBytes: size, fit: fit)
        }
        return offered.filter(\.model.recommended) + offered.filter { !$0.model.recommended }
    }
}
