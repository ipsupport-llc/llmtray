import Foundation

/// The in-app chat's HTTP side: streams a chat-completion response as
/// text (split only at line ends, so a multi-byte character cut by the
/// network is never lost) and reports how the request ended. One stream
/// at a time; a new one or cancel() makes a previous stream's late
/// callbacks no-ops.
@MainActor
final class ChatTransport: NSObject, URLSessionDataDelegate {
    struct Completion {
        var statusCode: Int?
        /// The response body when the status isn't 2xx (mlx_lm.server
        /// reports request errors as plain JSON, not SSE).
        var errorBody: Data
        var error: Error?
        /// When the first byte arrived and when the request ended --
        /// captured in the delegate callbacks themselves, not in the
        /// dispatched main-actor work, which can run late while the UI
        /// re-renders (that lag once inflated tok/s to nonsense).
        var firstByteDate: Date?
        var endDate: Date

        var isHTTPError: Bool { statusCode.map { !(200..<300).contains($0) } ?? false }
    }

    private struct Handlers {
        var onText: (String) -> Void
        var onComplete: (Completion) -> Void
    }

    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var handlers: Handlers?
    private nonisolated let streams = StreamStates()

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func stream(_ request: URLRequest, onText: @escaping (String) -> Void, onComplete: @escaping (Completion) -> Void) {
        cancel()
        let newTask = session.dataTask(with: request)
        streams.begin(newTask.taskIdentifier)
        task = newTask
        handlers = Handlers(onText: onText, onComplete: onComplete)
        newTask.resume()
    }

    /// Stops the current stream; none of its callbacks run afterwards.
    func cancel() {
        task?.cancel()
        task = nil
        handlers = nil
    }

    /// One-shot request returning the first choice's message content.
    static func completion(_ request: URLRequest) async throws -> String {
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
            throw NSError(
                domain: "ChatTransport", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected response shape from the chat completion endpoint."]
            )
        }
        // Cut off at max_tokens, or all of it spent reasoning: not an answer.
        if choices.first?["finish_reason"] as? String == "length" {
            throw NSError(domain: "ChatTransport", code: 2, userInfo: [NSLocalizedDescriptionKey: "the answer was cut off (token limit)"])
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "ChatTransport", code: 3, userInfo: [NSLocalizedDescriptionKey: "the model returned an empty answer"])
        }
        return content
    }

    /// mlx_lm.server's error bodies are `{"error": "<message>"}`; falls
    /// back to the raw body (or just the status) for anything else.
    static func serverErrorMessage(statusCode: Int, body: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let message = obj["error"] as? String, !message.isEmpty {
            return "Server error (\(statusCode)): \(message)"
        }
        let raw = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "Server error (\(statusCode))" : "Server error (\(statusCode)): \(raw)"
    }

    // MARK: - URLSessionDataDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        streams.setStatus((response as? HTTPURLResponse)?.statusCode, for: dataTask.taskIdentifier)
        completionHandler(.allow)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let taskID = dataTask.taskIdentifier
        guard let lines = streams.receive(data, for: taskID) else { return }
        Task { @MainActor in
            guard self.task?.taskIdentifier == taskID else { return }
            self.handlers?.onText(lines)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let endDate = Date()
        let taskID = task.taskIdentifier
        let result = streams.finish(taskID)
        Task { @MainActor in
            guard self.task?.taskIdentifier == taskID, let handlers = self.handlers else { return }
            self.task = nil
            self.handlers = nil
            let completion = Completion(
                statusCode: result.statusCode, errorBody: result.errorBody, error: error,
                firstByteDate: result.firstByteDate, endDate: endDate
            )
            // A last line without a trailing newline.
            if !completion.isHTTPError, !result.rest.isEmpty { handlers.onText(result.rest) }
            handlers.onComplete(completion)
        }
    }
}

/// Per-request state for ChatTransport's streaming requests, written from the
/// URLSession delegate queue and read on the main actor -- lock-protected
/// and keyed by task identifier, so callbacks of a cancelled request can't
/// clobber the next one's.
private final class StreamStates: @unchecked Sendable {
    struct Result {
        var statusCode: Int?
        var errorBody = Data()
        var firstByteDate: Date?
        /// Bytes after the last newline, decoded (normally empty).
        var rest = ""
    }

    private struct State {
        var statusCode: Int?
        var errorBody = Data()
        var firstByteDate: Date?
        /// Undecoded bytes: a network chunk can end inside a UTF-8
        /// character, so only complete lines are decoded.
        var pending = Data()
    }

    private let lock = NSLock()
    private var states: [Int: State] = [:]

    func begin(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        states[id] = State()
    }

    func setStatus(_ code: Int?, for id: Int) {
        lock.lock(); defer { lock.unlock() }
        states[id]?.statusCode = code
    }

    /// The complete lines received so far (newline-terminated), or nil
    /// when there's nothing to parse yet (or the response is an error body).
    func receive(_ data: Data, for id: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard var state = states[id] else { return nil }
        defer { states[id] = state }
        if let code = state.statusCode, !(200..<300).contains(code) {
            state.errorBody.append(data)
            return nil
        }
        if state.firstByteDate == nil { state.firstByteDate = Date() }
        state.pending.append(data)
        // 0x0A never occurs inside a multi-byte UTF-8 sequence.
        guard let newline = state.pending.lastIndex(of: 0x0A) else { return nil }
        let end = state.pending.index(after: newline)
        let complete = state.pending[state.pending.startIndex..<end]
        let text = String(decoding: complete, as: UTF8.self)
        state.pending = Data(state.pending[end...])
        return text
    }

    func finish(_ id: Int) -> Result {
        lock.lock(); defer { lock.unlock() }
        guard let state = states.removeValue(forKey: id) else { return Result() }
        return Result(
            statusCode: state.statusCode, errorBody: state.errorBody,
            firstByteDate: state.firstByteDate, rest: String(decoding: state.pending, as: UTF8.self)
        )
    }
}
