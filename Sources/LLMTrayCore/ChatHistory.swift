import Foundation

/// The shape of a chat history that its request pruning and compaction look
/// at, without the app's message type.
public struct HistoryEntry: Equatable {
    public var role: String
    /// A message the app added for the model only (view_image's image).
    public var isToolContext: Bool
    /// An assistant message's tool calls: (id, name).
    public var toolCalls: [HistoryCall]
    /// A tool result's call.
    public var toolCallID: String?
    public var isRefusal: Bool
    /// Text, images or music of its own (without its calls).
    public var hasContent: Bool

    public init(role: String, isToolContext: Bool = false, toolCalls: [HistoryCall] = [], toolCallID: String? = nil,
                isRefusal: Bool = false, hasContent: Bool = true) {
        self.role = role
        self.isToolContext = isToolContext
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.isRefusal = isRefusal
        self.hasContent = hasContent
    }
}

public struct HistoryCall: Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What a request leaves out of earlier turns (adr/0007, adr/0012).
public enum HistoryPruning {
    /// Where the current turn starts: the user's last own message.
    public static func turnStart(_ entries: [HistoryEntry]) -> Int? {
        entries.lastIndex { $0.role == "user" && !$0.isToolContext }
    }

    /// Earlier turns without the tool calls that don't belong in later
    /// requests, each with its result: refused ones (read back, "not run"
    /// made small models think the image was never made), and project tool
    /// calls -- a saved chat has none of them, so a live one sends what it
    /// would after a reload, and old file text doesn't pile up turn after
    /// turn. Per message: `nil` leaves it out, else the ids of its calls to
    /// keep. The current turn is kept whole; an assistant message that was
    /// only dropped calls goes (its answer, if it had one, stays). A call
    /// is its message's: a model may reuse an id in another round, and a
    /// result belongs to the latest call with its id before it. nil when
    /// nothing is dropped.
    public static func plan(_ entries: [HistoryEntry], projectTools: Set<String>) -> [[String]?]? {
        guard let start = turnStart(entries) else { return nil }
        // The message each earlier result answers, and the calls to drop.
        var owner: [Int: Int] = [:]
        var latest: [String: Int] = [:]
        var dropped: Set<CallKey> = []
        for (i, entry) in entries[..<start].enumerated() {
            for call in entry.toolCalls {
                latest[call.id] = i
                if projectTools.contains(call.name) { dropped.insert(CallKey(message: i, id: call.id)) }
            }
            if entry.role == "tool", let id = entry.toolCallID, let o = latest[id] {
                owner[i] = o
                if entry.isRefusal { dropped.insert(CallKey(message: o, id: id)) }
            }
        }
        guard !dropped.isEmpty else { return nil }
        return entries.enumerated().map { i, entry in
            let all = entry.toolCalls.map(\.id)
            guard i < start else { return all }
            if entry.role == "tool", let id = entry.toolCallID, let o = owner[i], dropped.contains(CallKey(message: o, id: id)) { return nil }
            let kept = all.filter { !dropped.contains(CallKey(message: i, id: $0)) }
            if entry.role == "assistant", kept.isEmpty, !all.isEmpty, !entry.hasContent { return nil }
            return kept
        }
    }

    /// A call: the message it's in, and its id.
    private struct CallKey: Hashable {
        var message: Int
        var id: String
    }
}

/// The transcript a compaction summary is written from (adr/0006): the
/// user's and the model's own words only. Tool results are left out --
/// file or web text summarized there would come back as the chat's own,
/// trusted history (adr/0012).
public enum CompactionTranscript {
    public struct Line {
        public var role: String
        public var content: String
        public var reasoning: String
        public var isToolContext: Bool

        public init(role: String, content: String, reasoning: String = "", isToolContext: Bool = false) {
            self.role = role
            self.content = content
            self.reasoning = reasoning
            self.isToolContext = isToolContext
        }
    }

    public static func make(_ lines: [Line]) -> String {
        lines.filter { $0.role != "tool" && !$0.isToolContext }.map { line in
            "\(line.role == "user" ? "User" : "Assistant"): \(line.content.isEmpty ? line.reasoning : line.content)"
        }.joined(separator: "\n\n")
    }
}
