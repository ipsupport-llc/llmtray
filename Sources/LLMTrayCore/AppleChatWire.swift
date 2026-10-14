import Foundation

/// The OpenAI chat-completion shapes the proxy answers Apple's model's
/// requests with (adr/0025): what `ChatClient`, `ChatTransport`, the CLI and
/// outside clients already read from mlx_lm.server.
public struct AppleChatWire: Sendable {
    public let id: String
    public let created: Int
    public let model: String

    public init(id: String = "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                created: Int = Int(Date().timeIntervalSince1970), model: String = AppleSystemModel.id) {
        self.id = id
        self.created = created
        self.model = model
    }

    /// What a request asks for: its messages and the knobs Apple's model has.
    public struct Request: Sendable {
        public var messages: [[String: any Sendable]]
        public var stream: Bool
        public var includeUsage: Bool
        public var maxTokens: Int?
        public var temperature: Double?

        /// nil when the body isn't a chat request (no messages).
        public init?(body: Data, contextSize: Int?) {
            guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let messages = object["messages"] as? [[String: Any]], !messages.isEmpty else { return nil }
            self.messages = messages.map { $0.mapValues { $0 as any Sendable } }
            stream = object["stream"] as? Bool ?? false
            includeUsage = (object["stream_options"] as? [String: Any])?["include_usage"] as? Bool ?? false
            let asked = (object["max_completion_tokens"] as? Int) ?? (object["max_tokens"] as? Int)
            // The context holds the input and the answer: at most half of it
            // for the answer (the chat's own max_tokens is sized for big models).
            let cap = contextSize.map { max(256, $0 / 2) }
            maxTokens = [asked, cap].compactMap { $0 }.min()
            temperature = (object["temperature"] as? NSNumber)?.doubleValue
        }

        public var plainMessages: [[String: Any]] { messages.map { $0.mapValues { $0 as Any } } }
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// One SSE event line ("data: …\n\n").
    public static func event(_ json: String) -> String { "data: \(json)\n\n" }
    public static let done = "data: [DONE]\n\n"

    /// The first chunk: the assistant's role, no text yet.
    public func roleChunk() -> String {
        Self.json(chunk(delta: ["role": "assistant", "content": ""], finish: nil))
    }

    public func textChunk(_ text: String) -> String {
        Self.json(chunk(delta: ["content": text], finish: nil))
    }

    public func finishChunk(_ reason: String = "stop") -> String {
        Self.json(chunk(delta: [:], finish: reason))
    }

    public func usageChunk(_ usage: AppleSystemModel.Usage) -> String {
        Self.json(["id": id, "object": "chat.completion.chunk", "created": created, "model": model,
                   "choices": [] as [Any], "usage": Self.usage(usage)])
    }

    /// An error after the answer began: shown by the chat as an error.
    public static func errorChunk(_ message: String, code: String) -> String {
        json(["error": ["message": message, "type": code, "code": code]])
    }

    /// A whole answer (`stream: false`: titles, compaction, outside callers).
    public func completion(_ text: String, usage: AppleSystemModel.Usage?) -> String {
        var object: [String: Any] = [
            "id": id, "object": "chat.completion", "created": created, "model": model,
            "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
        ]
        if let usage { object["usage"] = Self.usage(usage) }
        return Self.json(object)
    }

    /// An error before the answer: mlx_lm.server's shape, which
    /// `ChatTransport` reads ({"error": "…"}).
    public static func errorBody(_ message: String) -> String { json(["error": message]) }

    /// The HTTP status and body a failure is answered with.
    public static func status(of failure: AppleSystemModel.Failure) -> (status: String, code: String, message: String) {
        switch failure {
        case .unavailable(let why):
            return ("503 Service Unavailable", "model_unavailable", why.isEmpty ? "Apple's model isn't available" : why)
        case .refused:
            return ("400 Bad Request", "content_refused", "Apple's model declined this request (its safety guardrails)")
        case .contextExceeded:
            return ("400 Bad Request", "context_length_exceeded", "the chat is too long for Apple's model: compact it or start a new one")
        case .timedOut:
            return ("504 Gateway Timeout", "timeout", "Apple's model stopped answering")
        case .failed(let why):
            return ("500 Internal Server Error", "model_failed", why)
        }
    }

    private func chunk(delta: [String: Any], finish: String?) -> [String: Any] {
        ["id": id, "object": "chat.completion.chunk", "created": created, "model": model,
         "choices": [["index": 0, "delta": delta, "finish_reason": finish ?? NSNull()] as [String: Any]]]
    }

    private static func usage(_ usage: AppleSystemModel.Usage) -> [String: Any] {
        ["prompt_tokens": usage.prompt, "completion_tokens": usage.completion, "total_tokens": usage.prompt + usage.completion]
    }
}
