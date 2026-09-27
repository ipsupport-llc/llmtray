import Foundation

/// A UserDefaults key with its type and default, declared once (see `Pref`)
/// instead of a string literal and a default repeated at every use.
public struct PrefKey<Value> {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// Every app-level (not per-profile) setting. Per-model settings live in
/// profiles (ProfileManager), aliases in ModelAliasStore.
public enum Pref {
    // Server
    public static let port = PrefKey("llmtray.port", default: 8765)
    public static let allowLAN = PrefKey("llmtray.allowLAN", default: false)
    /// `ModelSwitchPolicy` raw value: an outside client asking for another model.
    public static let modelSwitchPolicy = PrefKey("llmtray.modelSwitchPolicy", default: ModelSwitchPolicy.auto.rawValue)
    public static let verboseServerLogging = PrefKey("llmtray.verboseServerLogging", default: false)
    public static let stallThresholdSeconds = PrefKey("llmtray.stallThresholdSeconds", default: 60)
    public static let autoRestartStallThreshold = PrefKey("llmtray.autoRestartStallThreshold", default: 3)
    /// 0 = never.
    public static let autoStopIdleMinutes = PrefKey("llmtray.autoStopIdleMinutes", default: 0)
    public static let autoStartOnLaunch = PrefKey("llmtray.autoStartOnLaunch", default: true)
    /// The model the popover (and auto-start) uses -- its path.
    public static let selectedModelID = PrefKey<String?>("selectedModelID", default: nil)
    /// A settings pane to open on the next launch (a relaunch to change the
    /// language, from that pane): read once, then removed.
    public static let settingsPaneAfterRelaunch = PrefKey<String?>("llmtray.settingsPaneAfterRelaunch", default: nil)

    // Chat
    public static let showReasoning = PrefKey("llmtray.showReasoning", default: true)
    /// Debug: show each tool call (name, arguments) under the answer, with
    /// its result when expanded.
    public static let showToolCalls = PrefKey("llmtray.showToolCalls", default: false)
    public static let compactKeepStart = PrefKey("llmtray.compactKeepStart", default: 4)
    public static let compactKeepEnd = PrefKey("llmtray.compactKeepEnd", default: 6)
    /// 0 = off.
    public static let autoCompactThreshold = PrefKey("llmtray.autoCompactThreshold", default: 0)
    /// The chat window shows the chats sidebar.
    public static let chatWindowSidebar = PrefKey("llmtray.chatWindowSidebar", default: true)
    /// The chat window shows the model, profile, tools and temperature
    /// controls too (they're always in the menu bar's popover).
    public static let chatWindowShowsModelControls = PrefKey("llmtray.chatWindowShowsModelControls", default: false)
    /// The saved chats open in tabs (UUID strings), reopened at launch.
    public static let openChatTabs = PrefKey<[String]>("llmtray.openChatTabs", default: [])
    /// A new chat's first answer gets the model to name the chat.
    public static let autoTitleChats = PrefKey("llmtray.autoTitleChats", default: true)

    /// The download queue (DownloadQueueState as JSON): what the first-run
    /// wizard chose that is still to download or failed, kept across a
    /// relaunch.
    public static let downloadQueue = PrefKey<String?>("llmtray.downloadQueue", default: nil)

    // Updates
    public static let betaUpdates = PrefKey("llmtray.betaUpdates", default: false)
    public static let checkUpdatesAtLaunch = PrefKey("llmtray.checkUpdatesAtLaunch", default: true)
    /// Sparkle's own key.
    public static let automaticUpdateChecks = PrefKey("SUEnableAutomaticChecks", default: true)

    // Reviews (ReviewStore, ReviewPrompter)
    /// The unsent review (a JSON ReviewDraft), kept until the server takes
    /// it: a failed send is retried with the same idempotency key.
    public static let reviewDraft = PrefKey<Data?>("llmtray.review.draft", default: nil)
    /// When a review was last accepted (seconds since 1970); 0 = never.
    public static let reviewSubmittedAt = PrefKey("llmtray.review.submittedAt", default: 0.0)
    /// The first launch with reviews in the app; 0 = not yet recorded.
    public static let reviewFirstLaunch = PrefKey("llmtray.review.firstLaunch", default: 0.0)
    /// Chat answers that completed without an error.
    public static let reviewAnswerCount = PrefKey("llmtray.review.answerCount", default: 0)
    /// "Later": no prompt before this (seconds since 1970); 0 = not snoozed.
    public static let reviewPromptSnoozedUntil = PrefKey("llmtray.review.snoozedUntil", default: 0.0)
    /// "Don't ask again".
    public static let reviewPromptNever = PrefKey("llmtray.review.neverAsk", default: false)

    // Telemetry (adr/0015)
    /// "Share anonymous usage statistics": off until the user turns it on.
    public static let telemetryEnabled = PrefKey("llmtray.telemetry.enabled", default: false)
    /// The random install ID reports go with (a UUID string); made when
    /// telemetry is turned on, removed when it's turned off.
    public static let telemetryInstallID = PrefKey<String?>("llmtray.telemetry.installID", default: nil)
}

extension UserDefaults {
    /// The stored value, or the key's default when nothing (or a value of
    /// another type) is stored.
    public subscript<Value>(key: PrefKey<Value>) -> Value {
        get {
            // bool(forKey:) semantics for Bool, as before: a "YES" / "1"
            // written with `defaults write` (no -bool) still reads as true.
            if Value.self == Bool.self, object(forKey: key.name) != nil {
                return bool(forKey: key.name) as! Value
            }
            return object(forKey: key.name) as? Value ?? key.defaultValue
        }
        set {
            if let optional = newValue as? OptionalProtocol, optional.isNil {
                removeObject(forKey: key.name)
            } else {
                set(newValue, forKey: key.name)
            }
        }
    }
}

private protocol OptionalProtocol {
    var isNil: Bool { get }
}

extension Optional: OptionalProtocol {
    var isNil: Bool { self == nil }
}
