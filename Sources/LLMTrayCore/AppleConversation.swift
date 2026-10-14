import Foundation

/// An OpenAI chat request's messages as Apple's on-device model takes them
/// (adr/0025): instructions, the earlier turns, and the prompt. Pure, so it's
/// tested where the model isn't.
public struct AppleConversation: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable { case user, assistant }

    /// The system messages, joined.
    public var instructions: String
    /// What came before the prompt, oldest first.
    public var turns: [Turn]
    /// The last user message: what the model answers.
    public var prompt: String

    public struct Turn: Equatable, Sendable {
        public var role: Role
        public var text: String
    }

    /// nil when there's no user message to answer.
    public init?(messages: [[String: Any]]) {
        var system: [String] = []
        var turns: [Turn] = []
        for message in messages {
            let text = Self.text(of: message["content"])
            switch message["role"] as? String {
            case "system", "developer":
                if !text.isEmpty { system.append(text) }
            case "user":
                if !text.isEmpty { turns.append(Turn(role: .user, text: text)) }
            case "assistant":
                // A tool call the chat made, said in words; an empty turn goes.
                let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap {
                    ($0["function"] as? [String: Any])?["name"] as? String
                }
                let said = text + (calls.isEmpty ? "" : (text.isEmpty ? "" : "\n") + "[called: \(calls.joined(separator: ", "))]")
                if !said.isEmpty { turns.append(Turn(role: .assistant, text: said)) }
            case "tool":
                // A tool's result is data in the turns, never instructions.
                if !text.isEmpty { turns.append(Turn(role: .user, text: "[tool result: \(text)]")) }
            default:
                continue
            }
        }
        guard let last = turns.lastIndex(where: { $0.role == .user }) else { return nil }
        prompt = turns[last].text
        // What followed the last user message (a tool result's answer) is
        // left out: the prompt is answered as the latest thing said.
        self.turns = Array(turns[..<last])
        instructions = system.joined(separator: "\n\n")
    }

    /// A message's text: a string, or the text parts of a parts array
    /// (images and audio are left out).
    static func text(of content: Any?) -> String {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { part -> String? in
            guard (part["type"] as? String) == "text" else { return nil }
            return part["text"] as? String
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
