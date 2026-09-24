import Foundation

/// Watches mlx_lm.server's output for a failure the process survives: its
/// generation thread can die (Metal out of memory, most often) while the
/// HTTP side lives on and refuses every request at once -- nothing stalls,
/// so the stall watchdog never fires.
public struct ServerLogWatch {
    public enum Event: Equatable {
        /// `reason` is the exception mlx_lm logged.
        case generationThreadDied(reason: String, outOfMemory: Bool)
    }

    /// mlx_lm.server logs this once, at ERROR level, when the thread dies
    /// ("%(asctime)s - %(levelname)s - %(message)s"). Requests refused
    /// afterwards say only "generation thread died". Only a line that *is*
    /// such a record matches: with verbose logging, request and response
    /// bodies are logged too (pretty-printed, one field per line), and a
    /// chat quoting this very error must not restart anything. A JSON
    /// string can't hold a raw newline, so no body line starts a record.
    static let record = try! NSRegularExpression(
        pattern: #"^(?:\d{4}-\d\d-\d\d \d\d:\d\d:\d\d,\d+ - ERROR - |ERROR:root:)mlx_lm\.server generation thread died"#
    )

    /// Output arrives in arbitrary chunks; an unfinished line waits here.
    private var partial = ""

    public init() {}

    public mutating func feed(_ chunk: String) -> [Event] {
        var lines = (partial + chunk).split(separator: "\n", omittingEmptySubsequences: false)
        partial = String(lines.removeLast())
        // Bounded, keeping the line's start -- that's where a record's
        // marker is; a long exception text after it can go.
        if partial.count > 4096 { partial = String(partial.prefix(1024)) }
        return lines.compactMap { line in
            let line = String(line)
            let ns = line as NSString
            guard let match = Self.record.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let rest = ns.substring(from: match.range.location + match.range.length)
            var reason = rest.trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespaces))
            // Metal reports it as a failed command buffer ("Insufficient
            // Memory") or as an allocation over its limit (metal::malloc).
            let oom = reason.contains("Insufficient Memory") || reason.localizedCaseInsensitiveContains("out of memory")
                || reason.contains("metal::malloc")
            if reason.count > 200 { reason = String(reason.prefix(200)) + "…" }
            return .generationThreadDied(reason: reason, outOfMemory: oom)
        }
    }
}

/// At most `limit` automatic restarts within `window` seconds: a model that
/// dies again right after each restart must end up failed, not restart
/// forever.
public struct RestartBudget {
    public let limit: Int
    public let window: TimeInterval
    private var restarts: [Date] = []

    public init(limit: Int = 3, window: TimeInterval = 600) {
        self.limit = limit
        self.window = window
    }

    /// Records a restart if one is allowed at `now`.
    public mutating func take(now: Date = Date()) -> Bool {
        restarts.removeAll { now.timeIntervalSince($0) >= window }
        guard restarts.count < limit else { return false }
        restarts.append(now)
        return true
    }
}

/// Decodes a byte stream read in arbitrary chunks: a chunk may end in the
/// middle of a multi-byte character, whose first bytes wait for the next
/// one instead of the whole chunk failing to decode. Used from one reading
/// thread at a time.
public final class UTF8StreamDecoder {
    private var pending: [UInt8] = []

    public init() {}

    public func decode(_ data: Data) -> String {
        var bytes = pending + data
        pending = []
        // An incomplete sequence can only be the last 1-3 bytes: find the
        // last lead byte and whether its sequence is complete.
        var i = bytes.count - 1
        while i >= 0, i >= bytes.count - 3, bytes[i] & 0xC0 == 0x80 { i -= 1 }
        if i >= 0, i < bytes.count {
            let lead = bytes[i]
            let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            if bytes.count - i < length {
                pending = Array(bytes[i...])
                bytes.removeSubrange(i...)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
