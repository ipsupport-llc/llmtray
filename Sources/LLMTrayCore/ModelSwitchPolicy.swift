import Foundation

/// What the proxy does when an outside client (an editor, an agent, curl)
/// asks for a model other than the one loaded: switching unloads the one
/// in use -- a coding agent's request used to swap the chat's Gemma for
/// Nemotron without a word. The app's own chat always switches: its
/// model is the one the user picked.
public enum ModelSwitchPolicy: String, CaseIterable, Sendable {
    /// Switch at once (the behaviour before this setting).
    case auto
    /// Ask the user; the request waits for the answer.
    case ask
    /// Keep the loaded model; the request is refused.
    case keep

    public enum Decision: Equatable, Sendable { case proceed, ask, refuse }

    /// `loaded`: the model running now (nil: none, or idle-unloaded -- then
    /// loading the requested one replaces nothing in use). `refusedLately`:
    /// the user said "keep" to this target a moment ago, so an agent's
    /// retries aren't asked about again.
    public func decide(fromApp: Bool, loaded: String?, target: String?, refusedLately: Bool) -> Decision {
        guard !fromApp, let loaded, let target, loaded != target else { return .proceed }
        switch self {
        case .auto: return .proceed
        case .keep: return .refuse
        case .ask: return refusedLately ? .refuse : .ask
        }
    }
}
