import Foundation

/// A download's speed and time left, steady enough to read: the average over
/// the last `window` seconds (chunks arrive unevenly, so a half-second rate
/// jumps), updated at most every `interval` seconds.
public struct TransferRate: Sendable {
    public let window: TimeInterval
    public let interval: TimeInterval
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var lastReport: TimeInterval?

    public init(window: TimeInterval = 10, interval: TimeInterval = 1) {
        self.window = window
        self.interval = interval
    }

    /// Starts over (a new download, or a resume after a pause: the paused
    /// time isn't counted as no throughput).
    public mutating func reset() {
        samples.removeAll()
        lastReport = nil
    }

    /// Adds the bytes written so far at `time` (seconds, any monotonic clock).
    /// Returns the speed (bytes/s) and time left when it's time to show
    /// them, else nil: not before a second of samples, then once per interval.
    public mutating func add(bytes: Int64, total: Int64, at time: TimeInterval) -> (speed: Double, eta: TimeInterval?)? {
        // Fewer bytes than before: the file started over (a CDN restart).
        if let last = samples.last, bytes < last.bytes { reset() }
        // A sample per quarter-second is plenty for a 10 s average; a fast
        // download calls this thousands of times a second.
        if let last = samples.last, time - last.time < 0.25, lastReport != nil, time - (lastReport ?? 0) < interval {
            return nil
        }
        samples.append((time, bytes))
        if let cut = samples.firstIndex(where: { $0.time >= time - window }), cut > 0 { samples.removeFirst(cut) }
        guard let first = samples.first, time - first.time >= min(1, window) else { return nil }
        if let lastReport, time - lastReport < interval { return nil }
        lastReport = time
        let speed = max(0, Double(bytes - first.bytes) / (time - first.time))
        let remaining = max(0, total - bytes)
        return (speed, speed > 0 ? Double(remaining) / speed : nil)
    }
}
