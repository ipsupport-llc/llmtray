import Foundation

/// A window, the screen or a browser tab the user showed the model with a
/// message (adr/0030): what it was, and its text when the model gets text.
public struct SharedContext: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A window, picked in the system's content-sharing picker.
        case window
        /// A whole display.
        case screen
        /// The front tab of a browser.
        case browserTab
    }

    public var id = UUID()
    public var kind: Kind
    /// The window's title or the page's ("Account settings").
    public var title: String
    /// The app ("Safari") for a window; the address for a tab.
    public var source: String
    /// The text the model gets: the page's readable text, or the text
    /// recognized in a capture for a model that doesn't see. nil: none (a
    /// capture going as an image).
    public var text: String?
    /// The text was cut at maxText.
    public var truncated = false
    /// For a tab: the browser ran no script, so only its title and address
    /// came (Chromium's "Allow JavaScript from Apple Events" is off).
    public var titleOnly = false
    /// A capture whose picture goes with the message: its recognized text
    /// is for a model that doesn't see (noteForModel).
    public var hasPicture = false

    /// The most text one shared item adds to a message, in characters.
    public static let maxText = 6000

    public init(kind: Kind, title: String, source: String, text: String? = nil, titleOnly: Bool = false, hasPicture: Bool = false) {
        self.hasPicture = hasPicture
        self.kind = kind
        self.title = title
        self.source = source
        self.titleOnly = titleOnly
        if let text {
            let clean = Self.clean(text)
            if clean.count > Self.maxText {
                self.text = String(clean.prefix(Self.maxText))
                truncated = true
            } else {
                self.text = clean.isEmpty ? nil : clean
            }
        }
    }

    /// Runs of spaces and of blank lines collapsed, lines trimmed: page text
    /// is mostly layout whitespace.
    static func clean(_ text: String) -> String {
        var lines: [String] = []
        var blank = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }).joined(separator: " ")
            if line.isEmpty {
                blank = !lines.isEmpty
                continue
            }
            if blank { lines.append("") }
            blank = false
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// The line naming it, for the model and the chip.
    public var heading: String {
        switch kind {
        case .window:
            let name = [source, title].filter { !$0.isEmpty }.joined(separator: " — ")
            return name.isEmpty ? "A window on the user's screen" : "Window: \(name)"
        case .screen:
            return "The user's screen"
        case .browserTab:
            let name = title.isEmpty ? source : "\(title) (\(source))"
            return "Browser tab: \(name)"
        }
    }

    /// The block the model gets before the message's text: marked as what
    /// the user showed, so a page's words don't read as the user's own. A
    /// capture's text goes only to a model that doesn't see its picture
    /// (`seesPicture` false).
    public func noteForModel(seesPicture: Bool) -> String {
        var lines = ["[The user is showing you this. \(heading)]"]
        if let text, !(hasPicture && seesPicture) {
            switch kind {
            case .window, .screen:
                lines.append("Text recognized in it (icons, colors and states of controls aren't in it):")
            case .browserTab:
                lines.append("The page's text:")
            }
            lines.append(text)
            if truncated { lines.append("(cut here: the rest isn't shown)") }
        } else if kind == .browserTab {
            lines.append("(Only the title and address: the page's text couldn't be read.)")
        }
        lines.append("[End of what the user is showing]")
        return lines.joined(separator: "\n")
    }
}

/// Text recognized in a capture, in reading order: observations (one per
/// line of text, with their boxes in the image's normalized coordinates,
/// origin at the bottom left as Vision gives them) grouped into rows top to
/// bottom, left to right within a row.
public enum ReadingOrder {
    public struct Piece: Equatable, Sendable {
        public let text: String
        /// Normalized box: x, y from the bottom left, width, height.
        public let x: Double, y: Double, width: Double, height: Double
        public init(text: String, x: Double, y: Double, width: Double, height: Double) {
            self.text = text
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
        var midY: Double { y + height / 2 }
    }

    /// One row per visual line: pieces whose vertical middles are within
    /// half a line height of the row's first piece are on it, joined with
    /// a gap.
    public static func lines(_ pieces: [Piece]) -> String {
        let sorted = pieces.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.midY != $1.midY ? $0.midY > $1.midY : $0.x < $1.x }
        var rows: [[Piece]] = []
        for piece in sorted {
            if let first = rows.last?.first, abs(first.midY - piece.midY) < max(first.height, piece.height) / 2 {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows.map { row in row.sorted { $0.x < $1.x }.map(\.text).joined(separator: "   ") }
            .joined(separator: "\n")
    }
}

/// The front tab of a browser through Apple Events (adr/0030; not in the
/// App Store build): which browsers, and the scripts asked of them.
public enum BrowserTab {
    public enum Family: Sendable { case safari, chromium }

    public struct Browser: Equatable, Sendable {
        public let bundleID: String
        public let name: String
        public let family: Family
    }

    public static let browsers: [Browser] = [
        Browser(bundleID: "com.apple.Safari", name: "Safari", family: .safari),
        Browser(bundleID: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview", family: .safari),
        Browser(bundleID: "com.google.Chrome", name: "Google Chrome", family: .chromium),
        Browser(bundleID: "com.google.Chrome.beta", name: "Google Chrome Beta", family: .chromium),
        Browser(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", family: .chromium),
        Browser(bundleID: "com.brave.Browser", name: "Brave Browser", family: .chromium),
        Browser(bundleID: "company.thebrowser.Browser", name: "Arc", family: .chromium),
        Browser(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", family: .chromium),
    ]

    public static func browser(bundleID: String?) -> Browser? {
        browsers.first { $0.bundleID == bundleID }
    }

    /// The readable text of the page, run in it by a Chromium browser:
    /// the main or article element's visible text, else the body's. Fixed
    /// here -- never anything a model wrote.
    static let pageTextJS = "(function(){var m=document.querySelector('main,article,[role=main]');"
        + "var t=(m&&m.innerText&&m.innerText.trim().length>200?m:document.body).innerText;return t||'';})()"

    /// The AppleScript asking `browser` for its front tab: title, address
    /// and (unless `titleOnly`) text, separated by `separator` lines. A
    /// Chromium browser runs the script only with "Allow JavaScript from
    /// Apple Events" on; `titleOnly` is the fallback without it.
    public static func script(for browser: Browser, titleOnly: Bool = false) -> String {
        let app = "application id \"\(browser.bundleID)\""
        let sep = "(ASCII character 30)"
        // Long enough for macOS's Automation prompt to be answered.
        let timeout = 120
        switch browser.family {
        case .safari:
            let text = titleOnly ? "\"\"" : "(text of t)"
            return """
            with timeout of \(timeout) seconds
                tell \(app)
                    set t to current tab of front window
                    return (name of t) & \(sep) & (URL of t) & \(sep) & \(text)
                end tell
            end timeout
            """
        case .chromium:
            let js = pageTextJS.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let text = titleOnly ? "\"\"" : "(execute t javascript \"\(js)\")"
            return """
            with timeout of \(timeout) seconds
                tell \(app)
                    set t to active tab of front window
                    return (title of t) & \(sep) & (URL of t) & \(sep) & \(text)
                end tell
            end timeout
            """
        }
    }

    /// The error number osascript ends its message with ("… (-1743)").
    public static func errorNumber(_ message: String) -> Int? {
        guard let open = message.lastIndex(of: "("), let close = message.lastIndex(of: ")"), open < close else { return nil }
        return Int(message[message.index(after: open)..<close])
    }

    /// A script's answer as a shared tab: nil when it isn't one.
    public static func parse(_ answer: String, titleOnly: Bool) -> SharedContext? {
        let parts = answer.components(separatedBy: "\u{1E}")
        guard parts.count >= 3 else { return nil }
        let url = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        let text = parts[2...].joined(separator: "\u{1E}")
        return SharedContext(kind: .browserTab, title: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                             source: url, text: titleOnly ? nil : text, titleOnly: titleOnly)
    }
}
