import Darwin
import Foundation
import LLMTrayCore

/// `llmtray chat`: one message to the OpenAI endpoint, the answer printed
/// as it streams. Through the API, not the socket: the profile's sampling
/// defaults are filled in there (adr/0005), as for any other client. With
/// the app's request token from `status`, so a model named with --model
/// switches as from the in-app chat -- no "Ask first" prompt for the
/// user's own terminal (adr/0019 §3).
struct ChatCommand {
    let options: CLICommand.ChatOptions

    func run() throws {
        let prompt = try readPrompt()
        var status = try LLMTrayCLI.statusNow()
        // Stopped or failed: started first, with the named model if any.
        // Running (or idle-unloaded, reloaded by the request itself), a
        // named model is switched to by the proxy.
        if !status.canAnswer {
            status = try LLMTrayCLI.start(options.model, quiet: !Output.stderrIsTerminal)
        }
        guard let url = URL(string: status.baseURL + "/chat/completions") else { throw CLIError("bad API address \(status.baseURL)") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // A long prompt's prefill sends nothing for a while.
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(status.appToken, forHTTPHeaderField: status.appTokenHeader)
        request.httpBody = try JSONSerialization.data(withJSONObject: options.requestBody(prompt: prompt))

        let stream = ChatStream(options: options)
        let session = URLSession(configuration: .ephemeral, delegate: stream, delegateQueue: nil)
        let task = session.dataTask(with: request)
        // Ctrl-C: the request is cancelled (the proxy stops the generation
        // when its client goes), then exit.
        Interrupt.onInterrupt(exits: false) {
            task.cancel()
        }
        task.resume()
        stream.done.wait()
        session.finishTasksAndInvalidate()
        if let error = stream.failure { throw CLIError(error) }
    }

    private func readPrompt() throws -> String {
        guard let fromStdin = options.readsStdin(stdinIsTerminal: isatty(STDIN_FILENO) != 0) else {
            throw CLIUsageError("chat: what to ask? e.g. llmtray chat \"Hello\" (or pipe the prompt in)", command: "chat")
        }
        let prompt = fromStdin
            ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            : options.prompt ?? ""
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIUsageError("chat: the prompt is empty", command: "chat")
        }
        return prompt
    }
}

/// The streamed response, decoded as it arrives (SSEDecoder, the chat's
/// own) and printed: the answer to stdout, the reasoning to stderr when
/// asked for -- so `llmtray chat ... > answer.txt` holds only the answer.
private final class ChatStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let options: CLICommand.ChatOptions
    let done = DispatchSemaphore(value: 0)
    private(set) var failure: String?
    private var decoder = SSEDecoder()
    private var statusCode = 200
    private var errorBody = Data()
    private var endsWithNewline = true
    private var inReasoning = false
    /// Bytes of a UTF-8 character split across two chunks.
    private var carry = Data()
    private let lock = NSLock()

    init(options: CLICommand.ChatOptions) {
        self.options = options
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard statusCode == 200 else {
            if errorBody.count < 65_536 { errorBody.append(data) }
            return
        }
        lock.lock()
        defer { lock.unlock() }
        carry.append(data)
        // Decoded up to the last newline: a chunk can end inside a UTF-8
        // character, but never inside one at a "\n" (no multi-byte
        // sequence contains that byte), and SSE is line-based anyway.
        guard let newline = carry.lastIndex(of: 0x0A) else { return }
        let complete = carry[carry.startIndex...newline]
        carry = Data(carry[carry.index(after: newline)...])
        handle(decoder.feed(String(decoding: complete, as: UTF8.self)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if !carry.isEmpty {
            handle(decoder.feed(String(decoding: carry, as: UTF8.self)))
            carry = Data()
        }
        handle(decoder.finish())
        lock.unlock()
        if let error {
            failure = (error as NSError).code == NSURLErrorCancelled ? nil : "the request failed: \(error.localizedDescription)"
        } else if statusCode != 200 {
            failure = CommandLineOutput.apiError(status: statusCode, body: errorBody)
        }
        finishLine()
        done.signal()
    }

    private func handle(_ events: [SSEEvent]) {
        for event in events {
            switch event {
            case .content(let text):
                if options.json { emit(["content": text]); continue }
                if inReasoning {
                    Output.err("")
                    inReasoning = false
                }
                Output.out(text, terminator: "")
                endsWithNewline = text.hasSuffix("\n")
            case .reasoning(let text):
                guard options.showThinking else { continue }
                if options.json { emit(["reasoning": text]); continue }
                inReasoning = true
                Output.err(text, terminator: "")
            case .usage(let completion, let prompt, _, _):
                if options.json { emit(["usage": ["completion_tokens": completion, "prompt_tokens": prompt as Any]]) }
            case .toolCall(_, let name, let arguments):
                if options.json { emit(["tool_call": ["name": name, "arguments": arguments]]) }
            case .image:
                break
            }
        }
    }

    private func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        Output.out(String(decoding: data, as: UTF8.self))
    }

    /// The answer ends on its own line (the shell prompt doesn't follow it).
    func finishLine() {
        if inReasoning { Output.err("") }
        if !options.json, !endsWithNewline { Output.out("") }
        endsWithNewline = true
        inReasoning = false
    }
}
