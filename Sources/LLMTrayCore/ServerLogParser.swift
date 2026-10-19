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
                } else if indented {
                    line = line.with(kind: .error)
                } else {
                    // The exception ends it; other text after a cut-off
                    // traceback is just text.
                    inTraceback = false
                    if ServerLogGrouping.isException(text) { line = line.with(kind: .error) }
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

/// What the log window shows: lines grouped into what happened. A request
/// with the cache, progress and stats lines that followed it; a warning or
/// an error with its source lines or traceback; an LLMTray event; any
/// other line on its own.
public struct ServerLogEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case request, warning, error, event, line }

    /// The first line's id: stable while lines are added after it.
    public var id: Int { head.id }
    public var kind: Kind
    public var head: ServerLogLine
    /// The lines after the head that belong to it (shown when expanded).
    public var children: [ServerLogLine] = []
    /// A request's stats line, parsed.
    public var stats: RequestStats?
    /// A request's latest prefill progress, while its prompt is read.
    public var progress: (done: Int, total: Int)?
    /// The same warning again right after: shown once, "×N".
    public var repeats = 1
    /// For an error: what failed ("Generation failed…") when the exception
    /// line is the summary.
    public var context: String?

    public static func == (a: Self, b: Self) -> Bool {
        a.kind == b.kind && a.head == b.head && a.children == b.children && a.stats == b.stats
            && a.progress?.done == b.progress?.done && a.progress?.total == b.progress?.total
            && a.repeats == b.repeats && a.context == b.context
    }

    /// The summary line: an error's exception ("RuntimeError: boom") when
    /// it has a traceback, else the head's message.
    public var summary: String {
        if kind == .error, let exception = children.last(where: { !$0.text.hasPrefix(" ") && !$0.text.hasPrefix("\t")
            && !$0.text.hasPrefix("Traceback") && !ServerLogGrouping.chainLines.contains(where: $0.text.hasPrefix) }) {
            return exception.text
        }
        // "/path/server.py:3156: UserWarning: …": the warning first; where
        // it came from is in the head line, shown when expanded.
        if kind == .warning, let range = head.message.range(of: #"^\S+:\d+: (?=\w*Warning: )"#, options: .regularExpression) {
            return String(head.message[range.upperBound...])
        }
        return head.message
    }

    public var isError: Bool { kind == .error || (head.status ?? 0) >= 500 }
    public var isProblem: Bool { isError || kind == .warning || (head.status ?? 0) >= 400 }
    public var lines: [ServerLogLine] { [head] + children }
    /// Every line's text, for copying and searching (a folded repeat says
    /// how many).
    public var text: String {
        lines.map(\.text).joined(separator: "\n") + (repeats > 1 ? "\n(×\(repeats))" : "")
    }

    /// The time of its last line that has one: when it ended.
    public var lastTime: String? { lines.last(where: { $0.time != nil })?.time }
}

extension ServerLogEntry.Kind {
    init(_ line: ServerLogLine) {
        switch line.kind {
        case .request: self = .request
        case .warning: self = .warning
        case .error: self = .error
        case .event: self = .event
        default: self = .line
        }
    }
}

public enum ServerLogGrouping {
    /// The routes whose requests generate: their cache, progress and stats
    /// lines follow them.
    static let generating = ["/v1/chat/completions", "/chat/completions", "/v1/completions", "/completions",
                             "/v1/messages", "/v1/responses"]

    static let progressPattern = try! NSRegularExpression(pattern: #"(\d+)\s*/\s*(\d+)"#)
    /// The line ending a traceback: an exception's name ("RuntimeError: boom",
    /// "KeyboardInterrupt"), not any text.
    static let exceptionPattern = try! NSRegularExpression(pattern: #"^[A-Za-z_][\w.]*(?::.*)?$"#)
    /// Python's lines between chained tracebacks.
    static let chainLines = ["During handling of the above exception", "The above exception was the direct cause"]

    static func isException(_ text: String) -> Bool {
        exceptionPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// LLMTray events after which nothing open goes on: the server started,
    /// stopped or failed.
    static func endsRequests(_ line: ServerLogLine) -> Bool {
        guard line.text.hasPrefix("--- ") else { return false }
        if line.kind == .warning { return true }
        let lower = line.message.lowercased()
        return ["start", "stop", "ready", "restart", "loading", "exited", "unload"].contains { lower.contains($0) }
    }

    public static func entries(_ lines: [ServerLogLine]) -> [ServerLogEntry] {
        var out: [ServerLogEntry] = []
        /// Generating requests not yet ended by their stats line (indices).
        var open: [Int] = []
        /// The problem entry lines may still join (index).
        var problem: Int?
        var inTraceback = false
        /// After a traceback's exception: Python may chain another.
        var afterException = false
        /// A repeat of a warning was folded in: its own source lines (already
        /// there) aren't added again.
        var repeating = false

        for line in lines {
            let indented = line.text.hasPrefix(" ") || line.text.hasPrefix("\t")
            // A warning's or error's own lines: indented source lines, a
            // traceback and the exception that ends it, chained ones.
            if let p = problem, line.time == nil, line.status == nil, !line.text.hasPrefix("--- ") {
                if line.text.hasPrefix("Traceback") {
                    inTraceback = true
                    afterException = false
                    out[p].children.append(line)
                    if out[p].kind == .warning { out[p].kind = .error }
                    continue
                }
                if afterException, chainLines.contains(where: line.text.hasPrefix) {
                    out[p].children.append(line)
                    continue
                }
                if indented {
                    if !(repeating && out[p].children.contains { $0.text == line.text }) { out[p].children.append(line) }
                    continue
                }
                if inTraceback, isException(line.text) {
                    out[p].children.append(line)
                    inTraceback = false
                    afterException = true
                    continue
                }
            }
            problem = nil
            inTraceback = false
            afterException = false
            repeating = false

            // A traceback with no record before it.
            if line.text.hasPrefix("Traceback") {
                out.append(ServerLogEntry(kind: .error, head: line))
                problem = out.count - 1
                inTraceback = true
                continue
            }
            // A frame or source line whose start was cut off: as it is.
            if indented, line.time == nil, line.kind == .error || line.kind == .warning {
                out.append(ServerLogEntry(kind: .line, head: line))
                continue
            }

            switch line.kind {
            case .request:
                out.append(ServerLogEntry(kind: .request, head: line))
                let path = (line.path ?? "").split(separator: "?").first.map(String.init) ?? ""
                if line.method == "POST", generating.contains(path), (line.status ?? 0) < 400 { open.append(out.count - 1) }
            case .cache, .progress, .stats:
                // Joins the request it belongs to: the only one open. With
                // several at once there's no telling which: on its own (and
                // a stats line still ends one of them, the oldest).
                guard open.count == 1, let r = open.first else {
                    out.append(ServerLogEntry(kind: .line, head: line))
                    if line.kind == .stats, !open.isEmpty { open.removeFirst() }
                    continue
                }
                out[r].children.append(line)
                if line.kind == .stats {
                    out[r].stats = RequestStats.parse(line.message)
                    out[r].progress = nil
                    open.removeAll()
                } else if line.kind == .progress {
                    let ns = line.message as NSString
                    if let m = progressPattern.firstMatch(in: line.message, range: NSRange(location: 0, length: ns.length)),
                       let done = Int(ns.substring(with: m.range(at: 1))), let total = Int(ns.substring(with: m.range(at: 2))) {
                        out[r].progress = (done, total)
                    }
                }
            case .warning, .error:
                let kind = ServerLogEntry.Kind(line)
                // The same warning again: counted on the last one, its source
                // lines not added twice.
                if kind == .warning, let last = out.indices.last, out[last].kind == .warning,
                   out[last].head.message == line.message {
                    out[last].repeats += 1
                    problem = last
                    repeating = true
                    continue
                }
                var entry = ServerLogEntry(kind: kind, head: line)
                if kind == .error { entry.context = line.message }
                out.append(entry)
                problem = out.count - 1
            default:
                out.append(ServerLogEntry(kind: ServerLogEntry.Kind(line), head: line))
            }
            if endsRequests(line) { open.removeAll() }
        }
        return out
    }
}
