import Foundation

/// The App Store build's import from the Developer ID build (adr/0018 §3):
/// its Application Support/LLMTray folder, granted once in an open panel,
/// copied into the container. Chats, projects, profiles and the downloaded
/// image, music, voice and embedding models; not the runtimes (the App Store
/// build has its own), pins, telemetry or folder grants (a folder is granted
/// again in the sandbox). Nothing here is ever overwritten: an item that's
/// missing is copied whole, and of a folder that's already here, only what
/// it lacks. Copies are APFS clones on the same volume -- instant, and no
/// second copy of a model's gigabytes on disk.
public enum StandaloneImport {
    /// What's imported, under Application Support/LLMTray.
    public static let items = [
        "sessions", "projects", "profiles", "tool_call_stats.json",
        "embed_models", "mflux_models", "music_models", "voice_models",
    ]

    /// Model→profile assignments: merged, the ones already here winning.
    static let assignments = "profiles/assignments.json"

    public struct Copy: Equatable, Sendable {
        /// Which of `items` it belongs to.
        public let item: String
        public let from: URL
        public let to: URL
    }

    public struct Summary: Equatable, Sendable {
        /// Items copied (whole or in part): "sessions", "voice_models", ...
        public var imported: [String] = []
        public var assignmentsMerged = 0
    }

    /// Whether `folder` looks like LLMTray's data folder at all.
    public static func looksLikeDataFolder(_ folder: URL, fileManager fm: FileManager = .default) -> Bool {
        items.contains { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// The copies to make: each item missing in `destination` whole; of a
    /// folder there already, its missing entries (one level down: a chat, a
    /// project, a model). Never an unfinished download (".partial-") or a
    /// copy this left half-done (".import-").
    public static func plan(from source: URL, to destination: URL, fileManager fm: FileManager = .default) -> [Copy] {
        var copies: [Copy] = []
        for item in items {
            let from = source.appendingPathComponent(item), to = destination.appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &isDir) else { continue }
            guard fm.fileExists(atPath: to.path) else {
                copies.append(Copy(item: item, from: from, to: to))
                continue
            }
            guard isDir.boolValue, let entries = try? fm.contentsOfDirectory(atPath: from.path) else { continue }
            for entry in entries.sorted() where !skipped(entry) {
                let target = to.appendingPathComponent(entry)
                if item + "/" + entry == assignments { continue }   // merged instead
                if !fm.fileExists(atPath: target.path) {
                    copies.append(Copy(item: item, from: from.appendingPathComponent(entry), to: target))
                }
            }
        }
        return copies
    }

    private static func skipped(_ name: String) -> Bool {
        name.hasPrefix(".") || name.contains(".partial-") || name.contains(".import-")
    }

    /// Makes `plan`'s copies (each to a temporary name first, so an
    /// interrupted one never looks finished) and merges the assignments.
    public static func run(from source: URL, to destination: URL, fileManager fm: FileManager = .default) throws -> Summary {
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var summary = Summary()
        for copy in plan(from: source, to: destination, fileManager: fm) {
            try fm.createDirectory(at: copy.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = copy.to.deletingLastPathComponent()
                .appendingPathComponent(copy.to.lastPathComponent + ".import-" + UUID().uuidString)
            do {
                try fm.copyItem(at: copy.from, to: temporary)
                try fm.moveItem(at: temporary, to: copy.to)
            } catch {
                try? fm.removeItem(at: temporary)
                throw error
            }
            if !summary.imported.contains(copy.item) { summary.imported.append(copy.item) }
        }
        summary.assignmentsMerged = try mergeAssignments(from: source, to: destination, fileManager: fm)
        if summary.assignmentsMerged > 0, !summary.imported.contains("profiles") { summary.imported.append("profiles") }
        return summary
    }

    /// The source's assignments added to the destination's; those already
    /// there stay. Returns how many were added.
    static func mergeAssignments(from source: URL, to destination: URL, fileManager fm: FileManager) throws -> Int {
        let from = source.appendingPathComponent(assignments), to = destination.appendingPathComponent(assignments)
        guard let data = fm.contents(atPath: from.path),
              let theirs = try? JSONDecoder().decode([String: String].self, from: data) else { return 0 }
        var ours: [String: String] = [:]
        if let existing = fm.contents(atPath: to.path) {
            // Unreadable here: left as it is (the app sets such a file aside).
            guard let decoded = try? JSONDecoder().decode([String: String].self, from: existing) else { return 0 }
            ours = decoded
        }
        let added = theirs.filter { ours[$0.key] == nil }
        guard !added.isEmpty else { return 0 }
        ours.merge(added) { current, _ in current }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(ours).write(to: to, options: .atomic)
        return added.count
    }
}
