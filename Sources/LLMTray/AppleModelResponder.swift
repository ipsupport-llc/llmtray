import Foundation
import LLMTrayCore
import Network

/// Answers chat requests for Apple's on-device model from the proxy itself
/// (adr/0025): no process behind it, the framework in-process. One
/// generation at a time, in arrival order; a client that goes away cancels
/// its own; one that stops making progress for a minute is cancelled.
@MainActor
final class AppleModelResponder {
    static let shared = AppleModelResponder()

    /// No new text for this long: the generation is given up.
    static let stallSeconds: TimeInterval = 60

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// `body`: the request (already checked to be a JSON object).
    func serve(body: Data, connection: NWConnection, server: ServerManager) {
        guard let request = AppleChatWire.Request(body: body, contextSize: AppleSystemModel.contextSize) else {
            send(connection, status: "400 Bad Request", body: AppleChatWire.errorBody("a chat request needs messages"))
            return
        }
        server.beginRequest()
        let wire = AppleChatWire()
        let state = Progress()
        let generation = Task { @MainActor in
            await self.acquire()
            defer {
                self.release()
                server.endRequest(forwarded: false)
                state.done = true
            }
            guard !Task.isCancelled else {
                connection.cancel()
                return
            }
            state.last = Date()
            state.started = true
            do {
                if request.stream {
                    self.sendHead(connection)
                    state.headersSent = true
                    self.sendChunk(connection, AppleChatWire.event(wire.roleChunk()))
                    let result = try await AppleSystemModel.stream(messages: request.plainMessages, maxTokens: request.maxTokens,
                                                                   temperature: request.temperature) { text in
                        await MainActor.run {
                            state.last = Date()
                            self.sendChunk(connection, AppleChatWire.event(wire.textChunk(text)))
                        }
                    }
                    self.sendChunk(connection, AppleChatWire.event(wire.finishChunk()))
                    if request.includeUsage, let usage = result.usage {
                        self.sendChunk(connection, AppleChatWire.event(wire.usageChunk(usage)))
                    }
                    self.sendChunk(connection, AppleChatWire.done)
                    self.sendEnd(connection)
                } else {
                    let result = try await AppleSystemModel.stream(messages: request.plainMessages, maxTokens: request.maxTokens,
                                                                   temperature: request.temperature) { _ in
                        await MainActor.run { state.last = Date() }
                    }
                    self.send(connection, status: "200 OK", body: wire.completion(result.text, usage: result.usage))
                }
            } catch {
                let failure = (error as? AppleSystemModel.Failure) ?? AppleSystemModel.classify(error)
                let (status, code, message) = AppleChatWire.status(of: failure)
                if state.headersSent {
                    self.sendChunk(connection, AppleChatWire.event(AppleChatWire.errorChunk(message, code: code)))
                    self.sendChunk(connection, AppleChatWire.done)
                    self.sendEnd(connection)
                } else {
                    self.send(connection, status: status, body: AppleChatWire.errorBody(message))
                }
            }
        }
        // The client gone: its generation stops (a pending receive is how
        // NWConnection notices the peer closing).
        watchClose(connection) { generation.cancel() }
        // Stalled: no new text for a minute (waiting its turn doesn't count).
        Task { @MainActor in
            while !state.done {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !state.done, state.started, Date().timeIntervalSince(state.last) > Self.stallSeconds {
                    generation.cancel()
                    return
                }
            }
        }
    }

    /// One request's progress, shared by its generation and its watchdog.
    private final class Progress {
        var last = Date()
        var started = false
        var headersSent = false
        var done = false
    }

    private func watchClose(_ connection: NWConnection, onClose: @escaping @MainActor () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                if isComplete || error != nil {
                    onClose()
                } else if data != nil {
                    self?.watchClose(connection, onClose: onClose)
                }
            }
        }
    }

    private func send(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendHead(_ connection: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    private func sendChunk(_ connection: NWConnection, _ text: String) {
        let data = Data(text.utf8)
        var chunk = Data(String(format: "%x\r\n", data.count).utf8)
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        connection.send(content: chunk, completion: .contentProcessed { _ in })
    }

    private func sendEnd(_ connection: NWConnection) {
        connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
