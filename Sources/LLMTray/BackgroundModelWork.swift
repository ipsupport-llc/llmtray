import Foundation
import LLMTrayCore

/// The app's background requests to the loaded model (adr/0024): through
/// the proxy, marked so it lets them in only while nobody else is at the
/// model, never loads or switches a model for them, and cancels them for
/// the next request that comes. Callers try again later on a transient
/// outcome (busy, not loaded, preempted).
enum BackgroundModelWork {
    /// A chat completion of `messages` on the loaded model (`modelAlias`:
    /// its served name; nil: whatever is loaded), streamed and read whole.
    /// `fields` join the body (sampling, thinking off). Never throws: a
    /// cancelled task gets `.failed("cancelled")`.
    static func complete(port: Int, modelAlias: String?, messages: [[String: Any]], maxTokens: Int,
                         fields: [String: Any] = [:]) async -> BackgroundRequest.Outcome {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else { return .failed("bad port") }
        // Read the server's prompt cache, add nothing to it (fork #42): a
        // reading must not push a chat's cached prompt out.
        var body: [String: Any] = ["messages": messages, "stream": true, "max_tokens": maxTokens, "cache_store": false]
        if let modelAlias { body["model"] = modelAlias }
        body.merge(fields) { $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .failed("unencodable request") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppRequestToken.value, forHTTPHeaderField: AppRequestToken.header)
        request.setValue(BackgroundRequest.value, forHTTPHeaderField: BackgroundRequest.header)
        // The model may take long on a long prompt; the proxy's own stall
        // watchdog ends a stuck one.
        request.timeoutInterval = 30 * 60
        // Whether the answer had begun: a failure before it is the
        // request's (no server, a refusal); one after it is the proxy
        // cutting it off for a foreground request.
        var answering = false
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                var errorBody = Data()
                for try await byte in bytes {
                    errorBody.append(byte)
                    if errorBody.count > 64 * 1024 { break }
                }
                return BackgroundRequest.outcome(status: status, body: errorBody)
            }
            answering = true
            var stream = StreamedContent()
            for try await line in bytes.lines {
                stream.read(line: line)
                if stream.done { break }
            }
            // Cut off without its end: the proxy cancelled it for a
            // foreground request (or the server went away).
            guard stream.done || stream.finishReason != nil else { return .preempted }
            return .done(stream.text)
        } catch is CancellationError {
            return .failed("cancelled")
        } catch let error as URLError where error.code == .cancelled {
            return .failed("cancelled")
        } catch {
            return answering ? .preempted : .failed(error.localizedDescription)
        }
    }
}
