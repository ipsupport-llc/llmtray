import Foundation

/// The "What's New" window's content and when it opens by itself. Pure:
/// the app's WhatsNewWindow shows `latest` and stores what it returns in
/// Pref.whatsNewLastSeen.
///
/// The text is localized here (keys = English); scripts/l10n.py extracts
/// this file along with the app's sources.
public enum WhatsNew {
    public struct Item: Equatable, Sendable {
        public let title: String
        public let text: String
        /// An SF Symbol shown next to it.
        public let symbol: String

        public init(title: String, text: String, symbol: String) {
            self.title = title
            self.text = text
            self.symbol = symbol
        }
    }

    public struct Release: Equatable, Sendable {
        /// major.minor, e.g. "0.8": the notes cover every 0.8.x.
        public let version: String
        public let items: [Item]

        public init(version: String, items: [Item]) {
            self.version = version
            self.items = items
        }
    }

    /// Newest first.
    public static var releases: [Release] {
        [
            Release(version: "0.8", items: [
                Item(title: NSLocalizedString("Project files", comment: "what's new: title"),
                     text: NSLocalizedString("Add PDFs, Word and text files to a project. Its chats search them and cite the page; pin a file to keep all of it in the conversation.", comment: "what's new: text"),
                     symbol: "doc.text.magnifyingglass"),
                Item(title: NSLocalizedString("Folders", comment: "what's new: title"),
                     text: NSLocalizedString("A chat can look in folders you allow and propose new folders, moves and renames. You approve every change and can undo it.", comment: "what's new: text"),
                     symbol: "folder"),
                Item(title: NSLocalizedString("First-run setup", comment: "what's new: title"),
                     text: NSLocalizedString("Picks a model that fits your Mac and enables only what you choose.", comment: "what's new: text"),
                     symbol: "checklist"),
                Item(title: NSLocalizedString("Answer details", comment: "what's new: title"),
                     text: NSLocalizedString("Hover the info button under an answer to see the model, speed and how much context it used.", comment: "what's new: text"),
                     symbol: "info.circle"),
                Item(title: NSLocalizedString("Faster long chats", comment: "what's new: title"),
                     text: NSLocalizedString("Long conversations and pinned files come from the cache instead of being read again every turn.", comment: "what's new: text"),
                     symbol: "bolt"),
                Item(title: NSLocalizedString("Works offline", comment: "what's new: title"),
                     text: NSLocalizedString("The model server no longer goes online when it starts.", comment: "what's new: text"),
                     symbol: "wifi.slash"),
            ]),
        ]
    }

    /// What the window shows.
    public static var latest: Release { releases[0] }

    /// A version's major and minor: "0.8.0", "0.8.0-beta.3" and "0.8" are
    /// all 0.8; nil for "dev" or anything else that isn't a version.
    public static func minorVersion(_ version: String) -> (major: Int, minor: Int)? {
        let core = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]),
              major >= 0, minor >= 0 else { return nil }
        return (major, minor)
    }

    /// "0.8.0-beta.3" -> "0.8", the form Pref.whatsNewLastSeen stores.
    public static func minorString(_ version: String) -> String? {
        minorVersion(version).map { "\($0.major).\($0.minor)" }
    }

    public enum LaunchAction: Equatable, Sendable {
        /// Show this release (and store its version as seen).
        case show(Release)
        /// Nothing to show; store this version as seen.
        case record(String)
        case nothing
    }

    /// At launch: `appVersion` the running app's (CFBundleShortVersionString),
    /// `lastSeen` the stored major.minor (nil: never stored -- a fresh
    /// install, or one from before this window existed), `freshInstall`
    /// the setup wizard's first-run signal (SetupWizard.opensAutomatically).
    /// Shown once per minor, never on a fresh install (the wizard is
    /// that), and only when there are notes for the running minor.
    public static func launchAction(appVersion: String, lastSeen: String?, freshInstall: Bool,
                                    releases: [Release] = WhatsNew.releases) -> LaunchAction {
        guard let current = minorVersion(appVersion), let currentString = minorString(appVersion) else { return .nothing }
        if let lastSeen, let seen = minorVersion(lastSeen), (seen.major, seen.minor) >= (current.major, current.minor) {
            return .nothing
        }
        if freshInstall { return .record(currentString) }
        if let release = releases.first(where: { minorString($0.version) == currentString }) {
            return .show(release)
        }
        return .record(currentString)
    }
}
