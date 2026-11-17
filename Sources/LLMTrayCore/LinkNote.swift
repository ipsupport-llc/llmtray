import Foundation

/// The in-app chat's reminder with a user message that has a link: small
/// models given a link tend to say they can't open it without trying the
/// page tool they have. Only the app's own
/// chat sends it -- never requests from API clients (coding agents).
public enum LinkNote {
    /// The web links in `text` written with their scheme (http://,
    /// https://), in order, each once. A bare name isn't one: the system
    /// detector makes https://main.rs of "src/main.rs" and https://user.id
    /// of code. Local addresses (localhost, 127.x) aren't read anyway.
    public static func links(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\bhttps?://[^\s<>"'`]+"#) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            let link = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}»"))
            guard let host = URL(string: link)?.host?.lowercased(), !host.isEmpty,
                  host != "localhost", !host.hasPrefix("127."), host != "[::1]", host != "::1" else { return nil }
            return seen.insert(link).inserted ? link : nil
        }
    }

    /// The note for a user message: nil without a link, or when the page
    /// tool isn't declared in this request (a chat without it, a coding
    /// profile, gets nothing).
    public static func text(for message: String, canReadPages: Bool) -> String? {
        let count = canReadPages ? links(in: message).count : 0
        guard count > 0 else { return nil }
        return count == 1
            ? "[App note, not the user's words: the message has a link. To read it, call web_search with source=page and url set to the link.]"
            : "[App note, not the user's words: the message has \(count) links. To read one, call web_search with source=page and url set to that link.]"
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
