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

    /// Whether `url` is the Developer ID build's preferences file itself:
    /// the right name, directly in `home`'s Library/Preferences (links
    /// resolved) -- not a stale copy elsewhere. `home`: the user's real one
    /// (SandboxAccess.realHome), not the container's.
    public static func isStandalonePreferencesFile(_ url: URL, home: String) -> Bool {
        let file = url.resolvingSymlinksInPath().standardizedFileURL
        let preferences = URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences")
            .resolvingSymlinksInPath().standardizedFileURL
        return file.lastPathComponent == settingsFileName
            && file.deletingLastPathComponent().standardizedFileURL.path == preferences.path
    }

    /// `settings` (the whole imported set) made this install's: theirs in
    /// place of ours, and each imported key they don't have removed here,
    /// so the result is their settings, defaults included -- what the
    /// same-id move gave (the data import, by contrast, never overwrites).
    /// `domain`: this app's own (persistent) domain in `defaults`, whose
    /// keys are the "ours" to remove. Then the one-time migrations run on
    /// what came in: the app ran them at launch, before these values were
    /// here. Returns how many keys changed.
    @discardableResult
    public static func apply(settings: [String: Any], to defaults: UserDefaults, domain: String) -> Int {
        var changed = 0
        let ours = defaults.persistentDomain(forName: domain) ?? [:]
        for key in ours.keys.sorted() where isImportedSetting(key) && settings[key] == nil {
            defaults.removeObject(forKey: key)
            changed += 1
        }
        for (key, value) in settings.sorted(by: { $0.key < $1.key }) where isImportedSetting(key) {
            if let current = ours[key] as? NSObject, let new = value as? NSObject, current.isEqual(new) { continue }
            defaults.set(value, forKey: key)
            changed += 1
        }
        // Their marker came with their values (or went, if their build
        // predates it): values from before the migration get it now.
        KVSettings.migrateIfNeeded(defaults)
        return changed
    }
}
