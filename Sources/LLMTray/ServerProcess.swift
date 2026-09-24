import Foundation

/// One mlx_lm.server process: its output, its exit, and stopping it.
/// ServerManager owns the lifecycle around it; an old instance's late
/// callbacks are told apart from the current one's by identity.
@MainActor
final class ServerProcess {
    private let task = Process()
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var hasExited = false
    private(set) var terminationStatus: Int32 = 0

    /// Each chunk of the process's combined stdout/stderr.
    var onOutput: ((String) -> Void)?
    /// Called once, after the exit waiters are released.
    var onExit: ((ServerProcess) -> Void)?

    init(executable: String, arguments: [String]) {
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.onOutput?(text) }
        }
        task.terminationHandler = { proc in
            // Must be cleared here, the one place that runs no matter why
            // the process exited: left in place, the pipe's read end stays
            // "readable" at EOF forever and libdispatch re-invokes the
            // handler in a tight loop, pegging a CPU core (seen live:
            // LLMTray at 100% CPU with no server process left).
            handle.readabilityHandler = nil
            let status = proc.terminationStatus
            // Strong capture: the instance stays alive until its exit has
            // been handled.
            Task { @MainActor in self.didExit(status: status) }
        }
    }

    var isRunning: Bool { !hasExited && task.isRunning }

    func run() throws {
        do {
            try task.run()
        } catch {
            // Never ran, so didExit won't break the handler <-> self cycle.
            task.terminationHandler = nil
            (task.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    /// SIGTERM, then SIGKILL if it's still alive 3 s later -- mlx_lm.server
    /// doesn't always react to SIGTERM promptly while a generation is in
    /// flight. Only ever signals this process.
    func terminate() {
        guard isRunning else { return }
        task.terminate()
        let pid = task.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                kill(pid, SIGKILL)
            }
        }
    }

    /// SIGKILL right away -- the app is quitting, there's no time to wait.
    func killNow() {
        guard isRunning else { return }
        kill(task.processIdentifier, SIGKILL)
    }

    func waitForExit() async {
        guard !hasExited else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exitWaiters.append(continuation)
        }
    }

    private func didExit(status: Int32) {
        guard !hasExited else { return }
        hasExited = true
        terminationStatus = status
        task.terminationHandler = nil
        let waiters = exitWaiters
        exitWaiters = []
        waiters.forEach { $0.resume() }
        onExit?(self)
    }
}
