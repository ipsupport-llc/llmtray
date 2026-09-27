import Foundation

/// One image or music generator at a time, app-wide, in the order asked
/// for: each generation takes most of the Mac's memory (and, with "unload
/// the chat model", the model with it). A request that finds one running
/// waits its turn instead of being refused. Polled rather than resumed by
/// continuations, so a waiter that stops caring (Stop, a chat switch)
/// simply leaves -- nothing to leak.
///
/// Below it, a background lane (adr/0012, Scheduling): indexing takes the
/// queue in bounded slices (one embed request, ≤ ~3 s) and holds nothing
/// across slices. A slice is granted only when no generation runs or waits;
/// a generation that asks while a slice runs gets the queue at the slice's
/// end, and `onInteractiveGrant` fires then -- the embed runner is told to
/// exit, its memory freed for the generation. `onInteractiveDemand` tells
/// the runner it is paused meanwhile, so a search doesn't start it again.
@MainActor
public final class GenerationQueue {
    public static let shared = GenerationQueue()

    public struct Cancelled: Error {}

    /// A granted turn: release() hands the generator on.
    @MainActor
    public final class Ticket {
        fileprivate weak var queue: GenerationQueue?
        fileprivate let id: UUID
        fileprivate init(queue: GenerationQueue, id: UUID) { self.queue = queue; self.id = id }

        public func release() {
            queue?.release(id)
            queue = nil
        }
    }

    /// One background slice; release it when the slice's work is done.
    @MainActor
    public final class Slice {
        fileprivate weak var queue: GenerationQueue?
        fileprivate let id: UUID
        fileprivate init(queue: GenerationQueue, id: UUID) { self.queue = queue; self.id = id }

        /// A generation is waiting: end the slice as soon as it can stop.
        public var shouldYield: Bool { queue?.hasInteractiveDemand ?? false }

        public func release() {
            queue?.releaseBackground(id)
            queue = nil
        }
    }

    private var holder: UUID?
    private var waiting: [UUID] = []
    private var backgroundHolder: UUID?
    private var backgroundWaiting: [UUID] = []
    private var lastDemand = false
    private let pollInterval: UInt64

    /// Awaited on the main actor each time a generation is granted the
    /// queue, before the ticket is handed out: the embed runner exits if it
    /// runs (started by indexing or by a search's query) and its memory is
    /// free when the generation starts (`EmbedRunner.stopAndWait`, at once
    /// when nothing runs). Wired by the indexer (3.4b).
    public var onInteractiveGrant: (() async -> Void)?

    /// Called on the main actor when `hasInteractiveDemand` changes: true
    /// once a generation asks, false when none runs or waits any more. The
    /// indexer wires it to `EmbedRunner.setPaused` -- a search meanwhile gets
    /// `.paused` and goes lexical-only instead of restarting the runner.
    /// Setting it reports the current state at once: an embedder wired up
    /// while a generation runs starts out paused, not at the next change.
    public var onInteractiveDemand: ((Bool) -> Void)? {
        didSet {
            lastDemand = hasInteractiveDemand
            onInteractiveDemand?(lastDemand)
        }
    }

    public init(pollInterval: TimeInterval = 0.2) {
        self.pollInterval = UInt64(pollInterval * 1_000_000_000)
    }

    /// Whether a generator is running or claimed (background slices aren't counted).
    public var isBusy: Bool { holder != nil }
    public var waitingCount: Int { waiting.count }
    public var isBackgroundRunning: Bool { backgroundHolder != nil }
    public var backgroundWaitingCount: Int { backgroundWaiting.count }
    /// A generation runs or waits: background slices hold off.
    public var hasInteractiveDemand: Bool { holder != nil || !waiting.isEmpty }

    private func demandMayHaveChanged() {
        let demand = hasInteractiveDemand
        guard demand != lastDemand else { return }
        lastDemand = demand
        onInteractiveDemand?(demand)
    }

    /// Waits for this request's turn. `onPosition` gets how many are ahead
    /// (the running one included) while it waits, then nil once granted.
    /// Throws Cancelled when `isCancelled` says so, or the task is cancelled.
    public func acquire(isCancelled: () -> Bool = { false }, onPosition: (Int?) -> Void = { _ in }) async throws -> Ticket {
        let id = UUID()
        waiting.append(id)
        demandMayHaveChanged()
        var lastPosition: Int?
        while true {
            if isCancelled() || Task.isCancelled {
                waiting.removeAll { $0 == id }
                demandMayHaveChanged()
                throw Cancelled()
            }
            if holder == nil, backgroundHolder == nil, waiting.first == id {
                waiting.removeFirst()
                holder = id
                if let hook = onInteractiveGrant { await hook() }
                onPosition(nil)
                return Ticket(queue: self, id: id)
            }
            // A running slice counts as one ahead: it ends at its boundary.
            let ahead = (waiting.firstIndex(of: id) ?? 0) + (holder == nil && backgroundHolder == nil ? 0 : 1)
            if ahead != lastPosition {
                lastPosition = ahead
                onPosition(ahead)
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    /// Waits for a background slice: granted when no generation runs or
    /// waits, background requests in order. Throws Cancelled like `acquire`.
    public func acquireBackground(isCancelled: () -> Bool = { false }) async throws -> Slice {
        let id = UUID()
        backgroundWaiting.append(id)
        while true {
            if isCancelled() || Task.isCancelled {
                backgroundWaiting.removeAll { $0 == id }
                throw Cancelled()
            }
            if holder == nil, waiting.isEmpty, backgroundHolder == nil, backgroundWaiting.first == id {
                backgroundWaiting.removeFirst()
                backgroundHolder = id
                return Slice(queue: self, id: id)
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    fileprivate func release(_ id: UUID) {
        if holder == id { holder = nil }
        demandMayHaveChanged()
    }

    fileprivate func releaseBackground(_ id: UUID) {
        if backgroundHolder == id { backgroundHolder = nil }
    }
}
