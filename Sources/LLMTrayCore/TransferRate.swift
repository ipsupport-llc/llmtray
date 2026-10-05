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
        samples.append((time, bytes))
        samples.removeAll { $0.time < time - window }
        guard let first = samples.first, time - first.time >= min(1, window) else { return nil }
        if let lastReport, time - lastReport < interval { return nil }
        lastReport = time
        let speed = max(0, Double(bytes - first.bytes) / (time - first.time))
        let remaining = max(0, total - bytes)
        return (speed, speed > 0 ? Double(remaining) / speed : nil)
    }
}
