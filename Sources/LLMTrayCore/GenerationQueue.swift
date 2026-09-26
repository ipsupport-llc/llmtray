import Foundation

/// One image or music generator at a time, app-wide, in the order asked
/// for: each generation takes most of the Mac's memory (and, with "unload
/// the chat model", the model with it). A request that finds one running
/// waits its turn instead of being refused. Polled rather than resumed by
/// continuations, so a waiter that stops caring (Stop, a chat switch)
/// simply leaves -- nothing to leak.
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

    private var holder: UUID?
    private var waiting: [UUID] = []
    private let pollInterval: UInt64

    public init(pollInterval: TimeInterval = 0.2) {
        self.pollInterval = UInt64(pollInterval * 1_000_000_000)
    }

    /// Whether a generator is running or claimed.
    public var isBusy: Bool { holder != nil }
    public var waitingCount: Int { waiting.count }

    /// Waits for this request's turn. `onPosition` gets how many are ahead
    /// (the running one included) while it waits, then nil once granted.
    /// Throws Cancelled when `isCancelled` says so, or the task is cancelled.
    public func acquire(isCancelled: () -> Bool = { false }, onPosition: (Int?) -> Void = { _ in }) async throws -> Ticket {
        let id = UUID()
        waiting.append(id)
        var lastPosition: Int?
        while true {
            if isCancelled() || Task.isCancelled {
                waiting.removeAll { $0 == id }
                throw Cancelled()
            }
            if holder == nil, waiting.first == id {
                waiting.removeFirst()
                holder = id
                onPosition(nil)
                return Ticket(queue: self, id: id)
            }
            let ahead = (waiting.firstIndex(of: id) ?? 0) + (holder == nil ? 0 : 1)
            if ahead != lastPosition {
                lastPosition = ahead
                onPosition(ahead)
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    fileprivate func release(_ id: UUID) {
        if holder == id { holder = nil }
    }
}
