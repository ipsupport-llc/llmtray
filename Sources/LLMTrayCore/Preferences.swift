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
    public static let verboseServerLogging = PrefKey("llmtray.verboseServerLogging", default: false)
    public static let stallThresholdSeconds = PrefKey("llmtray.stallThresholdSeconds", default: 60)
    public static let autoRestartStallThreshold = PrefKey("llmtray.autoRestartStallThreshold", default: 3)
    /// 0 = never.
    public static let autoStopIdleMinutes = PrefKey("llmtray.autoStopIdleMinutes", default: 0)
    public static let autoStartOnLaunch = PrefKey("llmtray.autoStartOnLaunch", default: true)
    /// The model the popover (and auto-start) uses -- its path.
    public static let selectedModelID = PrefKey<String?>("selectedModelID", default: nil)

    // Chat
    public static let showReasoning = PrefKey("llmtray.showReasoning", default: true)
    public static let compactKeepStart = PrefKey("llmtray.compactKeepStart", default: 4)
    public static let compactKeepEnd = PrefKey("llmtray.compactKeepEnd", default: 6)
    /// 0 = off.
    public static let autoCompactThreshold = PrefKey("llmtray.autoCompactThreshold", default: 0)

    // Updates
    public static let betaUpdates = PrefKey("llmtray.betaUpdates", default: false)
    public static let checkUpdatesAtLaunch = PrefKey("llmtray.checkUpdatesAtLaunch", default: true)
    /// Sparkle's own key.
    public static let automaticUpdateChecks = PrefKey("SUEnableAutomaticChecks", default: true)
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
