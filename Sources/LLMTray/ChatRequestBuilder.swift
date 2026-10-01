import Foundation
import LLMTrayCore

/// Builds the chat-completion requests the in-app chat sends.
enum ChatRequestBuilder {
    /// A streaming request with this body (streamingBody).
    static func streaming(port: Int, body: [String: Any]) -> URLRequest? {
        request(port: port, body: body)
    }

    /// The body of a streaming request answering `history` (which must not
    /// include the empty assistant placeholder). `tools` are declared when
    /// non-empty, and the profile's tool-use rule then joins the system
    /// prompt. The project's instructions come from `settings.project`.
    /// `projectTools`: the names whose calls earlier turns leave out
    /// (withoutEarlier).
    static func streamingBody(
        modelAlias: String, settings: ChatSettings,
        history: [ChatMessage], tools: [[String: Any]], projectTools: Set<String> = []
    ) -> [String: Any] {
        let history = withoutEarlier(history, projectTools: projectTools)
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
        // The project's instructions between the profile's prompt and the
        // tool-use rule: the rules about tools come last whatever they say.
        let systemPrompt = chatSystemPrompt(profile: settings.systemPrompt, project: settings.project,
                                            toolUsePolicy: tools.isEmpty ? nil : settings.toolUsePolicy)
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
        return body
    }

    /// A request body's size for the token estimate: its JSON bytes with
    /// the images' data URIs left out, and how many images it carries.
    static func measure(_ body: [String: Any]) -> PromptTokenEstimator.Measure {
        var images = 0
        var stripped = body
        if let messages = body["messages"] as? [[String: Any]] {
            stripped["messages"] = messages.map { message -> [String: Any] in
                guard let parts = message["content"] as? [[String: Any]] else { return message }
                var m = message
                m["content"] = parts.map { part -> [String: Any] in
                    guard part["type"] as? String == "image_url" else { return part }
                    images += 1
                    return ["type": "image_url"]
                }
                return m
            }
        }
        let bytes = (try? JSONSerialization.data(withJSONObject: stripped))?.count ?? 0
        return PromptTokenEstimator.Measure(bytes: bytes, images: images)
    }

    /// The history without the tool calls of earlier turns that don't
    /// belong in later requests, each with its result (HistoryPruning):
    /// refused ones -- in the turn they happened the model needs them,
    /// later they only read as "the image wasn't made" -- and project
    /// tools' (`projectTools`), which a saved chat doesn't have either: a
    /// live chat sends what it would after a reload, the answer and its
    /// citations without the file text. The current turn -- after the
    /// user's last message -- is kept whole.
    static func withoutEarlier(_ history: [ChatMessage], projectTools: Set<String>) -> [ChatMessage] {
        guard let plan = HistoryPruning.plan(history.map(\.historyEntry), projectTools: projectTools) else { return history }
        return zip(history, plan).compactMap { message, keptCalls in
            guard let keptCalls else { return nil }
            var kept = message
            kept.toolCalls.removeAll { !keptCalls.contains($0.id) }
            return kept
        }
    }

    /// A one-shot (non-streaming) request of the app's own -- a chat's
    /// title, a compaction summary: no reasoning first. Gemma 4's template
    /// thinks unless told not to (a title used to spend up to 2048 tokens
    /// thinking), and with an MTP drafter the server answers one request
    /// at a time, so the user's next message waited for it. Gemma 4's and
    /// Nemotron's templates read the switch; a model that thinks anyway
    /// still has room for it before its answer (max_tokens).
    static func completion(port: Int, modelAlias: String, messages: [[String: Any]]) -> URLRequest? {
        request(port: port, body: [
            "model": modelAlias,
            "messages": messages,
            "stream": false,
            "temperature": 0.3,
            // Room for a model's reasoning if it thinks anyway.
            "max_tokens": 2048,
            "chat_template_kwargs": ["enable_thinking": false],
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
        // The app's own chat: switches models whatever the switching policy.
        request.setValue(AppRequestToken.value, forHTTPHeaderField: AppRequestToken.header)
        request.httpBody = data
        request.timeoutInterval = 300
        return request
    }
}
