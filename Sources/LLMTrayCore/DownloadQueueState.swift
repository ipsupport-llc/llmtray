import Foundation

/// The download queue's bookkeeping (adr/0013): what's waiting, running,
/// done or failed, in the order it runs. Pure -- the app's DownloadQueue
/// does the downloads and reports back here. One item runs at a time; the
/// chat model goes ahead of everything still waiting (it's the one thing
/// needed to chat).
public struct DownloadQueueState: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case chatModel, imageModel, editModel, musicModel
        /// Project files' embedding model (adr/0012); its registry id.
        case embedder
    }

    public enum Status: Equatable, Codable, Sendable {
        case pending
        /// `progress`: 0...1 when the download reports it.
        case running(progress: Double?)
        case done
        case failed(String)
        case cancelled

        /// Won't change any more.
        public var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            case .pending, .running: return false
            }
        }
    }

    public struct Item: Identifiable, Equatable, Codable, Sendable {
        public let id: UUID
        public let kind: Kind
        /// What to download: a Hugging Face repo for the chat model, the
        /// model's identifier (ImageGenModel / MusicModel raw value, the
        /// embedder's registry id) for the others.
        public let target: String
        /// Expected size, for the free-space check (nil: not known yet).
        public var approxBytes: Int64?
        public var status: Status

        public init(id: UUID = UUID(), kind: Kind, target: String, approxBytes: Int64? = nil, status: Status = .pending) {
            self.id = id
            self.kind = kind
            self.target = target
            self.approxBytes = approxBytes
            self.status = status
        }
    }

    public private(set) var items: [Item] = []

    public init(items: [Item] = []) {
        self.items = items
    }

    /// The one running now.
    public var current: Item? { items.first { if case .running = $0.status { return true } else { return false } } }
    public var isRunning: Bool { current != nil }
    /// What runs next once nothing is running (queue order).
    public var nextPending: Item? { items.first { $0.status == .pending } }
    public var hasUnfinished: Bool { items.contains { !$0.status.isFinished } }

    public func item(_ id: UUID) -> Item? { items.first { $0.id == id } }

    /// Adds `item` (pending). The same kind and target already waiting or
    /// running isn't added twice: false. A chat model goes before every
    /// other item still pending -- never before the running one.
    @discardableResult
    public mutating func enqueue(_ item: Item) -> Bool {
        guard !items.contains(where: { $0.kind == item.kind && $0.target == item.target && !$0.status.isFinished })
        else { return false }
        var item = item
        item.status = .pending
        if item.kind == .chatModel,
           let firstOther = items.firstIndex(where: { $0.status == .pending && $0.kind != .chatModel }) {
            items.insert(item, at: firstOther)
        } else {
            items.append(item)
        }
        return true
    }

    /// Takes the next pending item and marks it running; nil while one is
    /// already running or nothing waits.
    public mutating func startNext() -> Item? {
        guard !isRunning, let next = nextPending, let index = index(next.id) else { return nil }
        items[index].status = .running(progress: nil)
        return items[index]
    }

    /// Progress of the running item (ignored for any other state).
    public mutating func setProgress(_ id: UUID, _ progress: Double?) {
        guard let index = index(id), case .running = items[index].status else { return }
        items[index].status = .running(progress: progress.map { min(1, max(0, $0)) })
    }

    public mutating func setApproxBytes(_ id: UUID, _ bytes: Int64?) {
        guard let index = index(id) else { return }
        items[index].approxBytes = bytes
    }

    /// The running item ended; a cancelled one stays cancelled (its
    /// download may still report back after the cancel).
    public mutating func finish(_ id: UUID, error: String? = nil) {
        guard let index = index(id), !items[index].status.isFinished else { return }
        items[index].status = error.map(Status.failed) ?? .done
    }

    /// Cancels a pending or running item; true if it was running (the
    /// download itself must then be stopped too).
    @discardableResult
    public mutating func cancel(_ id: UUID) -> Bool {
        guard let index = index(id), !items[index].status.isFinished else { return false }
        let wasRunning = items[index].status != .pending
        items[index].status = .cancelled
        return wasRunning
    }

    /// Everything not yet finished is cancelled; the running one's id, if
    /// any (to stop its download).
    public mutating func cancelAll() -> UUID? {
        let running = current?.id
        for index in items.indices where !items[index].status.isFinished {
            items[index].status = .cancelled
        }
        return running
    }

    /// A failed or cancelled item back in line (at the end, or first for a
    /// chat model, as enqueue), under a new id: a cancelled download that
    /// is still finishing reports to the old one, which is gone. The new
    /// id, nil if there was nothing to retry.
    @discardableResult
    public mutating func retry(_ id: UUID) -> UUID? {
        guard let index = index(id) else { return nil }
        switch items[index].status {
        case .failed, .cancelled:
            let old = items[index]
            let item = Item(kind: old.kind, target: old.target, approxBytes: old.approxBytes)
            guard !items.contains(where: { $0.kind == item.kind && $0.target == item.target && !$0.status.isFinished })
            else { return nil }
            items.remove(at: index)
            enqueue(item)
            return item.id
        default:
            return nil
        }
    }

    /// `id` is the running item (a download reporting back is still the
    /// one wanted).
    public func isRunning(_ id: UUID) -> Bool {
        if case .running = item(id)?.status { return true }
        return false
    }

    /// Drops what's done or cancelled (a list shown in the popover shrinks
    /// to what's left); a failed item stays, to be retried or dismissed.
    public mutating func removeFinished() {
        items.removeAll { $0.status == .done || $0.status == .cancelled }
    }

    /// Drops one finished item (a failed one the user gave up on).
    public mutating func dismiss(_ id: UUID) {
        items.removeAll { $0.id == id && $0.status.isFinished }
    }

    /// A relaunch: what was running starts over (the downloads themselves
    /// pick up what's complete: finished files and model folders).
    public mutating func resetInterrupted() {
        for index in items.indices {
            if case .running = items[index].status { items[index].status = .pending }
        }
    }

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    // MARK: - Free space

    /// Kept free beyond the download itself: a Mac with a full disk
    /// misbehaves, and a Python venv set up with a model needs room too.
    public static let freeSpaceMargin: Int64 = 2 * 1024 * 1024 * 1024

    /// Room for `bytes` on a volume with `free` bytes available; an unknown
    /// size or free space doesn't block (the download fails on its own).
    public static func hasRoom(for bytes: Int64?, free: Int64?) -> Bool {
        guard let bytes, let free else { return true }
        return free >= bytes + freeSpaceMargin
    }
}
