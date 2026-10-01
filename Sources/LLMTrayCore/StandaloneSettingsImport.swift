import Foundation

/// The Developer ID build's settings, for the App Store build's import
/// (adr/0018 §3). With its own bundle id the App Store build doesn't get
/// them from macOS (which moves a same-id app's preferences into the
/// container on the first sandboxed launch), and the sandbox can't read
/// another app's preference domain: `UserDefaults(suiteName:)` looks in the
/// container. What it can read is the domain's plist file, once the user
/// picks it in an open panel (StandaloneImporter) -- that's what comes in
/// here.
extension StandaloneImport {
    /// ~/Library/Preferences/<this>.
    public static let settingsFileName = AppIdentity.standaloneBundleID + ".plist"

    /// Keys of the app's own that aren't LLMTray-prefixed.
    static let otherSettings: Set<String> = ["selectedModelID", "AppleLanguages"]

    /// Never brought over: state of the moment (a relaunch's pane, the
    /// setup wizard mid-way, the download queue with the other build's
    /// destinations, the open tabs -- this app writes its own over them as
    /// it quits), the update channel (no Sparkle here), this install's
    /// telemetry id and last report (the opt-in itself comes), supporter
    /// proofs (the App Store build's are its purchases), and the sandbox's
    /// bookmarks.
    static let leftOutSettings: Set<String> = [
        "llmtray.settingsPaneAfterRelaunch",
        "llmtray.onboarding.progress", "llmtray.onboarding.startServerFor",
        "llmtray.downloadQueue", "llmtray.openChatTabs",
        "llmtray.betaUpdates", "llmtray.checkUpdatesAtLaunch",
        "llmtray.telemetry.installID", "llmtray.telemetry.lastSentJSON", "llmtray.telemetry.lastSentDay",
        "llmtray.sandbox.bookmarks",
    ]

    /// Whether the Developer ID build's `key` comes over: LLMTray's own
    /// settings, less `leftOutSettings`; nothing of AppKit's, Sparkle's or
    /// the system's (window frames, open-panel state, SU*).
    public static func isImportedSetting(_ key: String) -> Bool {
        guard key.hasPrefix("llmtray.") || otherSettings.contains(key) else { return false }
        return !leftOutSettings.contains(key) && !key.hasPrefix("llmtray.supporters.")
    }

    /// The settings to import from the preferences plist's `data` (binary
    /// or XML); nil when it isn't a preferences file.
    public static func settings(fromPlist data: Data) -> [String: Any]? {
        guard let all = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return all.filter { isImportedSetting($0.key) }
    }

    /// `settings` written into `defaults`, theirs in place of ours: the user
    /// asked for their settings, and it's what the same-id move gave (the
    /// data import, by contrast, never overwrites). Returns how many keys
    /// changed.
    @discardableResult
    public static func apply(settings: [String: Any], to defaults: UserDefaults) -> Int {
        var changed = 0
        for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
            if let current = defaults.object(forKey: key) as? NSObject, let new = value as? NSObject, current.isEqual(new) {
                continue
            }
            defaults.set(value, forKey: key)
            changed += 1
        }
        return changed
    }
}
