import Darwin
import Foundation

/// A long-running child spoken to over binary pipes both ways -- the Voice
/// Lab runner (adr/0016): audio frames stream in on stdin while the
/// model's frames stream out on stdout, for as long as the session lasts.
/// ProcessRunner's helpers write stdin once and read lines; this keeps
/// stdin open, writes from any thread without blocking it, and hands
/// stdout over in raw chunks (VoiceFrameDecoder reassembles them).
public final class DuplexProcess: @unchecked Sendable {
    public struct Exit: Equatable, Sendable {
        public var status: Int32
        /// Ended by a signal (a kill, a crash), not an exit.
        public var signaled: Bool
    }

    /// Writes queued and not yet taken by the pipe past this are refused
    /// (`write` returns false): a runner that stops reading must not grow
    /// the app's memory with audio it will never hear. 1 MB is ~30 s of
    /// 16 kHz int16.
    public let maxPendingBytes: Int

    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let writeQueue = DispatchQueue(label: "LLMTray.DuplexProcess.stdin")
    private let lock = NSLock()
    private var pendingBytes = 0
    private var stdinClosed = false
    private var closeRequested = false
    private var started = false

    public init(executable: String, arguments: [String], environment: [String: String]? = nil,
                maxPendingBytes: Int = 1 << 20) {
        self.maxPendingBytes = maxPendingBytes
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    /// Starts the child. `onStdout` / `onStderr` get each chunk as read, in
    /// order, on a reader thread of their own; `onExit` once, after the
    /// child has exited and stdout reached EOF (every chunk delivered).
    public func start(onStdout: @escaping @Sendable (Data) -> Void,
                      onStderr: @escaping @Sendable (Data) -> Void = { _ in },
                      onExit: @escaping @Sendable (Exit) -> Void) throws {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        // No SIGPIPE when the child is gone before a write: that signal
        // would take the whole app down; the write just fails.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let done = DispatchGroup()
        done.enter()
        done.enter()
        process.terminationHandler = { _ in done.leave() }
        try process.run()
        for (pipe, deliver, isStdout) in [(output, onStdout, true), (errors, onStderr, false)] {
            let thread = Thread {
                let handle = pipe.fileHandleForReading
                while true {
                    let data = handle.availableData   // blocks; empty at EOF
                    if data.isEmpty { break }
                    deliver(data)
                }
                if isStdout { done.leave() }
            }
            thread.name = isStdout ? "LLMTray duplex stdout" : "LLMTray duplex stderr"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        done.notify(queue: .global()) { [process] in
            onExit(Exit(status: process.terminationStatus, signaled: process.terminationReason == .uncaughtSignal))
        }
    }

    /// Queues `data` for the child's stdin; never blocks the caller (an
    /// audio thread). False when stdin is closed or `maxPendingBytes` would
    /// be exceeded -- the data is dropped.
    @discardableResult
    public func write(_ data: Data) -> Bool {
        lock.lock()
        guard started, !stdinClosed, pendingBytes + data.count <= maxPendingBytes else {
            lock.unlock()
            return false
        }
        pendingBytes += data.count
        lock.unlock()
        writeQueue.async { [self] in
            let ok = (try? input.fileHandleForWriting.write(contentsOf: data)) != nil
            lock.lock()
            pendingBytes -= data.count
            if !ok { stdinClosed = true }
            lock.unlock()
        }
        return true
    }

    /// Bytes queued for stdin that the pipe hasn't taken yet.
    public var queuedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingBytes
    }

    /// Closes stdin after what's queued: the child reads EOF.
    public func closeStdin() {
        lock.lock()
        let wasRequested = closeRequested
        closeRequested = true
        stdinClosed = true
        lock.unlock()
        guard !wasRequested else { return }
        writeQueue.async { [input] in try? input.fileHandleForWriting.close() }
    }

    /// SIGTERM.
    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// SIGKILL, for app quit: no time left to wait.
    public func kill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
}
