import Foundation

/// The App Store build's import from the Developer ID build (adr/0018 §3):
/// its Application Support/LLMTray folder, granted once in an open panel,
/// copied into the container. Chats, projects, profiles, tool stats and the
/// downloaded image, music, voice and embedding models; not the runtimes
/// (the App Store build has its own), pins, telemetry or folder grants (a
/// folder is granted again in the sandbox). Copies are APFS clones on the
/// same volume -- instant, and no second copy of a model's gigabytes.
///
/// Nothing here is overwritten: an item that's missing is copied whole, and
/// of a folder that's already here, only the entries it lacks. Three files
/// are merged instead of skipped: the chat library (projects, pins, which
/// chat is in which project), the model→profile assignments (those here
/// win), and the Default profile (theirs replaces ours only while ours is
/// still the untouched one; otherwise it comes as a profile of its own).
/// The app relaunches right after, so nothing it holds in memory is written
/// over what came in.
public enum StandaloneImport {
    /// What's imported, under Application Support/LLMTray.
    public static let items = [
        "sessions", "projects", "profiles", "tool_call_stats.json",
        "embed_models", "mflux_models", "music_models", "voice_models",
    ]

    static let library = "sessions/library.json"
    static let assignments = "profiles/assignments.json"
    static let defaultProfile = "profiles/\(Profile.defaultID).json"
    /// The id the Developer ID build's Default gets when ours was edited.
    static let importedDefaultID = "imported-default"
    private static var merged: Set<String> { [library, assignments, defaultProfile] }

    public struct Copy: Equatable, Sendable {
        /// Which of `items` it belongs to.
        public let item: String
        public let from: URL
        public let to: URL
    }

    public struct Summary: Equatable, Sendable {
        /// Items copied or merged into: "sessions", "voice_models", ...
        public var imported: [String] = []
        public var projectsAdded = 0
        public var assignmentsAdded = 0
        /// Their Default replaced ours (untouched) or came as its own profile.
        public var defaultProfile: DefaultProfileOutcome = .unchanged

        public enum DefaultProfileOutcome: Equatable, Sendable {
            case unchanged, replaced, addedAsProfile
        }

        mutating func mark(_ item: String) {
            if !imported.contains(item) { imported.append(item) }
        }
    }

    /// Whether `folder` looks like LLMTray's data folder at all.
    public static func looksLikeDataFolder(_ folder: URL, fileManager fm: FileManager = .default) -> Bool {
        items.contains { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// The copies to make: each item missing in `destination` whole; of a
    /// folder there already, its missing entries (one level down: a chat, a
    /// project, a model), less the merged files.
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
            for entry in entries.sorted() where !isLeftOut(entry) && !merged.contains(item + "/" + entry) {
                let target = to.appendingPathComponent(entry)
                if !fm.fileExists(atPath: target.path) {
                    copies.append(Copy(item: item, from: from.appendingPathComponent(entry), to: target))
                }
            }
        }
        return copies
    }

    /// Never brought over, at any depth: an unfinished download, a copy this
    /// left half-done, a project being deleted, a file set aside as
    /// unreadable, Finder's litter.
    static func isLeftOut(_ name: String) -> Bool {
        name == ".DS_Store" || name.contains(".partial-") || name.contains(".import-")
            || name.hasSuffix(".deleting") || name.contains(".unreadable-") || name.contains(".corrupt-")
    }

    /// Makes `plan`'s copies (each to a temporary name first, so an
    /// interrupted one never looks finished; a target that appeared
    /// meanwhile is left alone) and the merges. `untouchedDefault`: the
    /// Default profile this install would have now if nobody had edited it
    /// (ProfileStore.migratedDefault of the current settings).
    public static func run(from source: URL, to destination: URL, untouchedDefault: Profile?,
                           fileManager fm: FileManager = .default) throws -> Summary {
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        removeLeftoverCopies(in: destination, fileManager: fm)
        var summary = Summary()
        for copy in plan(from: source, to: destination, fileManager: fm) {
            try fm.createDirectory(at: copy.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = copy.to.deletingLastPathComponent()
                .appendingPathComponent(copy.to.lastPathComponent + ".import-" + UUID().uuidString)
            do {
                try fm.copyItem(at: copy.from, to: temporary)
                prune(temporary, fileManager: fm)
                if fm.fileExists(atPath: copy.to.path) {
                    try? fm.removeItem(at: temporary)
                    continue
                }
                try fm.moveItem(at: temporary, to: copy.to)
            } catch {
                try? fm.removeItem(at: temporary)
                throw error
            }
            summary.mark(copy.item)
        }
        summary.projectsAdded = try mergeLibrary(from: source, to: destination, fileManager: fm)
        if summary.projectsAdded > 0 { summary.mark("sessions") }
        summary.assignmentsAdded = try mergeAssignments(from: source, to: destination, fileManager: fm)
        summary.defaultProfile = try mergeDefaultProfile(from: source, to: destination, untouched: untouchedDefault, fileManager: fm)
        if summary.assignmentsAdded > 0 || summary.defaultProfile != .unchanged { summary.mark("profiles") }
        return summary
    }

    /// What `isLeftOut` names, removed from a fresh copy at every depth.
    private static func prune(_ root: URL, fileManager fm: FileManager) {
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        var doomed: [URL] = []
        for case let url as URL in walker where isLeftOut(url.lastPathComponent) {
            doomed.append(url)
            walker.skipDescendants()
        }
        for url in doomed { try? fm.removeItem(at: url) }
    }

    /// A copy an earlier import left half-done (the app quit mid-way).
    private static func removeLeftoverCopies(in destination: URL, fileManager fm: FileManager) {
        let levels = [destination] + items.map { destination.appendingPathComponent($0) }
        for dir in levels {
            for entry in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where entry.contains(".import-") {
                try? fm.removeItem(at: dir.appendingPathComponent(entry))
            }
        }
    }

    /// The chat library's dates are ISO 8601 (ChatLibraryStore); profiles
    /// and assignments have none.
    private static func decode<T: Decodable>(_ type: T.Type, at url: URL, fileManager fm: FileManager) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return fm.contents(atPath: url.path).flatMap { try? decoder.decode(type, from: $0) }
    }

    private static func write<T: Encodable>(_ value: T, to url: URL, fileManager fm: FileManager) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// Their projects, pins and chat→project links added to ours (ours win
    /// where both have one). Returns how many projects were added. Ours
    /// unreadable: left as it is (the app sets such a file aside).
    static func mergeLibrary(from source: URL, to destination: URL, fileManager fm: FileManager) throws -> Int {
        let to = destination.appendingPathComponent(library)
        guard let theirs = decode(ChatLibrary.self, at: source.appendingPathComponent(library), fileManager: fm),
              fm.fileExists(atPath: to.path), var ours = decode(ChatLibrary.self, at: to, fileManager: fm)
        else { return 0 }
        let before = ours
        let known = Set(ours.projects.map(\.id))
        let added = theirs.projects.filter { !known.contains($0.id) }
        ours.projects += added
        ours.pinned += theirs.pinned.filter { !ours.pinned.contains($0) }
        ours.projectOfChat.merge(theirs.projectOfChat) { current, _ in current }
        if ours != before { try write(ours, to: to, fileManager: fm) }
        return added.count
    }

    /// Their model→profile assignments added to ours; ours stay. Returns how
    /// many were added.
    static func mergeAssignments(from source: URL, to destination: URL, fileManager fm: FileManager) throws -> Int {
        let to = destination.appendingPathComponent(assignments)
        guard let theirs = decode([String: String].self, at: source.appendingPathComponent(assignments), fileManager: fm)
        else { return 0 }
        var ours: [String: String] = [:]
        if fm.fileExists(atPath: to.path) {
            guard let decoded = decode([String: String].self, at: to, fileManager: fm) else { return 0 }
            ours = decoded
        }
        let added = theirs.filter { ours[$0.key] == nil }
        guard !added.isEmpty else { return 0 }
        ours.merge(added) { current, _ in current }
        try write(ours, to: to, fileManager: fm)
        return added.count
    }

    /// Their Default: in place of ours while ours is untouched, else as a
    /// profile of its own ("Default (ipsupport.us)"), once.
    static func mergeDefaultProfile(from source: URL, to destination: URL, untouched: Profile?,
                                    fileManager fm: FileManager) throws -> Summary.DefaultProfileOutcome {
        let to = destination.appendingPathComponent(defaultProfile)
        guard var theirs = decode(Profile.self, at: source.appendingPathComponent(defaultProfile), fileManager: fm),
              fm.fileExists(atPath: to.path) else { return .unchanged }
        let ours = decode(Profile.self, at: to, fileManager: fm)
        theirs.id = Profile.defaultID
        if ours == theirs { return .unchanged }
        if let ours, let untouched, ours == untouched {
            try write(theirs, to: to, fileManager: fm)
            return .replaced
        }
        let aside = destination.appendingPathComponent("profiles/\(importedDefaultID).json")
        guard !fm.fileExists(atPath: aside.path) else { return .unchanged }
        theirs.id = importedDefaultID
        theirs.name = "Default (ipsupport.us)"
        try write(theirs, to: aside, fileManager: fm)
        return .addedAsProfile
    }
}
