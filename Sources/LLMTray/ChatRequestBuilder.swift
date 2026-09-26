import Foundation

/// Builds the chat-completion requests the in-app chat sends.
enum ChatRequestBuilder {
    /// A streaming request answering `history` (which must not include the
    /// empty assistant placeholder). `tools` are declared when non-empty,
    /// and the profile's tool-use rule then joins the system prompt.
    static func streaming(
        port: Int, modelAlias: String, settings: ChatSettings,
        history: [ChatMessage], tools: [[String: Any]]
    ) -> URLRequest? {
        let history = withoutEarlierRefusals(history)
        // An image a tool put in front of the model goes with the request
        // right after it only -- not again with every later one.
        let lastIndex = history.indices.last
        var payload = history.enumerated().map { i, message in
            // A model without vision refuses any request carrying an image
            // (mlx_lm.server): a chat that had one, continued with a text
            // model, sends just the text.
            message.isToolContext && i != lastIndex || !settings.modelSupportsVision && !message.images.isEmpty
                ? serialize(message: ChatMessage(role: message.role,
                                                 content: message.content.isEmpty && !settings.modelSupportsVision ? "(image)" : message.content,
                                                 toolCalls: message.toolCalls, toolCallID: message.toolCallID))
                : serialize(message: message)
        }
        let userSystemPrompt = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = [userSystemPrompt, tools.isEmpty ? "" : settings.toolUsePolicy]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !systemPrompt.isEmpty {
            payload.insert(["role": "system", "content": systemPrompt], at: 0)
        }

        var body: [String: Any] = [
            "model": modelAlias,
            "messages": payload,
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": settings.temperature,
            "top_p": settings.topP,
            "max_tokens": settings.maxTokens,
            // Always sent, 0 included: omitting it would fall back to the
            // server's launch-time --top-k, stale after a profile change.
            "top_k": settings.topK,
        ]
        if !tools.isEmpty {
            body["tools"] = tools
        }
        return request(port: port, body: body)
    }

    /// The history without refused tool calls of earlier turns (the call
    /// and its "not run" result): in the turn they happened the model needs
    /// them, later they only read as "the image wasn't made". The current
    /// turn -- after the user's last message -- is kept whole.
    static func withoutEarlierRefusals(_ history: [ChatMessage]) -> [ChatMessage] {
        guard let turnStart = history.lastIndex(where: { $0.role == "user" && !$0.isToolContext }) else { return history }
        let refused = Set(history[..<turnStart].compactMap { $0.isRefusal ? $0.toolCallID : nil })
        guard !refused.isEmpty else { return history }
        var out: [ChatMessage] = []
        for (i, message) in history.enumerated() {
            guard i < turnStart else { out.append(message); continue }
            if message.role == "tool", let id = message.toolCallID, refused.contains(id) { continue }
            var kept = message
            kept.toolCalls.removeAll { refused.contains($0.id) }
            // A message that was only those calls.
            if kept.role == "assistant", kept.toolCalls.isEmpty, !message.toolCalls.isEmpty,
               kept.content.isEmpty, kept.images.isEmpty, kept.audios.isEmpty { continue }
            out.append(kept)
        }
        return out
    }

    /// A one-shot (non-streaming) request, e.g. for a compaction summary.
    static func completion(port: Int, modelAlias: String, messages: [[String: Any]]) -> URLRequest? {
        request(port: port, body: [
            "model": modelAlias,
            "messages": messages,
            "stream": false,
            "temperature": 0.3,
            // Room for a thinking model's reasoning before the summary.
            "max_tokens": 2048,
        ])
    }

    /// Serializes one message in whichever of the three shapes OpenAI's
    /// tool-calling protocol expects: a plain user/system/assistant turn, an
    /// assistant turn that called tool(s) (tool_calls attached, content
    /// omitted if the model produced none), or a "tool" result keyed by
    /// tool_call_id.
    static func serialize(message: ChatMessage) -> [String: Any] {
        if message.role == "tool" {
            return ["role": "tool", "tool_call_id": message.toolCallID ?? "", "content": message.content]
        }
        if message.role == "assistant", !message.toolCalls.isEmpty {
            var dict: [String: Any] = ["role": "assistant"]
            if !message.content.isEmpty {
                dict["content"] = message.content
            }
            dict["tool_calls"] = message.toolCalls.map { call in
                ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.argumentsJSON]]
            }
            return dict
        }
        if message.role == "user", !message.images.isEmpty {
            // Attachments are always normalized to PNG before landing in
            // ChatMessage.images (see ContentView's attach-file handling),
            // so the MIME half of this data URI is never a guess.
            var parts: [[String: Any]] = []
            if !message.content.isEmpty {
                parts.append(["type": "text", "text": message.content])
            }
            for data in message.images {
                let url = "data:image/png;base64,\(data.base64EncodedString())"
                parts.append(["type": "image_url", "image_url": ["url": url]])
            }
            return ["role": "user", "content": parts]
        }
        return ["role": message.role, "content": message.content]
    }

    private static func request(port: Int, body: [String: Any]) -> URLRequest? {
        guard let url = URL(string: "http://localhost:\(port)/v1/chat/completions"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 300
        return request
    }
}
