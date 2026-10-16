import CryptoKit
import Foundation

/// The parts of the Model Context Protocol the chat's client speaks
/// (adr/0027): JSON-RPC 2.0 messages, the versions it accepts, a server's
/// tools and what a call returns.
public enum MCP {
    /// Newest first: asked for the first, any of them accepted back.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// The client's name in `initialize`.
    public static var clientInfo: [String: Any] {
        ["name": "LLMTray", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"]
    }

    /// Most characters of a call's text handed to the model.
    public static let resultCharacters = 16_000

    /// A JSON-RPC message as read: a request or notification from the
    /// server (`method`), or a reply to one of ours (`id` with `result` or
    /// `error`).
    public struct Message {
        public var id: Int?
        /// The server's own request id, as sent (a number or a string).
        public var rawID: Any?
        public var method: String?
        public var params: [String: Any]?
        public var result: [String: Any]?
        public var error: (code: Int, message: String)?

        /// One message from a line or an HTTP body; nil for anything that
        /// isn't a JSON-RPC object. A batch (an array) gives its first
        /// readable member only: servers don't batch replies to us.
        public static func parse(_ data: Data) -> [Message] {
            guard let any = try? JSONSerialization.jsonObject(with: data) else { return [] }
            let objects = (any as? [[String: Any]]) ?? [(any as? [String: Any])].compactMap { $0 }
            return objects.compactMap(Message.init(object:))
        }

        init?(object: [String: Any]) {
            guard object["jsonrpc"] as? String == "2.0" else { return nil }
            rawID = object["id"]
            if let n = object["id"] as? Int { id = n } else if let s = object["id"] as? String { id = Int(s) }
            method = object["method"] as? String
            params = object["params"] as? [String: Any]
            result = object["result"] as? [String: Any]
            if let e = object["error"] as? [String: Any] {
                error = ((e["code"] as? Int) ?? -32603, (e["message"] as? String) ?? "error")
            }
            guard method != nil || rawID != nil else { return nil }
        }
    }

    public static func request(id: Int, method: String, params: [String: Any]? = nil) -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { object["params"] = params }
        return encode(object)
    }

    public static func notification(_ method: String, params: [String: Any]? = nil) -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { object["params"] = params }
        return encode(object)
    }

    /// A reply to the server's own request (a ping): an empty result, or
    /// "method not found" for anything we don't serve.
    public static func reply(to id: Any, result: [String: Any]?) -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let result { object["result"] = result } else { object["error"] = ["code": -32601, "message": "Method not found"] }
        return encode(object)
    }

    static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
    }

    public static func initializeParams(version: String = protocolVersions[0]) -> [String: Any] {
        // Asked for nothing (no roots, sampling or elicitation): v1 serves none.
        ["protocolVersion": version, "capabilities": [String: Any](), "clientInfo": clientInfo]
    }

    // MARK: Tools

    /// One tool a server offers, as listed.
    public struct Tool: Equatable, Sendable {
        public var name: String
        public var title: String?
        public var description: String
        /// The JSON Schema as sent, kept as JSON text (sorted keys): passed
        /// to the model unchanged.
        public var inputSchemaJSON: String
        /// What the server says about it: shown, never trusted.
        public var readOnlyHint: Bool?
        public var destructiveHint: Bool?

        public init(name: String, title: String? = nil, description: String, inputSchemaJSON: String,
                    readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil) {
            self.name = name
            self.title = title
            self.description = description
            self.inputSchemaJSON = inputSchemaJSON
            self.readOnlyHint = readOnlyHint
            self.destructiveHint = destructiveHint
        }

        init?(object: [String: Any]) {
            guard let name = object["name"] as? String, !name.isEmpty else { return nil }
            self.name = name
            title = object["title"] as? String ?? (object["annotations"] as? [String: Any])?["title"] as? String
            description = object["description"] as? String ?? ""
            let schema = object["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]
            inputSchemaJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8),
                                     as: UTF8.self)
            let annotations = object["annotations"] as? [String: Any]
            readOnlyHint = annotations?["readOnlyHint"] as? Bool
            destructiveHint = annotations?["destructiveHint"] as? Bool
        }

        public var inputSchema: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(inputSchemaJSON.utf8))) as? [String: Any] ?? [:]
        }

        /// What the user reviewed: name, description and schema. An
        /// approval holds for this hash only (adr/0027).
        public var definitionHash: String {
            let text = name + "\u{0}" + description + "\u{0}" + inputSchemaJSON
            return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        }

        /// A top-level string field with a fixed list of values (`action`,
        /// `mode`): approvals are per value. The first such required field,
        /// else the first such field.
        public var actionField: (name: String, values: [String])? {
            let schema = inputSchema
            guard let properties = schema["properties"] as? [String: Any] else { return nil }
            let required = schema["required"] as? [String] ?? []
            let fields = properties.compactMap { key, value -> (String, [String])? in
                guard let p = value as? [String: Any], (p["type"] as? String ?? "string") == "string",
                      let values = p["enum"] as? [String], !values.isEmpty else { return nil }
                return (key, values)
            }.sorted { $0.0 < $1.0 }
            return fields.first { required.contains($0.0) } ?? fields.first
        }
    }

    /// `tools/list`'s page: the tools and the cursor of the next page.
    public static func parseTools(_ result: [String: Any]) -> (tools: [Tool], next: String?) {
        let tools = (result["tools"] as? [[String: Any]] ?? []).compactMap(Tool.init(object:))
        return (tools, result["nextCursor"] as? String)
    }

    // MARK: Results

    /// A call's result as the model's tool text: text parts joined, else
    /// structured content as compact JSON; other parts named; at most
    /// `limit` characters with how much was cut. `isError` says the tool
    /// failed (its text is the error).
    public static func resultText(_ result: [String: Any], limit: Int = resultCharacters) -> (text: String, isError: Bool) {
        let isError = result["isError"] as? Bool ?? false
        var parts: [String] = []
        var other: [String] = []
        for part in result["content"] as? [[String: Any]] ?? [] {
            switch part["type"] as? String {
            case "text": if let t = part["text"] as? String { parts.append(t) }
            case "resource":
                if let r = part["resource"] as? [String: Any], let t = r["text"] as? String { parts.append(t) }
                else { other.append("resource") }
            case let kind?: other.append(kind)
            case nil: break
            }
        }
        var text = parts.joined(separator: "\n")
        if text.isEmpty, let structured = result["structuredContent"],
           JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys, .withoutEscapingSlashes]) {
            text = String(decoding: data, as: UTF8.self)
        }
        if !other.isEmpty {
            let counts = Dictionary(grouping: other, by: { $0 }).map { "\($0.value.count) \($0.key)" }.sorted()
            text += (text.isEmpty ? "" : "\n") + "[Not shown: \(counts.joined(separator: ", ")).]"
        }
        if text.isEmpty { text = isError ? "The tool failed and said nothing." : "(no output)" }
        if text.count > limit {
            let cut = text.count - limit
            text = String(text.prefix(limit)) + "\n[Cut: \(cut) more characters.]"
        }
        return (text, isError)
    }

    /// What the model is told when a call's outcome is unknown (a time
    /// limit, Stop, a lost session): it may have happened.
    public static let unknownOutcomeText = "No answer from the server in time: the call may or may not have happened. Check before trying again, and don't repeat it without asking the user."
}
