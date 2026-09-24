import Foundation

/// One thing a streamed chat-completion chunk carried.
public enum SSEEvent: Equatable {
    case reasoning(String)
    case content(String)
    /// An inline (data: URI) image in a multimodal content array.
    case image(Data)
    case toolCall(id: String, name: String, argumentsJSON: String)
    /// The final stream_options.include_usage chunk.
    case usage(completionTokens: Int)
}

/// Turns an OpenAI-style `text/event-stream` chat-completion response into
/// events. Feed it text as it arrives (any chunking); incomplete lines are
/// kept for the next call.
public struct SSEDecoder {
    private var buffer = ""

    public init() {}

    public mutating func feed(_ text: String) -> [SSEEvent] {
        buffer += text
        var lines = buffer.components(separatedBy: "\n")
        // The last (possibly incomplete) line waits for the next chunk.
        buffer = lines.removeLast()
        return lines.flatMap(Self.events(fromLine:))
    }

    /// The events of a last line that never got its newline.
    public mutating func finish() -> [SSEEvent] {
        defer { buffer = "" }
        return Self.events(fromLine: buffer)
    }

    public static func events(fromLine rawLine: String) -> [SSEEvent] {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        guard line.hasPrefix("data: ") else { return [] }
        let payload = String(line.dropFirst("data: ".count))
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var events: [SSEEvent] = []
        // The usage chunk has an empty (or absent) choices array and a
        // top-level "usage" -- the accurate completion_tokens for tok/s.
        if let usage = obj["usage"] as? [String: Any], let tokens = usage["completion_tokens"] as? Int {
            events.append(.usage(completionTokens: tokens))
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return events }

        // mlx_lm.server uses "reasoning", some other OpenAI-compatible
        // servers "reasoning_content" -- both, so a server change can't
        // silently drop it.
        if let reasoning = (delta["reasoning"] as? String) ?? (delta["reasoning_content"] as? String),
           !reasoning.isEmpty {
            events.append(.reasoning(reasoning))
        }
        // Plain string content, or OpenAI's multimodal content array
        // ([{type: "text", text}, {type: "image_url", image_url: {url}}])
        // from a model that emits images.
        if let content = delta["content"] as? String, !content.isEmpty {
            events.append(.content(content))
        } else if let parts = delta["content"] as? [[String: Any]] {
            for part in parts {
                switch part["type"] as? String {
                case "text":
                    if let text = part["text"] as? String, !text.isEmpty { events.append(.content(text)) }
                case "image_url":
                    if let url = (part["image_url"] as? [String: Any])?["url"] as? String,
                       let image = decodeDataURI(url) {
                        events.append(.image(image))
                    }
                default:
                    break
                }
            }
        }
        // mlx_lm.server emits a tool call only once complete (it buffers
        // the model's <tool_call>...</tool_call> server-side), so
        // "arguments" is already whole JSON -- no merging of fragments by
        // index like OpenAI's own streaming protocol needs.
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            for call in calls {
                guard let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                events.append(.toolCall(
                    id: (call["id"] as? String) ?? UUID().uuidString,
                    name: name,
                    argumentsJSON: (function["arguments"] as? String) ?? "{}"
                ))
            }
        }
        return events
    }

    /// Decodes a "data:image/png;base64,..." URI. nil for a remote http(s)
    /// URL: fetching third-party content isn't "the model's own image".
    public static func decodeDataURI(_ uri: String) -> Data? {
        guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
    }
}
