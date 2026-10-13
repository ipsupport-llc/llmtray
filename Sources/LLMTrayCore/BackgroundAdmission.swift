import Foundation

/// Background model work (adr/0024: memory's reflection, verify, classify
/// and tidy-up): requests the app makes while nobody is asking for
/// anything. The proxy lets one in only when no foreground request (the
/// chat, an outside client) is at the model, never loads or switches a
/// model for one, and cancels it the moment a foreground request arrives,
/// waiting for it to end before forwarding that one.
public enum BackgroundRequest {
    /// Marks an app request as background work. Honoured only with the
    /// app's own token (AppRequestToken): an outside client can't mark one.
    public static let header = "X-LLMTray-Background"
    public static let value = "1"

    /// The `code` of the proxy's refusals, in an OpenAI-shaped error.
    public static let busyCode = "background_busy"
    public static let notLoadedCode = "background_model_not_loaded"
    public static let preemptedCode = "background_preempted"

    /// How a background request ended.
    public enum Outcome: Equatable, Sendable {
        /// The model's answer (its content, without reasoning).
        case done(String)
        /// A foreground request was running, or another background one: later.
        case busy
        /// Its model isn't the loaded one, or none is: later, or never.
        case notLoaded
        /// A foreground request came: later, from the same place.
        case preempted
        case failed(String)

        /// Worth trying again later from the same place.
        public var isTransient: Bool {
            switch self {
            case .busy, .notLoaded, .preempted: return true
            case .done, .failed: return false
            }
        }
    }

    /// The outcome of an HTTP error answer from the proxy.
    public static func outcome(status: Int, body: Data) -> Outcome {
        let error = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let detail = error?["error"] as? [String: Any]
        switch detail?["code"] as? String {
        case busyCode: return .busy
        case notLoadedCode: return .notLoaded
        case preemptedCode: return .preempted
        default:
            let message = detail?["message"] as? String ?? (error?["error"] as? String) ?? "HTTP \(status)"
            return .failed(message)
        }
    }
}

/// Who is at the model: the proxy's bookkeeping for background admission.
/// Foreground requests are counted from the moment they head for the model
/// (before a model load) to their end; one background request at most.
public struct BackgroundAdmission: Equatable, Sendable {
    public private(set) var foreground = 0
    /// The running background request's id; nil when none.
    public private(set) var background: Int?
    private var nextID = 1

    public init() {}

    /// A background request asks to start: its id, or nil (busy).
    public mutating func admitBackground() -> Int? {
        guard foreground == 0, background == nil else { return nil }
        let id = nextID
        nextID += 1
        background = id
        return id
    }

    /// A foreground request heads for the model: the background request
    /// to preempt, if one runs. New background requests are refused from
    /// now until it ends.
    public mutating func foregroundBegan() -> Int? {
        foreground += 1
        return background
    }

    public mutating func foregroundEnded() {
        foreground = max(0, foreground - 1)
    }

    /// The background request `id` ended (done, refused, or preempted).
    public mutating func backgroundEnded(_ id: Int) {
        if background == id { background = nil }
    }
}

/// A streamed chat completion read for its content only (background work
/// streams, so cancelling it stops the model generating).
public struct StreamedContent: Equatable, Sendable {
    public private(set) var text = ""
    /// The stream said it's done ("data: [DONE]").
    public private(set) var done = false
    /// Why it stopped, as the last chunk with one said.
    public private(set) var finishReason: String?

    public init() {}

    /// One line of the event stream.
    public mutating func read(line: String) {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            done = true
            return
        }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first else { return }
        if let content = (choice["delta"] as? [String: Any])?["content"] as? String {
            text += content
        }
        if let reason = choice["finish_reason"] as? String {
            finishReason = reason
        }
    }
}
