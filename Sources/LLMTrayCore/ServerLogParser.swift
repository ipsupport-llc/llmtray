import Foundation

/// One line of the server log, sorted by what it is: the model server's own
/// log records, its HTTP access lines, LLMTray's "--- … ---" events and
/// Python warnings and tracebacks.
public struct ServerLogLine: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case error, warning, request, stats, cache, progress, event, debug, info
    }

    /// The line's number since the log started: it stays the same when
    /// older lines are dropped from the front.
    public let id: Int
    public let text: String
    public let kind: Kind
    /// The record's time as written ("06:22:11"), when it has one.
    public let time: String?
    /// The line without its time and level prefix.
    public let message: String
    /// For an HTTP access line: its method, path and status.
    public let method: String?
    public let path: String?
    public let status: Int?

    /// An error, or a request the server failed (5xx).
    public var isError: Bool { kind == .error || (status ?? 0) >= 500 }
    /// An error or a warning, or a request refused (4xx).
    public var isProblem: Bool { isError || kind == .warning || (status ?? 0) >= 400 }
}

public enum ServerLogParser {
    // 2026-10-17 06:22:11,984 - INFO - message
    private static let record = try! NSRegularExpression(
        pattern: #"^\d{4}-\d\d-\d\d (\d\d:\d\d:\d\d)(?:,\d+)? - (DEBUG|INFO|WARNING|ERROR|CRITICAL) - (.*)$"#)
    // WARNING:root:message (Python logging's default format)
    private static let plainRecord = try! NSRegularExpression(
        pattern: #"^(DEBUG|INFO|WARNING|ERROR|CRITICAL):[\w.]+:(.*)$"#)
    // 127.0.0.1 - - [17/Oct/2026 06:22:11] "POST /v1/chat/completions HTTP/1.1" 200 -
    private static let access = try! NSRegularExpression(
        pattern: #"^\S+ - - \[[^\]]*? (\d\d:\d\d:\d\d)\] "(\w+) (\S+)[^"]*" (\d{3})"#)
    // --- runtime ready ---
    private static let event = try! NSRegularExpression(pattern: #"^--- (.*?) ---\s*$"#)
    // /path/x.py:3156: UserWarning: …, or "DeprecationWarning: …"
    private static let pyWarning = try! NSRegularExpression(pattern: #"^(?:\S+:\d+: )?\w*Warning: "#)
    // RuntimeError: boom
    private static let pyError = try! NSRegularExpression(pattern: #"^[\w.]*(?:Error|Exception)(?::|$)"#)

    /// LLMTray events that report something gone wrong.
    private static let badEvent = ["couldn't", "can't", "failed", "stalled", "error", "didn't", "given up",
                                   "not installed", "exited", "unexpected", "killed", "crash", "refused", "timed out"]

    /// The lines of `log`. `firstID`: the number of the log's first line
    /// (lines dropped from the front before it).
    public static func parse(_ log: String, firstID: Int = 0) -> [ServerLogLine] {
        var out: [ServerLogLine] = []
        var inTraceback = false
        var previous: ServerLogLine.Kind?
        for (index, raw) in log.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let id = firstID + index
            var line = parseLine(text, id: id)
            let indented = text.hasPrefix(" ") || text.hasPrefix("\t")
            if text.hasPrefix("Traceback (most recent call last)") {
                inTraceback = true
            } else if inTraceback {
                // Frames are indented; the exception line ends it (a record
                // or an access line ends a cut-off one).
                if line.time != nil || line.status != nil || line.kind == .event {
                    inTraceback = false
                } else {
                    if !indented { inTraceback = false }
                    line = line.with(kind: .error)
                }
            } else if indented, line.time == nil, let previous, previous == .warning || previous == .error {
                // A warning's source line ("  warnings.warn(") goes with it.
                line = line.with(kind: previous)
            }
            out.append(line)
            previous = line.kind
        }
        return out
    }

    static func parseLine(_ text: String, id: Int) -> ServerLogLine {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = record.firstMatch(in: text, range: range) {
            return logRecord(text, id: id, time: ns.substring(with: m.range(at: 1)),
                             level: ns.substring(with: m.range(at: 2)), message: ns.substring(with: m.range(at: 3)))
        }
        if let m = plainRecord.firstMatch(in: text, range: range) {
            return logRecord(text, id: id, time: nil,
                             level: ns.substring(with: m.range(at: 1)), message: ns.substring(with: m.range(at: 2)))
        }
        if let m = access.firstMatch(in: text, range: range) {
            return ServerLogLine(id: id, text: text, kind: .request, time: ns.substring(with: m.range(at: 1)),
                                 message: text, method: ns.substring(with: m.range(at: 2)),
                                 path: ns.substring(with: m.range(at: 3)), status: Int(ns.substring(with: m.range(at: 4))))
        }
        if let m = event.firstMatch(in: text, range: range) {
            let message = ns.substring(with: m.range(at: 1))
            let lower = message.lowercased()
            return ServerLogLine(id: id, text: text, kind: badEvent.contains(where: lower.contains) ? .warning : .event,
                                 time: nil, message: message, method: nil, path: nil, status: nil)
        }
        let kind: ServerLogLine.Kind
        if text.hasPrefix("Traceback") || pyError.firstMatch(in: text, range: range) != nil { kind = .error }
        else if pyWarning.firstMatch(in: text, range: range) != nil { kind = .warning }
        else { kind = .info }
        return ServerLogLine(id: id, text: text, kind: kind, time: nil, message: text, method: nil, path: nil, status: nil)
    }

    private static func logRecord(_ text: String, id: Int, time: String?, level: String, message: String) -> ServerLogLine {
        let kind: ServerLogLine.Kind
        switch level {
        case "ERROR", "CRITICAL": kind = .error
        case "WARNING": kind = .warning
        case "DEBUG": kind = .debug
        default:
            if message.hasPrefix("Request stats:") { kind = .stats }
            else if message.hasPrefix("Prompt processing progress") || message.hasPrefix("Prefill step") { kind = .progress }
            else if message.hasPrefix("Prompt Cache:") || message.hasPrefix("Prompt cache:")
                        || message.hasPrefix("- assistant:") || message.hasPrefix("- user:")
                        || message.hasPrefix("- system:") { kind = .cache }
            else { kind = .info }
        }
        return ServerLogLine(id: id, text: text, kind: kind, time: time, message: message, method: nil, path: nil, status: nil)
    }

    /// Whether `text` holds `query`, ignoring case and diacritics (as the
    /// search highlight matches).
    public static func matches(_ text: String, _ query: String) -> Bool {
        query.isEmpty || text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

extension ServerLogLine {
    func with(kind: Kind) -> ServerLogLine {
        ServerLogLine(id: id, text: text, kind: kind, time: time, message: message, method: method, path: path, status: status)
    }
}
