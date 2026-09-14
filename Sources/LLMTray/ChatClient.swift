import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: String   // "user" | "assistant"
    var content: String = ""
    var reasoning: String = ""
}

struct ChatSettings {
    var temperature: Double = 0.6
    var topP: Double = 0.95
    var maxTokens: Int = 1024
}

@MainActor
final class ChatClient: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming: Bool = false
    @Published var lastTokensPerSecond: Double?
    @Published var errorText: String?

    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var sseBuffer: String = ""
    // Set directly in the nonisolated URLSession delegate callback below, at
    // the real moment the first byte arrives on the network -- not inside
    // the `Task { @MainActor in ... }` that processes it. That dispatched
    // Task can lag behind the actual network event when the main thread is
    // busy (e.g. re-rendering the chat bubble on every streamed delta), and
    // measuring from a delayed dispatch point silently compresses the
    // apparent elapsed time toward zero, which is what was inflating tok/s
    // to nonsense values.
    nonisolated(unsafe) private var firstByteDate: Date?
    private var approxCompletionTokens: Int = 0
    private var usageCompletionTokens: Int?
    private var assistantMessageIndex: Int?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func send(prompt: String, port: Int, modelAlias: String, settings: ChatSettings) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        messages.append(ChatMessage(role: "user", content: prompt))
        startAssistantResponse(port: port, modelAlias: modelAlias, settings: settings)
    }

    /// Re-runs the last user turn with a fresh generation -- drops the
    /// previous assistant reply (if any) so the retry doesn't just pile up
    /// underneath a garbled/unhelpful one, then asks again with the exact
    /// same prompt.
    func regenerate(port: Int, modelAlias: String, settings: ChatSettings) {
        guard !isStreaming else { return }
        if messages.last?.role == "assistant" {
            messages.removeLast()
        }
        guard messages.last?.role == "user" else { return }
        startAssistantResponse(port: port, modelAlias: modelAlias, settings: settings)
    }

    private func startAssistantResponse(port: Int, modelAlias: String, settings: ChatSettings) {
        errorText = nil
        messages.append(ChatMessage(role: "assistant"))
        assistantMessageIndex = messages.count - 1

        let payloadMessages: [[String: String]] = messages.dropLast(1).map { ["role": $0.role, "content": $0.content] }

        let body: [String: Any] = [
            "model": modelAlias,
            "messages": payloadMessages,
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": settings.temperature,
            "top_p": settings.topP,
            "max_tokens": settings.maxTokens,
        ]

        guard let url = URL(string: "http://localhost:\(port)/v1/chat/completions"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            errorText = "failed to build request"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 300

        sseBuffer = ""
        approxCompletionTokens = 0
        usageCompletionTokens = nil
        firstByteDate = nil
        isStreaming = true

        task = session.dataTask(with: request)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        isStreaming = false
    }

    func clear() {
        cancel()
        messages.removeAll()
        lastTokensPerSecond = nil
        errorText = nil
    }

    // MARK: - URLSessionDataDelegate (incremental SSE parsing)

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if firstByteDate == nil {
            firstByteDate = Date()
        }
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        Task { @MainActor in
            self.handleChunk(chunk)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Captured here, synchronously in the real delegate callback, for
        // the same reason as firstByteDate above -- not inside the
        // dispatched Task, which could run late.
        let completionDate = Date()
        Task { @MainActor in
            self.isStreaming = false
            if let error, (error as NSError).code != NSURLErrorCancelled {
                self.errorText = error.localizedDescription
            }
            self.finalizeTokensPerSecond(endDate: completionDate)
        }
    }

    private func finalizeTokensPerSecond(endDate: Date) {
        guard let start = firstByteDate else { return }
        let elapsed = endDate.timeIntervalSince(start)
        // Sub-50ms is measurement noise (SSE framing, a one-word reply),
        // not a real generation rate -- dividing by it is what produced
        // the nonsense "cosmos" numbers.
        guard elapsed > 0.05 else { return }
        // Prefer the server's real completion_tokens (from the final
        // stream_options.include_usage chunk) over the word-count proxy --
        // this is only an approximation when the server doesn't send usage.
        let tokenCount = usageCompletionTokens ?? approxCompletionTokens
        guard tokenCount > 0 else { return }
        lastTokensPerSecond = Double(tokenCount) / elapsed
    }

    private func handleChunk(_ chunk: String) {
        sseBuffer += chunk
        let lines = sseBuffer.components(separatedBy: "\n")
        // Keep the last (possibly incomplete) line in the buffer for next time.
        sseBuffer = lines.last ?? ""
        for line in lines.dropLast() {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            // The final stream_options.include_usage chunk has an empty (or
            // absent) choices array and a top-level "usage" object -- this is
            // the accurate completion_tokens count for tok/s, when present.
            if let usage = obj["usage"] as? [String: Any],
               let completionTokens = usage["completion_tokens"] as? Int {
                usageCompletionTokens = completionTokens
            }

            guard let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any] else { continue }

            // mlx_lm.server puts this under the key "reasoning", not the
            // "reasoning_content" name some other OpenAI-compatible servers
            // use -- checking both means this doesn't silently break again
            // if a future server build changes it back.
            let reasoningValue = (delta["reasoning"] as? String) ?? (delta["reasoning_content"] as? String)
            if let reasoning = reasoningValue, !reasoning.isEmpty {
                appendToAssistant(reasoning: reasoning)
                approxCompletionTokens += max(1, reasoning.split(whereSeparator: { $0.isWhitespace }).count)
            }
            if let content = delta["content"] as? String, !content.isEmpty {
                appendToAssistant(content: content)
                // Word-count proxy, used only if the server never sends a
                // real usage.completion_tokens (see finalizeTokensPerSecond).
                approxCompletionTokens += max(1, content.split(whereSeparator: { $0.isWhitespace }).count)
            }
        }
    }

    private func appendToAssistant(content: String) {
        guard let idx = assistantMessageIndex, idx < messages.count else { return }
        messages[idx].content += content
    }

    private func appendToAssistant(reasoning: String) {
        guard let idx = assistantMessageIndex, idx < messages.count else { return }
        messages[idx].reasoning += reasoning
    }
}
