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

    /// Appends one event and syncs it to disk.
    public func append(_ event: JournalEvent, planID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var line = try Self.encoder.encode(event)
        line.append(0x0A)
        let fd = open(url(for: planID).path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FolderAccessError.system("journal open", errno) }
        defer { close(fd) }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { throw FolderAccessError.system("journal write", errno) }
        guard fsync(fd) == 0 else { throw FolderAccessError.system("journal sync", errno) }
    }

    public func record(_ planID: UUID) -> JournalRecord? {
        guard let data = try? Data(contentsOf: url(for: planID)) else { return nil }
        var events: [JournalEvent] = []
        for line in data.split(separator: 0x0A) {
            // A torn last line (a crash mid-write) is skipped: its operation
            // hadn't started.
            if let e = try? Self.decoder.decode(JournalEvent.self, from: Data(line)) { events.append(e) }
        }
        return Self.fold(planID: planID, events)
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
