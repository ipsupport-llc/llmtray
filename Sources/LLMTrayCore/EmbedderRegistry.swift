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
        /// What the weights were converted from (`org/model@revision`).
        public var upstream: String?
    }
    public struct TokenizerFile: Decodable, Equatable, Sendable {
        public var file: String?
    }
    /// A sentence-transformers Dense head (EmbeddingGemma).
    public struct DenseHead: Decodable, Equatable, Sendable {
        public var file: String
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
    public var tokenizer: TokenizerFile?
    public var dense: [DenseHead]?

    /// Every file the runner reads from the model folder by name -- each must
    /// be pinned in `source.files` (so it is sha-checked after the download).
    public var referencedFiles: [String] {
        ["config.json", tokenizer?.file ?? "tokenizer.json"] + (dense ?? []).map(\.file)
    }

    enum CodingKeys: String, CodingKey {
        case id, license, family, source, pooling, dim, reference, tokenizer, dense
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
        /// A file the runner reads that isn't pinned (or no weights at all).
        case unpinnedFile(entry: String, file: String)
    }

    public static let families: Set<String> = ["xlm-roberta", "gemma3-bidir"]

    /// What the runner loads as weights (only the pinned ones).
    public static func isWeightsFile(_ name: String) -> Bool {
        name.hasPrefix("model") && name.hasSuffix(".safetensors") && !name.contains("/")
    }

    public func entry(_ id: String) -> EmbedderEntry? { embedders.first { $0.id == id } }

    public static func load(from url: URL) throws -> EmbedderRegistry {
        let registry = try JSONDecoder().decode(EmbedderRegistry.self, from: Data(contentsOf: url))
        try registry.validate()
        return registry
    }

    public func validate() throws {
        guard entry(defaultID) != nil else { throw Invalid.unknownDefault(defaultID) }
        for e in embedders {
            let names = [e.id, e.displayName, e.source.repo, e.source.upstream ?? "", e.family].map { $0.lowercased() }
            if names.contains(where: { $0.contains("qwen") }) { throw Invalid.forbidden(e.id) }
            let hex = CharacterSet(charactersIn: "0123456789abcdef")
            let pinned = e.source.revision.count == 40 && !e.source.files.isEmpty
                && e.source.files.values.allSatisfy { $0.count == 64 && $0.unicodeScalars.allSatisfy(hex.contains) }
                && e.reference.sha256.count == 64 && Self.families.contains(e.family)
            if !pinned { throw Invalid.unpinned(e.id) }
            for file in e.referencedFiles where e.source.files[file] == nil { throw Invalid.unpinnedFile(entry: e.id, file: file) }
            if !e.source.files.keys.contains(where: Self.isWeightsFile) { throw Invalid.unpinnedFile(entry: e.id, file: "model*.safetensors") }
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

/// An entry's folder of weights (adr/0012): installed, checked and repaired
/// by the files' sha256, not by the revision stamp alone -- a folder whose
/// stamp says "done" can still hold a damaged file, and a download must
/// then fix it instead of trusting the stamp.
public enum EmbedderInstall {
    /// Written into the folder once every file matched its checksum: the
    /// revision it holds. A folder without it (or with another) isn't ready.
    public static let stampName = ".llmtray-revision"

    public struct ChecksumMismatch: Error, Equatable {
        public let files: [String]
    }

    /// The cheap check (no hashing): the folder's stamp is this revision.
    public static func isStamped(_ entry: EmbedderEntry, at folder: URL) -> Bool {
        let stamp = try? String(contentsOf: folder.appendingPathComponent(stampName), encoding: .utf8)
        return stamp?.trimmingCharacters(in: .whitespacesAndNewlines) == entry.source.revision
    }

    /// Hashes every file; any that doesn't match takes the stamp away, so
    /// the folder isn't ready and the next `install` repairs it. For a
    /// runner that failed to load. Returns the damaged or missing files.
    @discardableResult
    public static func verify(_ entry: EmbedderEntry, at folder: URL) async throws -> [String] {
        let bad = try await ProcessRunner.offMain { EmbedderFiles.mismatches(in: folder, for: entry) }
        if !bad.isEmpty { try? FileManager.default.removeItem(at: folder.appendingPathComponent(stampName)) }
        return bad
    }

    /// Installs `entry` into `folder`, or repairs it: every file is hashed;
    /// only the missing or mismatching ones are fetched (`fetch(names,
    /// into)`, into a temporary folder beside it), the good ones linked
    /// over, the whole set checked again, stamped, and swapped in -- the
    /// folder in place is never half-written. Returns the files fetched
    /// ([]: nothing to do).
    @discardableResult
    public static func install(_ entry: EmbedderEntry, at folder: URL,
                               fetch: (_ files: [String], _ into: URL) async throws -> Void) async throws -> [String] {
        let fm = FileManager.default
        let bad = try await ProcessRunner.offMain { EmbedderFiles.mismatches(in: folder, for: entry) }
        if bad.isEmpty {
            if !isStamped(entry, at: folder) {
                try entry.source.revision.write(to: folder.appendingPathComponent(stampName), atomically: true, encoding: .utf8)
            }
            return []
        }
        let temp = folder.deletingLastPathComponent().appendingPathComponent("\(folder.lastPathComponent).partial-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            try await fetch(bad, temp)
            // The good files come over as hard links (same volume: no copy).
            for name in entry.source.files.keys.sorted() where !bad.contains(name) {
                let target = temp.appendingPathComponent(name)
                guard !fm.fileExists(atPath: target.path) else { continue }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.linkItem(at: folder.appendingPathComponent(name), to: target)
            }
            let still = try await ProcessRunner.offMain { EmbedderFiles.mismatches(in: temp, for: entry) }
            guard still.isEmpty else { throw ChecksumMismatch(files: still) }
            try entry.source.revision.write(to: temp.appendingPathComponent(stampName), atomically: true, encoding: .utf8)
            if fm.fileExists(atPath: folder.path) {
                // One atomic exchange: the verified folder in, the old one
                // out under the temp name (deleted now, or swept as a
                // partial after a crash) -- never a moment with neither.
                guard renamex_np(temp.path, folder.path, UInt32(RENAME_SWAP)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } else {
                try fm.moveItem(at: temp, to: folder)
            }
            try? fm.removeItem(at: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        return bad
    }
}

/// One runner per embedder entry, shared by every caller while it lives
/// (held weakly): stopping an entry's runner -- before its weights are
/// removed -- then stops the only one there is, never leaving another
/// behind.
@MainActor
public final class EmbedRunnerPool {
    private struct Weak { weak var runner: EmbedRunner? }
    private var runners: [String: Weak] = [:]
    private var held: Set<String> = []

    public init() {}

    /// The entry's live runner, or a new one from `make` (held too while
    /// the entry is).
    public func runner(for id: String, make: () -> EmbedRunner) -> EmbedRunner {
        if let live = runners[id]?.runner { return live }
        let runner = make()
        if held.contains(id) { runner.setHeld(true) }
        runners[id] = Weak(runner: runner)
        return runner
    }

    /// Stops the entry's runner, waits for it to exit, and keeps it from
    /// starting again -- no caller's request, no waiter's respawn -- until
    /// `release`: its files can be replaced or removed meanwhile.
    public func hold(_ id: String) async {
        held.insert(id)
        guard let runner = runners[id]?.runner else { return }
        runner.setHeld(true)
        await runner.stopAndWait()
    }

    public func release(_ id: String) {
        held.remove(id)
        runners[id]?.runner?.setHeld(false)
    }
}
