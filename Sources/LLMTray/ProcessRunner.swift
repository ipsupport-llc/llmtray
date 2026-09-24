import Foundation

/// Runs the helper processes the runtime installers need (venv creation,
/// pip) -- shared by the mlx-lm runtime, its updater and the image-generation
/// runtime, which used to carry three copies of this.
enum ProcessRunner {
    struct Failure: LocalizedError {
        let executable: String
        let status: Int32
        /// The last part of the process's output, for the error message.
        let outputTail: String

        var errorDescription: String? {
            let name = (executable as NSString).lastPathComponent
            return outputTail.isEmpty ? "\(name) exited \(status)" : "\(name) exited \(status): \(outputTail)"
        }
    }

    /// Runs `executable` to completion; throws `Failure` on a non-zero exit.
    /// Output is drained as it arrives -- a pipe nobody reads fills up at
    /// 64 KB and blocks the child forever (a chatty pip install did exactly
    /// that when output was only read after exit) -- passed to `log` when
    /// given, and its tail is kept for the error.
    static func run(
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

    /// Runs blocking file / process work on a background thread.
    static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
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
enum PythonLocator {
    static var commonLocations: [String] {
        [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            NSString(string: "~/.pyenv/shims/python3").expandingTildeInPath,
            "/opt/local/bin/python3",
            NSString(string: "~/miniconda3/bin/python3").expandingTildeInPath,
            NSString(string: "~/anaconda3/bin/python3").expandingTildeInPath,
        ]
    }

    /// The first modern Python among `preferred`, then the common locations.
    /// The version probes run off the main thread.
    static func findModern(preferring preferred: [String] = []) async -> String? {
        let candidates = (preferred + commonLocations).filter { FileManager.default.isExecutableFile(atPath: $0) }
        return try? await ProcessRunner.offMain { candidates.first(where: isModern) } ?? nil
    }

    /// Blocks until the probe exits -- call it off the main thread.
    static func isModern(_ path: String) -> Bool {
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
