import Foundation

/// One line of the server log, sorted by what it is: the model server's own
/// log records, its HTTP access lines, LLMTray's "--- … ---" events and
/// Python tracebacks.
public struct ServerLogLine: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case error, warning, request, stats, cache, progress, event, debug, info
    }

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

    public var isProblem: Bool { kind == .error || kind == .warning }
}

public enum ServerLogParser {
    // 2026-10-17 06:22:11,984 - INFO - message
    private static let record = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d)(?:,\d+)? - (DEBUG|INFO|WARNING|ERROR|CRITICAL) - (.*)$"#)
    // 127.0.0.1 - - [17/Oct/2026 06:22:11] "POST /v1/chat/completions HTTP/1.1" 200 -
    private static let access = try! NSRegularExpression(
        pattern: #"^\S+ - - \[[^\]]*? (\d\d:\d\d:\d\d)\] "(\w+) (\S+)[^"]*" (\d{3})"#)

    /// The lines of `log`, in order. A traceback's lines are errors up to
    /// its exception line.
    public static func parse(_ log: String) -> [ServerLogLine] {
        var out: [ServerLogLine] = []
        var inTraceback = false
        var id = 0
        for raw in log.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if text.isEmpty { continue }
            var line = parseLine(text, id: id)
            if text.hasPrefix("Traceback (most recent call last)") {
                inTraceback = true
            } else if inTraceback {
                // Indented frames and code, then the exception line ends it.
                if !(text.hasPrefix(" ") || text.hasPrefix("\t")) { inTraceback = false }
                line = ServerLogLine(id: id, text: text, kind: .error, time: nil, message: text,
                                     method: nil, path: nil, status: nil)
            }
            out.append(line)
            id += 1
        }
        return out
    }

    static func parseLine(_ text: String, id: Int) -> ServerLogLine {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = record.firstMatch(in: text, range: range) {
            let time = ns.substring(with: m.range(at: 2))
            let level = ns.substring(with: m.range(at: 3))
            let message = ns.substring(with: m.range(at: 4))
            let kind: ServerLogLine.Kind
            switch level {
            case "ERROR", "CRITICAL": kind = .error
            case "WARNING": kind = .warning
            case "DEBUG": kind = .debug
            default:
                if message.hasPrefix("Request stats:") { kind = .stats }
                else if message.hasPrefix("Prompt processing progress") { kind = .progress }
                else if message.hasPrefix("Prompt Cache:") || message.hasPrefix("Prompt cache:")
                            || message.hasPrefix("- assistant:") || message.hasPrefix("- user:")
                            || message.hasPrefix("- system:") { kind = .cache }
                else { kind = .info }
            }
            return ServerLogLine(id: id, text: text, kind: kind, time: time, message: message,
                                 method: nil, path: nil, status: nil)
        }
        if let m = access.firstMatch(in: text, range: range) {
            let status = Int(ns.substring(with: m.range(at: 4)))
            return ServerLogLine(id: id, text: text, kind: .request, time: ns.substring(with: m.range(at: 1)),
                                 message: text, method: ns.substring(with: m.range(at: 2)),
                                 path: ns.substring(with: m.range(at: 3)), status: status)
        }
        if text.hasPrefix("---") {
            // LLMTray's own events: one that reports a failure is a warning.
            let message = text.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
            let lower = message.lowercased()
            let bad = ["couldn't", "can't", "failed", "stalled", "error", "didn't", "given up", "not installed"]
            return ServerLogLine(id: id, text: text, kind: bad.contains(where: lower.contains) ? .warning : .event,
                                 time: nil, message: message, method: nil, path: nil, status: nil)
        }
        let lower = text.lowercased()
        let kind: ServerLogLine.Kind
        if text.hasPrefix("Traceback") || lower.contains("error:") || text.hasPrefix("Exception") { kind = .error }
        else if lower.contains("warning") || text.contains("warnings.warn(") { kind = .warning }
        else { kind = .info }
        return ServerLogLine(id: id, text: text, kind: kind, time: nil, message: text,
                             method: nil, path: nil, status: nil)
    }
}
