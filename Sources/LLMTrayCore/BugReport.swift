import Foundation

/// The text of a bug report: what the app knows about itself, the Mac, the
/// runtime and the model, in sections, with the user's home folder
/// replaced by "~" everywhere (no user name in the report). Chats are never
/// part of it.
public struct BugReport {
    public struct Section {
        public var title: String
        public var lines: [(String, String)]

        public init(_ title: String, _ lines: [(String, String)]) {
            self.title = title
            self.lines = lines
        }
    }

    public var product: String
    public var version: String
    public var description: String
    public var sections: [Section]
    public var createdAt: Date

    public init(product: String, version: String, description: String, sections: [Section], createdAt: Date = Date()) {
        self.product = product
        self.version = version
        self.description = description
        self.sections = sections
        self.createdAt = createdAt
    }

    /// "LLMTray 0.7.1-beta.12 -- bug report"
    public var subject: String { "\(product) \(version) — bug report" }

    public func text(home: String = NSHomeDirectory()) -> String {
        let stamp = ISO8601DateFormatter().string(from: createdAt)
        var out = "\(subject)\n\(stamp)\n\n"
        let what = description.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "What happened\n-------------\n\(what.isEmpty ? "(not described)" : what)\n"
        for section in sections {
            out += "\n\(section.title)\n\(String(repeating: "-", count: section.title.count))\n"
            let width = section.lines.map(\.0.count).max() ?? 0
            for (key, value) in section.lines {
                out += key.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + value + "\n"
            }
        }
        return Self.redact(out, home: home)
    }

    /// The home folder as "~", and the user name as "USER" where it's a
    /// folder anywhere else (/Volumes/Models/alice/...): paths say where,
    /// not whose.
    public static func redact(_ text: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> String {
        var text = text
        if home.count > 1 {
            // On a path boundary: "/Users/alice2" isn't "~2".
            let pattern = NSRegularExpression.escapedPattern(for: home) + #"(?=[/\\"'\s:,)\]]|$)"#
            text = text.replacingOccurrences(of: pattern, with: "~", options: .regularExpression)
        }
        if !user.isEmpty {
            let name = NSRegularExpression.escapedPattern(for: user)
            // A whole path component: anything but a name character after it.
            text = text.replacingOccurrences(of: #"(?<=/)"# + name + #"(?![A-Za-z0-9._-])"#, with: "USER", options: .regularExpression)
        }
        return text
    }

    /// The server log without what a chat put in it. With verbose logging
    /// mlx_lm.server logs each request body, the generated text and the
    /// response as DEBUG records, over several lines. Kept, as an allow
    /// list: records that start as a record surely does (a full timestamp
    /// with milliseconds and a level, an access line, LLMTray's own
    /// "--- ... ---"), and the lines continuing a kept non-DEBUG record (a
    /// traceback). A DEBUG record and whatever follows it up to the next
    /// record go, and so does everything before the first record (a log
    /// cut mid-record). Lines carrying a chat's JSON fields go too.
    public static func withoutChatContent(_ log: String) -> String {
        enum State { case beforeFirstRecord, kept, dropped }
        var state = State.beforeFirstRecord
        var out: [String] = []
        for line in log.components(separatedBy: "\n") {
            if let level = recordLevel(line) {
                if level == "DEBUG" {
                    if state != .dropped { out.append("[verbose log record removed]") }
                    state = .dropped
                    continue
                }
                state = .kept
            } else if state != .kept {
                continue
            }
            if ["\"messages\"", "\"content\"", "\"prompt\"", "Request Body:"].contains(where: line.contains) {
                out.append("[request data removed]")
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Verbose logging was on at some point: the log holds DEBUG records,
    /// and with them the chats (a model's answer can even look like a log
    /// line). Such a log isn't attached at all.
    public static func hasVerboseRecords(_ log: String) -> Bool {
        log.range(of: #"(?m)^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3} - DEBUG - "#, options: .regularExpression) != nil
    }

    /// A line that starts a log record, and its level ("" for one without:
    /// an access line, LLMTray's markers). nil for a continuation line.
    /// Strict on purpose: a model's text (a markdown "---", a date, a line
    /// saying "Error") mustn't pass for a record and end a DEBUG one.
    static func recordLevel(_ line: String) -> String? {
        let logged = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3} - (DEBUG|INFO|WARNING|ERROR|CRITICAL) - "#
        if line.range(of: logged, options: .regularExpression) != nil {
            // "<date> - LEVEL - message": the second field.
            return line.components(separatedBy: " - ").dropFirst().first ?? ""
        }
        let other = #"^(\d{1,3}(\.\d{1,3}){3} - - \[|--- .+ ---$)"#
        return line.range(of: other, options: .regularExpression) != nil ? "" : nil
    }

    /// A macOS crash report (.ips) as attached: the home folder as "~" in
    /// its JSON-escaped paths too, and the IDs that identify this Mac
    /// across reports (crashReporterKey, sleepWakeUUID...) removed.
    public static func redactCrashReport(_ text: String, home: String = NSHomeDirectory()) -> String {
        var out = redact(text, home: home)
        out = redact(out, home: home.replacingOccurrences(of: "/", with: "\\/"))
        for key in ["crashReporterKey", "sleepWakeUUID", "deviceIdentifierForVendor", "incident_id", "incident"] {
            out = out.replacingOccurrences(of: #""\#(key)"\s*:\s*"[^"]*""#, with: "\"\(key)\":\"removed\"", options: .regularExpression)
        }
        return out
    }

    /// The last `maxBytes` of a log, from a line start.
    public static func tail(_ log: String, maxBytes: Int) -> String {
        let data = Data(log.utf8)
        guard data.count > maxBytes else { return log }
        var cut = String(decoding: data.suffix(maxBytes), as: UTF8.self)
        if let newline = cut.firstIndex(of: "\n") { cut = String(cut[cut.index(after: newline)...]) }
        return "[… earlier output cut …]\n" + cut
    }
}
