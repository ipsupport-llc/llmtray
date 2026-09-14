import Foundation
import Combine

enum ServerState: Equatable {
    case stopped
    case starting
    case running(port: Int, model: String)
    case failed(String)
}

@MainActor
final class ServerManager: ObservableObject {
    @Published private(set) var state: ServerState = .stopped
    @Published private(set) var log: String = ""
    // True while the server is actively producing output -- deliberately
    // independent of ChatClient.isStreaming, which only knows about
    // requests made through this app's own chat UI. An external tool
    // hitting the OpenAI-compatible endpoint directly never touches
    // ChatClient, but --log-level DEBUG (set below) makes the server print
    // a line per generated token for every caller, so watching its own log
    // -- which this app is already capturing -- covers everyone without
    // needing to poll anything.
    @Published private(set) var isBusy: Bool = false
    // Debounce window: isBusy flips true the instant a log line arrives and
    // back to false once this long has passed with no further lines --
    // long enough to bridge the gap between two DEBUG lines during normal
    // decoding, short enough that it drops promptly once generation stops.
    private static let quietWindow: TimeInterval = 0.6

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stdoutHandle: FileHandle?
    private var quietTimer: Timer?

    /// The venv runtime/run_server.sh creates and patches on its first run.
    /// Talking to the binary directly (instead of shelling out through
    /// run_server.sh every launch) skips a `pip install mlx-lm` network
    /// round-trip and a re-check of both idempotent patch scripts on every
    /// single "Start Server" click -- work that only ever needs doing once,
    /// not once per app launch.
    private var venvDir: String { RuntimePaths.runtimeDir + "/.mlx_server_venv" }
    private var venvServerBinary: String { venvDir + "/bin/mlx_lm.server" }

    func start(modelPath: String, port: Int, kvBits: Int, kvGroupSize: Int, alias: String) {
        guard case .stopped = state else { return }
        state = .starting
        log = ""

        // A downloaded .app has no venv at all (only run_server.sh's dev
        // flow created one before) -- someone who just dragged LLMTray.dmg
        // to Applications has no terminal-accessible path to run that
        // script anyway, so bootstrapping it here is the only way "download
        // and click Start Server" actually works end to end.
        Task {
            do {
                try await ensureRuntimeReady()
            } catch {
                // Only report the failure if the user hasn't already hit
                // Stop mid-bootstrap -- state would be .stopped in that
                // case, and clobbering it back to .failed would resurrect
                // a state they already dismissed.
                if case .starting = self.state {
                    self.state = .failed("runtime setup failed: \(error.localizedDescription)")
                }
                return
            }
            guard case .starting = self.state else { return }
            self.launchServerProcess(modelPath: modelPath, port: port, kvBits: kvBits, kvGroupSize: kvGroupSize, alias: alias)
        }
    }

    private func launchServerProcess(modelPath: String, port: Int, kvBits: Int, kvGroupSize: Int, alias: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: venvServerBinary)
        var args = [
            "--model", modelPath, "--port", String(port), "--prefill-step-size", "128",
            // DEBUG is what makes the server log per-token during decoding
            // (default INFO only logs around request start/prompt prefill,
            // silent through the actual generation) -- needed for isBusy's
            // log-activity signal to track a request all the way through
            // instead of just its first moment.
            "--log-level", "DEBUG",
        ]
        if kvBits > 0 {
            args += ["--kv-bits", String(kvBits), "--kv-group-size", String(kvGroupSize), "--quantized-kv-start", "0"]
        }
        if !alias.isEmpty {
            args += ["--model-alias", alias]
        }
        task.arguments = args
        task.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        self.stdoutPipe = pipe
        self.process = task

        let handle = pipe.fileHandleForReading
        self.stdoutHandle = handle
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            // The weak capture must be re-checked *inside* the Task's own
            // closure, not hoisted from the outer one -- strict concurrency
            // checking (on newer toolchains than what this was written
            // against) treats a weak `self` threaded into a concurrently-
            // scheduled closure from outside as an unchecked data race.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appendLog(text)
                self.checkForReadySignal(text, port: port, modelPath: modelPath)
                self.markActivity()
            }
        }

        task.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .running = self.state {
                    self.state = .stopped
                } else if case .starting = self.state {
                    self.state = .failed("server exited during startup (code \(proc.terminationStatus))")
                }
                self.process = nil
                self.quietTimer?.invalidate()
                self.quietTimer = nil
                self.isBusy = false
            }
        }

        do {
            try task.run()
        } catch {
            state = .failed("failed to launch: \(error.localizedDescription)")
            process = nil
        }
    }

    func stop() {
        guard let process, process.isRunning else {
            state = .stopped
            return
        }
        process.terminate()
        // Give it a moment, then hard-kill if it's still alive -- mlx_lm.server
        // doesn't always react to SIGTERM promptly while a generation is in flight.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let p = self.process, p.isRunning else { return }
            kill(p.processIdentifier, SIGKILL)
        }
        state = .stopped
    }

    /// For app-quit paths only (applicationWillTerminate): there's no time
    /// left to wait for a graceful SIGTERM, so signal SIGKILL directly and
    /// synchronously. The 3-second wait+SIGKILL-fallback in stop() is for
    /// the "user clicked Stop Server, app keeps running" case; this is for
    /// "the whole app is going away right now."
    func terminateImmediately() {
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    /// A downloaded .app has no venv (that only ever got created by
    /// manually running runtime/run_server.sh) -- this does the same setup
    /// run_server.sh does, in-process, so "download the DMG, click Start
    /// Server" works without ever opening a terminal. No-ops instantly if
    /// the venv's already there (the normal case after the first run).
    private func ensureRuntimeReady() async throws {
        guard !FileManager.default.fileExists(atPath: venvServerBinary) else { return }

        appendLog("--- first run: setting up mlx-lm runtime (this can take a minute) ---\n")
        let runtimeDir = RuntimePaths.runtimeDir

        if !FileManager.default.fileExists(atPath: venvDir) {
            try await runProcess("/usr/bin/python3", ["-m", "venv", venvDir])
        }
        try await runProcess(venvDir + "/bin/pip", ["install", "--quiet", "--upgrade", "pip"])

        guard let pinData = FileManager.default.contents(atPath: runtimeDir + "/mlx_lm_runtime.json"),
              let pinObj = try? JSONSerialization.jsonObject(with: pinData) as? [String: Any],
              let version = pinObj["pinned_version"] as? String else {
            throw NSError(
                domain: "ServerManager", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not read mlx_lm_runtime.json"]
            )
        }
        try await runProcess(venvDir + "/bin/pip", ["install", "--quiet", "mlx-lm==\(version)"])
        try await runProcess(venvDir + "/bin/python", [runtimeDir + "/patch_mlx_server_kv.py"])
        try await runProcess(venvDir + "/bin/python", [runtimeDir + "/patch_mlx_tool_parser.py"])
        appendLog("--- runtime ready ---\n")
    }

    /// Runs one setup step to completion, streaming its output into the
    /// same log the server's own output goes to -- so a slow first run
    /// (venv creation, pip install) is visible progress, not a silently
    /// stuck spinner.
    private func runProcess(_ executable: String, _ arguments: [String]) async throws {
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
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    self.appendLog(text)
                }
            }
            task.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "ServerManager", code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "\(executable) exited \(proc.terminationStatus)"]
                    ))
                }
            }
            do {
                try task.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func appendLog(_ text: String) {
        log += text
        // Cap the retained log so a long-running server doesn't grow this unbounded.
        if log.count > 200_000 {
            log = String(log.suffix(150_000))
        }
    }

    private func checkForReadySignal(_ chunk: String, port: Int, modelPath: String) {
        guard case .starting = state else { return }
        // mlx_lm.server prints a "Starting httpd at ..." line (via werkzeug/uvicorn)
        // once it's actually accepting connections -- that's the real "ready" signal,
        // not just "process launched" (model loading can take tens of seconds).
        if chunk.contains("Starting httpd") || chunk.contains("Uvicorn running") || chunk.contains("http://") {
            let name = (modelPath as NSString).lastPathComponent
            state = .running(port: port, model: name)
        }
    }

    /// Called on every chunk of server output, regardless of what it says --
    /// with --log-level DEBUG, a per-token line arrives throughout decoding
    /// for any caller, so "a line just arrived" is itself the busy signal.
    private func markActivity() {
        isBusy = true
        quietTimer?.invalidate()
        let timer = Timer(timeInterval: Self.quietWindow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isBusy = false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        quietTimer = timer
    }

    deinit {
        stdoutHandle?.readabilityHandler = nil
        quietTimer?.invalidate()
        process?.terminate()
    }
}
