import Foundation

/// One chat model of the curated list (runtime/recommended_models.json,
/// adr/0013).
public struct RecommendedModel: Codable, Equatable, Sendable, Identifiable {
    public enum Capability: String, Codable, Sendable, CaseIterable {
        /// `code`: made for programming and agents -- offered as that, not
        /// ranked against the general models. `audio`: hears speech and
        /// sounds (an audio tower or audio embedder).
        case vision, audio, tools, reasoning, code
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
    /// Never offered on a Mac with less memory. Above it, offered on every
    /// Mac it fits (the ladder: a bigger Mac sees the smaller models too).
    public var minMemoryGB: Int
    /// The memory tiers (MemoryTier) it's the recommended model of: marked
    /// and listed first there.
    public var recommendedFor: [Int]
    /// Needs a license accepted on its page and a token to download.
    public var gated: Bool

    public init(repo: String, title: String, summary: String, capabilities: [Capability] = [], languages: [String] = [],
                license: String? = nil, approxBytes: Int64, minMemoryGB: Int, recommendedFor: [Int] = [],
                gated: Bool = false) {
        self.repo = repo
        self.title = title
        self.summary = summary
        self.capabilities = capabilities
        self.languages = languages
        self.license = license
        self.approxBytes = approxBytes
        self.minMemoryGB = minMemoryGB
        self.recommendedFor = recommendedFor
        self.gated = gated
    }

    private enum CodingKeys: String, CodingKey {
        case repo, title, summary, capabilities, languages, license, approxBytes, minMemoryGB, recommendedFor, gated
        // A list from before the ladder: offered in `tiers`, recommended
        // there when `recommended`.
        case recommended, tiers
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(repo, forKey: .repo)
        try c.encode(title, forKey: .title)
        try c.encode(summary, forKey: .summary)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encode(languages, forKey: .languages)
        try c.encodeIfPresent(license, forKey: .license)
        try c.encode(approxBytes, forKey: .approxBytes)
        try c.encode(minMemoryGB, forKey: .minMemoryGB)
        try c.encode(recommendedFor, forKey: .recommendedFor)
        try c.encode(gated, forKey: .gated)
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
        if let tiers = try c.decodeIfPresent([Int].self, forKey: .recommendedFor) {
            recommendedFor = tiers
        } else {
            let old = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
            recommendedFor = old ? try c.decodeIfPresent([Int].self, forKey: .tiers) ?? [] : []
        }
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
        public var role: Role = .alternative

        /// Where it stands on this Mac, for its label.
        public enum Role: Equatable, Sendable {
            /// This Mac's recommended model.
            case recommended
            /// Smaller than the recommended one: faster, leaves memory to
            /// other apps, simpler answers.
            case lighter
            /// Bigger than the recommended one: better answers, slower, less
            /// memory left.
            case larger
            /// Made for programming and agents (`code`).
            case forCode
            /// No recommended model to compare with here.
            case alternative
        }

        public init(model: RecommendedModel, sizeBytes: Int64, fit: ModelFitLevel, role: Role = .alternative) {
            self.model = model
            self.sizeBytes = sizeBytes
            self.fit = fit
            self.role = role
        }
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
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && m.approxBytes > 0 && !m.title.isEmpty
    }

    /// What to offer on `hardware` -- the ladder: every model it has the
    /// memory for (`minMemoryGB`), whose weights fit the GPU's limit (when
    /// known) and that isn't "unlikely" by the HF browser's fit estimate.
    /// Its tier's recommended model first, then the general ones from the
    /// biggest down, then the ones made for code; each with its role
    /// against the recommended one. `liveSizes`: repo -> the Hub's current
    /// size, over the list's approxBytes.
    public static func picks(from models: [RecommendedModel], for hardware: HardwareInfo,
                             liveSizes: [String: Int64] = [:]) -> [Pick] {
        let memory = hardware.physicalMemoryBytes
        let tier = MemoryTier.tier(physicalMemoryBytes: memory)
        let gpuLimit = hardware.gpuLimitBytes
        var offered: [Pick] = models.compactMap { model in
            guard memory >= UInt64(max(0, model.minMemoryGB)) << 30 else { return nil }
            let size = liveSizes[model.repo] ?? model.approxBytes
            if let gpuLimit, size >= Int64(clamping: gpuLimit) { return nil }
            let fit = ModelFitLevel.estimate(sizeBytes: size, physicalMemoryBytes: memory)
            guard fit != .unlikely else { return nil }
            return Pick(model: model, sizeBytes: size, fit: fit)
        }
        let recommended = offered.first { $0.model.recommendedFor.contains(tier) }
        for i in offered.indices {
            let pick = offered[i]
            if pick.id == recommended?.id {
                offered[i].role = .recommended
            } else if pick.model.capabilities.contains(.code) {
                offered[i].role = .forCode
            } else if let recommended {
                offered[i].role = pick.sizeBytes < recommended.sizeBytes ? .lighter : .larger
            }
        }
        let general = offered.filter { $0.role != .recommended && $0.role != .forCode }.sorted { $0.sizeBytes > $1.sizeBytes }
        let forCode = offered.filter { $0.role == .forCode }.sorted { $0.sizeBytes > $1.sizeBytes }
        return offered.filter { $0.role == .recommended } + general + forCode
    }
}
