import CryptoKit
import Foundation

/// One embedder of `runtime/embedders.json` (adr/0012): configuration, not
/// code. The runner reads the same file; this side needs what to download
/// and check, and what a vector set records.
public struct EmbedderEntry: Decodable, Equatable, Sendable {
    public struct Source: Decodable, Equatable, Sendable {
        public var repo: String
        public var revision: String
        /// File name → sha256 (hex).
        public var files: [String: String]
        public var bytes: Int64
    }
    public struct Reference: Decodable, Equatable, Sendable {
        public var file: String
        public var sha256: String
        public var minCosine: Double
        enum CodingKeys: String, CodingKey { case file, sha256, minCosine = "min_cosine" }
    }

    public var id: String
    public var displayName: String
    public var license: String
    public var family: String
    public var source: Source
    public var pooling: String
    public var dim: Int
    public var preprocessingVersion: Int
    public var memoryBytes: Int64?
    public var reference: Reference

    enum CodingKeys: String, CodingKey {
        case id, license, family, source, pooling, dim, reference
        case displayName = "display_name"
        case preprocessingVersion = "preprocessing_version"
        case memoryBytes = "memory_bytes"
    }

    /// What a vector set is keyed by: a change of either re-embeds.
    public var vectorSetModel: String { "\(id)@\(source.revision)" }
}

public struct EmbedderRegistry: Decodable, Equatable, Sendable {
    public var defaultID: String
    public var embedders: [EmbedderEntry]

    enum CodingKeys: String, CodingKey { case defaultID = "default", embedders }

    public enum Invalid: Error, Equatable {
        case unknownDefault(String)
        /// Qwen models are never used (the user's rule).
        case forbidden(String)
        case unpinned(String)
    }

    public static let families: Set<String> = ["xlm-roberta", "gemma3-bidir"]

    public func entry(_ id: String) -> EmbedderEntry? { embedders.first { $0.id == id } }

    public static func load(from url: URL) throws -> EmbedderRegistry {
        let registry = try JSONDecoder().decode(EmbedderRegistry.self, from: Data(contentsOf: url))
        try registry.validate()
        return registry
    }

    public func validate() throws {
        guard entry(defaultID) != nil else { throw Invalid.unknownDefault(defaultID) }
        for e in embedders {
            let names = [e.id, e.displayName, e.source.repo, e.family].map { $0.lowercased() }
            if names.contains(where: { $0.contains("qwen") }) { throw Invalid.forbidden(e.id) }
            let hex = CharacterSet(charactersIn: "0123456789abcdef")
            let pinned = e.source.revision.count == 40 && !e.source.files.isEmpty
                && e.source.files.values.allSatisfy { $0.count == 64 && $0.unicodeScalars.allSatisfy(hex.contains) }
                && e.reference.sha256.count == 64 && Self.families.contains(e.family)
            if !pinned { throw Invalid.unpinned(e.id) }
        }
    }
}

/// The downloaded files of an entry, checked against their pins.
public enum EmbedderFiles {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Files missing or not matching their sha256 (empty: all good).
    public static func mismatches(in folder: URL, for entry: EmbedderEntry) -> [String] {
        entry.source.files.keys.sorted().filter { name in
            let url = folder.appendingPathComponent(name)
            return (try? sha256(of: url)) != entry.source.files[name]
        }
    }
}
