import Foundation

/// The in-app chat's reminder with a user message that has a link: small
/// models given a link tend to say they can't open it without trying the
/// page tool they have. Only the app's own
/// chat sends it -- never requests from API clients (coding agents).
public enum LinkNote {
    /// The web links (http, https) in `text`, in order, each once.
    public static func links(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return seen.insert(url.absoluteString).inserted ? url.absoluteString : nil
        }
    }

    /// The note for a user message: nil without a link, or when the page
    /// tool isn't declared in this request (a chat without it, a coding
    /// profile, gets nothing).
    public static func text(for message: String, canReadPages: Bool) -> String? {
        guard canReadPages, !links(in: message).isEmpty else { return nil }
        return "[App note, not the user's words: the message has a link. "
            + "To read it, call web_search with source=page and url set to the link.]"
    }

    /// Whether `tools` (the request's declarations) include the page tool.
    public static func declaresPageReading(_ tools: [[String: Any]]) -> Bool {
        tools.contains { tool in
            guard let function = tool["function"] as? [String: Any], function["name"] as? String == "web_search",
                  let parameters = function["parameters"] as? [String: Any],
                  let properties = parameters["properties"] as? [String: Any] else { return false }
            return properties["url"] != nil
        }
    }
}
