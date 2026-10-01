import Foundation

/// What `llmtray` prints (adr/0019 §4), pure so its wording is tested
/// without a terminal: plain English, like the CLI's errors (a terminal
/// tool's output is read by scripts and pasted into issues).
public enum CommandLineOutput {
    public static func status(_ s: ControlStatus) -> String {
        var state = s.state
        if let message = s.message, !message.isEmpty { state += ": " + message }
        if s.state == ControlStatus.stopped, s.idleUnloaded { state = "idle (the model was unloaded; the next request reloads it)" }
        var lines = ["LLMTray \(s.appVersion) -- server \(state)"]
        if let model = s.model {
            lines.append("  model     \(model)" + (s.modelPath.map { "  (\($0))" } ?? ""))
        }
        if let selected = s.selectedModel, selected != s.model {
            lines.append("  selected  \(selected)")
        }
        lines.append("  API       \(s.baseURL)" + (s.canAnswer ? "" : "  (listens once the server runs: llmtray start)"))
        return lines.joined(separator: "\n")
    }

    /// One row per model: selected (*), request name, size, loaded.
    public static func models(_ models: [ControlModel]) -> String {
        guard !models.isEmpty else {
            return "No chat models yet. Download one: llmtray pull <org/name> (e.g. mlx-community/Qwen3-4B-4bit)"
        }
        let width = min(60, models.map(\.name.count).max() ?? 0)
        return models.map { m in
            let size = m.sizeBytes.map(bytes) ?? "?"
            let name = m.name.padding(toLength: max(width, m.name.count), withPad: " ", startingAt: 0)
            return "\(m.selected ? "*" : " ") \(name)  \(size.leftPadded(to: 9))" + (m.loaded ? "  loaded" : "")
        }.joined(separator: "\n")
    }

    public static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }

    /// "[#####-----]  42%  detail" -- a download's or a generation's line.
    public static func progress(_ fraction: Double?, _ detail: String?) -> String {
        var parts: [String] = []
        if let fraction {
            let f = min(1, max(0, fraction))
            let filled = Int((f * 20).rounded(.down))
            parts.append("[" + String(repeating: "#", count: filled) + String(repeating: "-", count: 20 - filled) + "]")
            parts.append(String(format: "%3.0f%%", f * 100))
        }
        if let detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: "  ")
    }

    /// ./llmtray-20260930-142501.png
    public static func defaultImageName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "llmtray-\(formatter.string(from: date)).png"
    }

    /// `llmtray api`: the endpoint and how a client uses it.
    public static func api(_ s: ControlStatus, exampleModel: String?) -> String {
        let model = exampleModel ?? "<name from llmtray models>"
        var text = """
            OpenAI-compatible API: \(s.baseURL)

            Point an OpenAI client at it:
              export OPENAI_BASE_URL=\(s.baseURL)
              export OPENAI_API_KEY=local      # any value: LLMTray doesn't check it

            A request names the model by its name in `llmtray models` (without
            one, the loaded model answers):
              curl \(s.baseURL)/chat/completions -H 'Content-Type: application/json' \\
                -d '{"model": "\(model)", "messages": [{"role": "user", "content": "Hello"}]}'
            """
        if !s.canAnswer {
            text += "\n\nThe server isn't running, so nothing listens there yet: llmtray start"
        }
        return text
    }

    /// An OpenAI-style error body's message ({"error": {"message": ...}}),
    /// else the body itself, shortened.
    public static func apiError(status: Int, body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return "HTTP \(status): \(message)" }
            if let message = object["error"] as? String { return "HTTP \(status): \(message)" }
        }
        let text = String(decoding: body.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(text)"
    }
}

extension CLICommand.ChatOptions {
    /// The `/v1/chat/completions` body: streamed, with usage; the model
    /// only when one was named (else the proxy answers with the loaded one,
    /// adr/0002), so its profile's sampling defaults fill in the rest.
    public func requestBody(prompt: String) -> [String: Any] {
        var messages: [[String: Any]] = []
        if let system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": prompt])
        var body: [String: Any] = ["messages": messages, "stream": true, "stream_options": ["include_usage": true]]
        if let model { body["model"] = model }
        return body
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
