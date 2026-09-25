import Foundation

/// Runs the helper processes the runtime installers need (venv creation,
/// pip) -- shared by the mlx-lm runtime, its updater and the image-generation
/// runtime, which used to carry three copies of this.
public enum ProcessRunner {
    public struct Failure: LocalizedError {
        public let executable: String
        public let status: Int32
        /// The last part of the process's output, for the error message.
        public let outputTail: String

        public var errorDescription: String? {
            let name = (executable as NSString).lastPathComponent
            return outputTail.isEmpty ? "\(name) exited \(status)" : "\(name) exited \(status): \(outputTail)"
        }
    }

    /// Runs `executable` to completion; throws `Failure` on a non-zero exit.
    /// Output is drained as it arrives -- a pipe nobody reads fills up at
    /// 64 KB and blocks the child forever (a chatty pip install did exactly
    /// that when output was only read after exit) -- passed to `log` when
    /// given, and its tail is kept for the error.
    public static func run(
        _ executable: String, _ arguments: [String],
        log: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws {
        let tail = OutputTail()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = arguments
            task.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty else { return }
                tail.append(data)
                if let log, let text = String(data: data, encoding: .utf8) {
                    Task { @MainActor in log(text) }
                }
            }
            task.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                // Whatever is still in the pipe -- often pip's final
                // "ERROR: ..." line, the part the error message needs.
                if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    tail.append(rest)
                    if let log, let text = String(data: rest, encoding: .utf8) {
                        Task { @MainActor in log(text) }
                    }
                }
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: Failure(
                        executable: executable, status: proc.terminationStatus, outputTail: tail.text
                    ))
                }
            }
            do {
                try task.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Like run(), but hands each complete stdout line to `onLine`, in
    /// order, from a background thread -- for a child that reports through
    /// a line protocol. Returns once every line has been delivered and the
    /// process has exited. stderr is kept apart; its tail goes into the error.
    /// `stdin`: written to the child's standard input (e.g. a prompt kept out
    /// of the argument list, which `ps` shows); `environment`: added to it.
    /// Cancelling the calling task terminates the child.
    public static func runStreaming(
        _ executable: String, _ arguments: [String],
        stdin: Data? = nil, environment: [String: String]? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        let tail = OutputTail()
        let running = RunningProcess()
        try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = arguments
            if let environment { task.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
            let input = Pipe()
            task.standardInput = stdin == nil ? FileHandle.nullDevice : input
            let out = Pipe(), err = Pipe()
            task.standardOutput = out
            task.standardError = err
            err.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                if !data.isEmpty { tail.append(data) }
            }
            // Done = stdout at EOF (every line delivered) AND exited.
            let done = DispatchGroup()
            done.enter()
            done.enter()
            task.terminationHandler = { _ in done.leave() }
            do {
                try task.run()
            } catch {
                err.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
                return
            }
            running.set(task)
            if let stdin {
                // Written and closed off the reader threads. No SIGPIPE if
                // the child is already gone (Stop, a crash at import): that
                // signal would kill the whole app; the write just fails.
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                DispatchQueue.global().async {
                    try? input.fileHandleForWriting.write(contentsOf: stdin)
                    try? input.fileHandleForWriting.close()
                }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let lines = LineSplitter()
                let handle = out.fileHandleForReading
                while true {
                    let data = handle.availableData   // blocks; empty at EOF
                    if data.isEmpty { break }
                    lines.append(data).forEach(onLine)
                }
                lines.flush().map(onLine)   // a last line without a newline
                done.leave()
            }
            done.notify(queue: .global()) {
                err.fileHandleForReading.readabilityHandler = nil
                if let rest = try? err.fileHandleForReading.readToEnd() { tail.append(rest) }
                if task.terminationStatus == 0 {
                    continuation.resume()
                } else if running.wasCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: Failure(executable: executable, status: task.terminationStatus, outputTail: tail.text))
                }
            }
        }
        } onCancel: {
            running.cancel()   // the task's cancellation ends the child
        }
    }

    /// Runs blocking file / process work on a background thread.
    public static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}

/// Finds a Python 3.10+ to create a venv with.
///
/// GUI apps launched via Finder/LaunchServices don't inherit the
/// interactive shell PATH that adds a package manager's bin dir -- so a
/// plain "python3" (or hardcoded /usr/bin/python3) resolves to the ancient
/// Xcode Command Line Tools Python (3.9.6 here), whose pip can't find
/// wheels for a current `mlx` (needs 3.10+): venv creation silently
/// succeeds and the install inside it then fails with version-not-found.
///
/// Path presence alone isn't enough to trust, so each candidate's real
/// version is checked, covering Homebrew (both CPU architectures), pyenv,
/// MacPorts and Anaconda/Miniconda. Deliberately no /usr/bin/python3: on a
/// clean Mac without the Command Line Tools that's a stub that pops an
/// "Install Command Line Developer Tools" dialog the first time anything
/// runs it -- confusing from a background bootstrap step. nil instead lets
/// the caller fail with a clear, actionable message.
public enum PythonLocator {
    public static var commonLocations: [String] {
        // python.org's installers: /Library/Frameworks/Python.framework,
        // newest first (its /usr/local/bin links are optional).
        let versions = "/Library/Frameworks/Python.framework/Versions"
        let pythonOrg = ((try? FileManager.default.contentsOfDirectory(atPath: versions)) ?? [])
            .filter { $0.first?.isNumber == true }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(versions)/\($0)/bin/python3" }
        return [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            NSString(string: "~/.pyenv/shims/python3").expandingTildeInPath,
            "/opt/local/bin/python3",
            NSString(string: "~/miniconda3/bin/python3").expandingTildeInPath,
            NSString(string: "~/anaconda3/bin/python3").expandingTildeInPath,
        ] + pythonOrg
    }

    /// The first modern Python among `preferred`, then the common locations.
    /// The version probes run off the main thread.
    public static func findModern(preferring preferred: [String] = []) async -> String? {
        let candidates = (preferred + commonLocations).filter { FileManager.default.isExecutableFile(atPath: $0) }
        return try? await ProcessRunner.offMain { candidates.first(where: isModern) }
    }

    /// Blocks until the probe exits -- call it off the main thread.
    public static func isModern(_ path: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["-c", "import sys; exit(0 if sys.version_info >= (3, 10) else 1)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// The last few KB of a process's output, appended from the pipe's reader
/// thread and read from the termination handler.
private final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 2_000

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit * 2 { data = Data(data.suffix(limit)) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data.suffix(limit), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Splits a byte stream into complete lines (UTF-8), keeping a partial
/// last line for the next chunk. Thread-safe.
public final class LineSplitter: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private var pending = Data()
    /// Where the newline search resumes: pending[..<scanned] has none.
    private var scanned = 0

    /// What's left after the last newline, if anything (at EOF).
    public func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        defer { pending = Data(); scanned = 0 }
        return String(decoding: pending, as: UTF8.self)
    }

    public func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        var start = pending.startIndex
        var search = pending.startIndex + scanned
        while let newline = pending[search...].firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[start..<newline], as: UTF8.self))
            start = pending.index(after: newline)
            search = start
        }
        pending = Data(pending[start...])
        scanned = pending.count   // only new bytes are searched next time
        return lines
    }
}

/// The child of a runStreaming call, for cancellation from another thread.
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func set(_ p: Process) {
        lock.lock()
        process = p
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { p.terminate() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}
