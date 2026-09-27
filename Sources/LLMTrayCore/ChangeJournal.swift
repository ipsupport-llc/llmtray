import Darwin
import Foundation

/// What an executed item left behind: enough to find it again by identity
/// and reverse it (Hardening 7).
public struct JournalResult: Codable, Equatable, Sendable {
    /// The item's identity after the operation (the made folder, the moved
    /// or trashed item).
    public var identity: FileIdentity
    /// The name the file system took (differs from the asked one after
    /// "keep both").
    public var finalName: String?
    /// Identities from the destination's root down to its parent, as they
    /// were when the operation ran.
    public var destinationChain: [FileIdentity]?
    /// Where the Trash put the item (the name may differ); nil when the
    /// system didn't say.
    public var trashURL: String?
    /// Where the item is now, below the destination's root (make_dir, move).
    public var components: [String]?

    public var device: Int32 { identity.device }
}

/// One line of a journal file: JSON Lines, appended and synced before and
/// after each operation, so a crash leaves a "pending" line without its
/// outcome.
public struct JournalEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case begin, pending, done, failed, end
        /// Ran, outcome not established: stays incomplete.
        case uncertain
        case undoPending = "undo_pending", undone, undoFailed = "undo_failed"
    }

    public var kind: Kind
    public var date: Date
    public var item: Int?
    public var chatID: String?
    public var planItem: PlanItem?
    public var result: JournalResult?
    public var message: String?
}

/// A plan's journal, folded from its events.
public struct JournalRecord: Equatable, Sendable {
    public enum ItemState: Equatable, Sendable {
        /// Started and never finished: the outcome is unknown (a crash).
        case incomplete
        /// Ran, and what it did couldn't be established: look.
        case uncertain(String)
        case done(JournalResult)
        case failed(String)
        /// Reversed by undo.
        case undone
        /// Undo started and never finished (a crash): unknown.
        case undoIncomplete(JournalResult)
    }

    public struct Item: Equatable, Sendable {
        public var planItem: PlanItem
        public var state: ItemState
    }

    public var planID: UUID
    public var chatID: String
    public var started: Date
    public var ended: Date?
    public var items: [Item]

    /// A crash mid-plan (or mid-undo): no end, or an item without its outcome.
    public var isIncomplete: Bool {
        ended == nil || items.contains {
            if case .incomplete = $0.state { return true }
            if case .uncertain = $0.state { return true }
            if case .undoIncomplete = $0.state { return true }
            return false
        }
    }
}

/// The durable journal of folder changes: one JSON Lines file per plan
/// under `directory` (the app's Application Support by default; injectable
/// for tests). A write that fails before an operation stops the operation.
public final class ChangeJournal: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("LLMTray/FolderJournal", isDirectory: true)
    }

    func url(for planID: UUID) -> URL { directory.appendingPathComponent(planID.uuidString + ".jsonl") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Tests make appends fail here.
    var appendHook: ((JournalEvent) throws -> Void)?

    /// Appends one event and syncs it to disk. A torn last line (a crash
    /// mid-write) is closed off first, so it can't swallow this one; a new
    /// file's directory entry is synced too.
    public func append(_ event: JournalEvent, planID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try appendHook?(event)
        try Self.makeDurably(directory.path)
        var line = try Self.encoder.encode(event)
        line.append(0x0A)
        let path = url(for: planID).path
        let isNew = Posix.lstatPath(path) == nil
        let fd = open(path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FolderAccessError.system("journal open", errno) }
        defer { close(fd) }
        let size = lseek(fd, 0, SEEK_END)
        if size > 0 {
            var last: UInt8 = 0
            if pread(fd, &last, 1, size - 1) == 1, last != 0x0A { line.insert(0x0A, at: 0) }
        }
        var written = 0
        while written < line.count {
            let n = line.withUnsafeBytes { write(fd, $0.baseAddress! + written, $0.count - written) }
            if n < 0 {
                if errno == EINTR { continue }
                throw FolderAccessError.system("journal write", errno)
            }
            written += n
        }
        guard fsync(fd) == 0 else { throw FolderAccessError.system("journal sync", errno) }
        if isNew { try Self.syncDirectory(directory.path) }
    }

    /// Makes each missing folder of `path`, outermost first, syncing its
    /// parent after each: a crash can't lose a folder the journal is in.
    static func makeDurably(_ path: String) throws {
        var missing: [String] = []
        var p = path
        while Posix.lstatPath(p) == nil, p != "/", !p.isEmpty {
            missing.append(p)
            p = (p as NSString).deletingLastPathComponent
        }
        for dir in missing.reversed() {
            if mkdir(dir, 0o700) != 0, errno != EEXIST { throw FolderAccessError.system("journal folder", errno) }
            try syncDirectory((dir as NSString).deletingLastPathComponent)
        }
    }

    /// A new entry in `path` is on disk only once the folder itself is synced.
    static func syncDirectory(_ path: String) throws {
        let dfd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dfd >= 0 else { throw FolderAccessError.system("journal sync", errno) }
        defer { close(dfd) }
        guard fsync(dfd) == 0 else { throw FolderAccessError.system("journal sync", errno) }
    }

    /// Journals are read up to this many bytes (a plan's is a few KB); past
    /// it the record shows as incomplete.
    public var maxRecordBytes = 16 << 20

    /// Whether a journal exists for the plan (it has started).
    public func exists(_ planID: UUID) -> Bool { Posix.lstatPath(url(for: planID).path) != nil }

    public func record(_ planID: UUID) -> JournalRecord? {
        guard let handle = try? FileHandle(forReadingFrom: url(for: planID)) else { return nil }
        defer { try? handle.close() }
        guard var data = try? handle.read(upToCount: maxRecordBytes + 1) else { return nil }
        let truncated = data.count > maxRecordBytes
        if truncated { data = data.prefix(maxRecordBytes) }
        var events: [JournalEvent] = []
        for line in data.split(separator: 0x0A) {
            // A torn last line (a crash mid-write) is skipped: its operation
            // hadn't started.
            if let e = try? Self.decoder.decode(JournalEvent.self, from: Data(line)) { events.append(e) }
        }
        var record = Self.fold(planID: planID, events)
        if truncated { record?.ended = nil }
        return record
    }

    /// Every plan in the journal, newest first.
    public func records() -> [JournalRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> JournalRecord? in
            guard name.hasSuffix(".jsonl"), let id = UUID(uuidString: String(name.dropLast(6))) else { return nil }
            return record(id)
        }.sorted { $0.started > $1.started }
    }

    static func fold(planID: UUID, _ events: [JournalEvent]) -> JournalRecord? {
        guard let begin = events.first, begin.kind == .begin else { return nil }
        var rec = JournalRecord(planID: planID, chatID: begin.chatID ?? "", started: begin.date, ended: nil, items: [])
        func index(_ id: Int?) -> Int? { rec.items.firstIndex { $0.planItem.id == id } }
        for e in events.dropFirst() {
            switch e.kind {
            case .begin: break
            case .pending:
                if let p = e.planItem { rec.items.append(.init(planItem: p, state: .incomplete)) }
            case .done:
                if let i = index(e.item), let r = e.result { rec.items[i].state = .done(r) }
            case .failed:
                if let i = index(e.item) { rec.items[i].state = .failed(e.message ?? "failed") }
            case .uncertain:
                if let i = index(e.item) { rec.items[i].state = .uncertain(e.message ?? "uncertain") }
            case .end:
                rec.ended = e.date
            case .undoPending:
                if let i = index(e.item), case .done(let r) = rec.items[i].state { rec.items[i].state = .undoIncomplete(r) }
            case .undone:
                if let i = index(e.item) { rec.items[i].state = .undone }
            case .undoFailed:
                // Undo didn't change it: back to done.
                if let i = index(e.item), case .undoIncomplete(let r) = rec.items[i].state { rec.items[i].state = .done(r) }
            }
        }
        return rec
    }
}
