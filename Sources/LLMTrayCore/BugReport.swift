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

    /// The home folder as "~": paths say where, not whose.
    public static func redact(_ text: String, home: String = NSHomeDirectory()) -> String {
        guard home.count > 1 else { return text }
        return text.replacingOccurrences(of: home, with: "~")
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
