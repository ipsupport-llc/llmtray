import Foundation

/// A project's own data on disk (adr/0012): `projects/<id>/` beside the
/// sessions -- its files and index, once there are any -- and deleting it
/// so that a crash halfway is finished at the next launch. A deletion is
/// written down first (`<id>.deleting` beside the directory), then the
/// directory goes, then the record. A directory with neither a project nor
/// a record is never touched: nothing here sweeps by what the library
/// lacks.
public struct ProjectStorage {
    /// `.../LLMTray/projects`.
    public let root: String

    public init(root: String) {
        self.root = root
    }

    /// How library.json read at launch. Only a library that was read (or
    /// isn't there) may finish deletions: an unreadable one loads as empty,
    /// and nothing must be decided from that.
    public enum LibraryState: Equatable {
        case loaded, missing, unreadable
    }

    private static let recordSuffix = ".deleting"

    public func directory(for id: UUID) -> String {
        root + "/" + id.uuidString
    }

    func recordPath(for id: UUID) -> String {
        root + "/" + id.uuidString + Self.recordSuffix
    }

    /// The deletions written down in a listing of `root` (file names).
    static func deletionRecords(in names: [String]) -> [UUID] {
        names.compactMap { name in
            name.hasSuffix(recordSuffix) ? UUID(uuidString: String(name.dropLast(recordSuffix.count))) : nil
        }
        .sorted { $0.uuidString < $1.uuidString }
    }

    /// Deletions a crash left unfinished, to finish now: none when the
    /// library couldn't be read.
    public func pendingDeletions(library: LibraryState) -> [UUID] {
        guard library != .unreadable,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return Self.deletionRecords(in: names)
    }

    /// Step one: the record. False when it couldn't be written (the
    /// directory is still removed, but a crash before that leaves it).
    @discardableResult
    public func beginDeletion(_ id: UUID) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        return fm.createFile(atPath: recordPath(for: id), contents: Data(id.uuidString.utf8))
    }

    /// Removes the directory, then the record. False, the record kept for
    /// the next launch, when the directory couldn't be removed.
    @discardableResult
    public func finishDeletion(_ id: UUID) -> Bool {
        let fm = FileManager.default
        let dir = directory(for: id)
        if fm.fileExists(atPath: dir) {
            guard (try? fm.removeItem(atPath: dir)) != nil else { return false }
        }
        try? fm.removeItem(atPath: recordPath(for: id))
        return !fm.fileExists(atPath: recordPath(for: id))
    }
}
