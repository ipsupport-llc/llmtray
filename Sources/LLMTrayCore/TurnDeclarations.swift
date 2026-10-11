import Foundation

/// One tool list per turn once the prompt is long (adr/0007, "One list per
/// turn"): the chat templates put the tools at the start of the prompt, so a
/// list changed between a turn's requests misses the server's prompt cache
/// and the whole chat is prefilled again (about a minute for 30K tokens on
/// Gemma 4 26B, adr/0020). The kept list's tools that may not run now are
/// refused when called, by the same checks as always.
public enum TurnDeclarations {
    /// From how many prompt tokens a turn keeps its list: below it a
    /// re-prefill costs seconds, and a narrower list keeps a small model
    /// from calling what it can't use.
    public static let keepFromPromptTokens = 3_000

    /// Whether a request's list becomes the turn's.
    public static func shouldKeep(alreadyKept: Bool, declared: Int, promptTokens: Int) -> Bool {
        !alreadyKept && declared > 0 && promptTokens >= keepFromPromptTokens
    }

    /// The kept list as it's sent again: without the tools no longer offered
    /// at all (a profile read again mid-turn switched one off).
    public static func repeated(_ kept: [[String: Any]], offered: Set<String>) -> [[String: Any]] {
        kept.filter { name(of: $0).map(offered.contains) ?? false }
    }

    public static func name(of definition: [String: Any]) -> String? {
        (definition["function"] as? [String: Any])?["name"] as? String
    }
}
