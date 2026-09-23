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
    // True while at least one request is in flight -- driven directly by
    // ModelProxyServer's beginRequest()/endRequest() around every request it
    // forwards (and around a model switch, which can itself take tens of
    // seconds while the old process stops and the new one loads). Precise
    // by construction: the proxy already knows the exact start/end of every
    // request it handles, for every caller (this app's own chat UI and any
    // external OpenAI-API client alike, since both only ever reach
    // mlx_lm.server through the proxy's public port) -- no need to guess
    // from server log output, which used to require --log-level DEBUG
    // (dropped below) and a debounce timer to bridge gaps between lines,
    // and which never saw a model-switch as "busy" at all.
    @Published private(set) var isBusy: Bool = false
    private var activeRequestCount = 0

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stdoutHandle: FileHandle?
    private lazy var proxy = ModelProxyServer(server: self)

    // Last time a request actually started -- checked by the idle-stop
    // timer below (Advanced setting, 0 disables it). Only needs updating
    // in beginRequest(): checkIdleStop already skips while
    // activeRequestCount > 0, so a long-running request can never be
    // judged idle regardless of how stale this timestamp gets meanwhile.
    private var lastActivityAt = Date()
    private var idleStopTimer: Timer?

    // Remembered from the initial start() call so switchModel() (driven by
    // the proxy, not the UI) knows what port/KV settings to keep reusing
    // when a client's `model` field asks for something else.
    private var currentPublicPort: Int?
    private var currentKVBits: Int = 4
    private var currentKVGroupSize: Int = 64
    private var currentModelPath: String?
    private var currentAlias: String = ""

    // Consecutive endRequestStalled() calls with no successful endRequest()
    // in between -- reset to 0 by any request that actually completes.
    // Used by restartWedgedProcess() below: a single stall can be a
    // legitimately slow request timing out for an unrelated reason, but an
    // unbroken streak means the process itself is the problem.
    private var consecutiveStallCount = 0

    /// mlx_lm.server actually binds here, not to the port the user
    /// configured -- that public port is instead served by `proxy`, which
    /// is what makes switching models based on a request's `model` field
    /// possible at all (mlx_lm.server itself is a single-model process
    /// with no hot-swap; the public-facing port has to be something this
    /// app controls, not the model process itself).
    private var internalPort: Int { (currentPublicPort ?? 8765) + 10_000 }

    /// Lives outside the app bundle (see RuntimePaths.externalRuntimeDir) so
    /// it survives Sparkle replacing Contents/ wholesale on every
    /// auto-update. Talking to the binary directly (instead of shelling out
    /// through run_server.sh every launch) skips a `pip install mlx-lm`
    /// network round-trip and a re-check of both idempotent patch scripts on
    /// every single "Start Server" click -- work that only ever needs doing
    /// once, not once per app launch (or, prior to this, once per update).
    private var venvDir: String { RuntimePaths.externalRuntimeDir + "/mlx_server_venv" }
    private var venvPython: String { venvDir + "/bin/python3" }
    // Only ever used as an existence check (pip creates it as its last
    // install step, so its presence is a reliable "setup finished" signal)
    // -- never executed directly, see launchServerProcess's doc comment.
    private var venvServerBinary: String { venvDir + "/bin/mlx_lm.server" }
    private var versionMarkerPath: String { venvDir + "/.llmtray_pinned_version" }

    /// Only present in the "Full" build variant (scripts/build_full_app.sh),
    /// which vendors a working venv straight into the bundle so first launch
    /// never needs the network. Reused as the *source* for the one-time
    /// external copy above rather than a copy this app ever runs from
    /// directly -- Contents/ is exactly what the next Sparkle update wipes.
    private var bundledVenvDir: String { RuntimePaths.runtimeDir + "/.mlx_server_venv" }
    private var bundledVenvServerBinary: String { bundledVenvDir + "/bin/mlx_lm.server" }

    /// Also Full-build-only: the self-contained Python.framework
    /// build_full_app.sh vendored to create that venv in the first place.
    /// Copied out alongside the venv so that if the external venv is ever
    /// deleted (e.g. via the "Uninstall Runtime Data" menu item) and needs
    /// recreating on a machine with no system Python 3.10+, there's still a
    /// working interpreter to recreate it with -- without that, a Full
    /// install would silently degrade into needing a system Python anyway,
    /// defeating the point of "Full" in the first place.
    private var bundledFrameworkDir: String? {
        guard let frameworksPath = Bundle.main.privateFrameworksPath else { return nil }
        let path = frameworksPath + "/Python.framework"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
    private var externalFrameworkDir: String { RuntimePaths.externalRuntimeDir + "/Python.framework" }

    // Resumed by launchServerProcess's terminationHandler/checkForReadySignal
    // -- only switchModel() actually awaits these (see below); the public
    // start()/stop() keep their original fire-and-forget timing so the UI
    // still flips to "Stopped" immediately on click rather than waiting on
    // the process to actually exit.
    private var processExitContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Error>?

    func start(modelPath: String, port: Int, kvBits: Int, kvGroupSize: Int, alias: String) {
        guard case .stopped = state else { return }
        state = .starting
        log = ""
        currentPublicPort = port
        currentKVBits = kvBits
        currentKVGroupSize = kvGroupSize
        currentModelPath = modelPath
        currentAlias = alias

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
            self.launchServerProcess(modelPath: modelPath, alias: alias)
        }
    }

    /// Swaps the model backing mlx_lm.server without the caller having to
    /// re-specify port/KV settings -- driven by ModelProxyServer when a
    /// client's `model` field doesn't match what's currently loaded.
    /// mlx_lm.server has no hot-swap of its own, so this really does stop
    /// the whole process and start a fresh one; the public port stays up
    /// throughout since that's `proxy`, not this process.
    func switchModel(modelPath: String, alias: String) async throws {
        guard modelPath != currentModelPath else { return }
        await terminateAndWaitForExit()
        state = .starting
        currentModelPath = modelPath
        currentAlias = alias
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            launchServerProcess(modelPath: modelPath, alias: alias)
        }
    }

    /// Called by ModelProxyServer at the top of every request: if the
    /// model was idle-unloaded (see checkIdleStop/idleUnload below), the
    /// proxy's public port stayed up but nothing is actually running --
    /// this transparently reloads the last-used model before the request
    /// gets forwarded, instead of the caller just getting connection-refused.
    /// A no-op once something's already running. If another concurrent
    /// request already triggered the same reload, this waits on the
    /// existing one via the @Published state stream rather than racing a
    /// second launchServerProcess call.
    func ensureModelLoaded() async throws {
        if case .running = state { return }
        if case .stopped = state {
            guard let modelPath = currentModelPath else { return }
            state = .starting
            try await ensureRuntimeReady()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                startContinuation = continuation
                launchServerProcess(modelPath: modelPath, alias: currentAlias)
            }
            return
        }
        for await newState in $state.values {
            switch newState {
            case .running: return
            case .failed(let message):
                throw NSError(domain: "ServerManager", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
            case .stopped:
                throw NSError(domain: "ServerManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "stopped while reloading"])
            case .starting:
                continue
            }
        }
    }

    /// Restarts the *same* model -- deliberately not routed through
    /// switchModel(), which no-ops when modelPath is unchanged. Triggered
    /// by endRequestStalled() below after too many consecutive stalls: a
    /// mlx_lm.server worker thread can die (e.g. a METAL out-of-memory
    /// error) without taking the whole process down with it, since Python
    /// just prints a traceback and kills that one thread -- the process
    /// looks alive to Process.terminationHandler, but every request after
    /// that hangs forever, since nothing left is generating anything.
    private func restartWedgedProcess() async {
        guard case .running = state else { return }
        appendLog("--- restarting the model process after repeated stalls ---\n")
        do {
            try await restartSameModel()
        } catch {
            state = .failed("auto-restart failed: \(error.localizedDescription)")
        }
    }

    /// Public restart-in-place used by the benchmark tab's auto-tune sweep:
    /// decode-concurrency and prefill-step-size are only read at process
    /// launch (see launchServerProcess), so trying a new candidate value
    /// requires a real restart even though the model itself isn't changing
    /// -- switchModel() no-ops in that case since its guard is keyed on
    /// modelPath, not on launch args.
    func restartToApplyLaunchSettings() async throws {
        guard case .running = state else {
            throw NSError(domain: "ServerManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "server isn't running"])
        }
        try await restartSameModel()
    }

    private func restartSameModel() async throws {
        guard let modelPath = currentModelPath else { return }
        await terminateAndWaitForExit()
        state = .starting
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            launchServerProcess(modelPath: modelPath, alias: currentAlias)
        }
    }

    /// `--draft-model` value for the model's MTP drafter (see
    /// ModelDiscovery.mtpDrafterRepo), or nil. Only when the installed
    /// mlx-lm actually has the drafter architecture: an older pinned
    /// runtime would fail to load it and the whole server start with it,
    /// so the setting simply has no effect until Check for Updates brings
    /// in a runtime that supports it. A --draft-model the user put in the
    /// extra arguments wins. mlx_lm.server loads the drafter from Hugging
    /// Face itself (~450MB, cached after the first start).
    private func mtpDrafterArgument(forModelPath modelPath: String) -> String? {
        guard UserDefaults.standard.object(forKey: "llmtray.mtpDrafter") as? Bool ?? true else { return nil }
        guard let repo = ModelDiscovery.mtpDrafterRepo(forModelPath: modelPath) else { return nil }
        let extra = UserDefaults.standard.string(forKey: "llmtray.extraServerArgs") ?? ""
        if extra.contains("--draft-model") { return nil }
        guard runtimeSupportsModelType("gemma4_assistant") else {
            appendLog("--- MTP drafter available for this model, but the installed mlx-lm runtime doesn't support it yet (Check for Updates) ---\n")
            return nil
        }
        appendLog("--- speculative decoding with MTP drafter \(repo) ---\n")
        return repo
    }

    private func runtimeSupportsModelType(_ modelType: String) -> Bool {
        let lib = venvDir + "/lib"
        guard let pythons = try? FileManager.default.contentsOfDirectory(atPath: lib) else { return false }
        return pythons.contains { py in
            FileManager.default.fileExists(atPath: "\(lib)/\(py)/site-packages/mlx_lm/models/\(modelType).py")
        }
    }

    private func launchServerProcess(modelPath: String, alias: String) {
        lastActivityAt = Date()
        if idleStopTimer == nil { startIdleStopTimer() }
        let task = Process()
        // Not venvServerBinary (the "mlx_lm.server" console-script pip
        // generates) directly -- that script's first line is a shebang
        // hardcoding the exact absolute interpreter path that was live
        // when pip created it. For a Full build that's a GitHub Actions
        // runner path (/Users/runner/work/...) that exists nowhere else,
        // and even a *correct* path here would still break: shebangs don't
        // support spaces, and externalRuntimeDir lives under
        // "~/Library/Application Support/..." -- guaranteed to contain
        // one. Invoking the interpreter directly with -m sidesteps shebang
        // parsing entirely; Process doesn't go through a shell either way.
        task.executableURL = URL(fileURLWithPath: venvPython)
        // Without a cap, mlx_lm.server's cross-request prompt cache
        // (letting a conversation continue without re-prefilling the whole
        // history each turn) just keeps every conversation's KV state
        // around forever -- confirmed live: a long session's cache grew
        // from 0.27 GB to 1.25 GB before a subsequent request's own KV
        // allocation pushed the process into a METAL "Insufficient Memory"
        // crash. 1 GiB is a conservative default (Advanced setting) --
        // this evicts old cached conversations before they can pile up
        // into exactly that kind of failure, at the cost of occasionally
        // re-prefilling a conversation that's been idle a while (cheap
        // compared to a crash).
        let promptCacheMB = UserDefaults.standard.object(forKey: "llmtray.promptCacheMB") as? Int ?? 1024
        // Read fresh on every launch (not just once) so the benchmark tab's
        // auto-tune sweep can change this and pick it up via a plain
        // restartToApplyLaunchSettings() -- no separate code path needed.
        let prefillStepSize = UserDefaults.standard.object(forKey: "llmtray.prefillStepSize") as? Int ?? 128
        var args = [
            "-m", "mlx_lm.server",
            "--model", modelPath, "--port", String(internalPort), "--prefill-step-size", String(prefillStepSize),
            "--prompt-cache-bytes", String(promptCacheMB * 1_048_576),
        ]
        if currentKVBits > 0 {
            let quantizedKVStart = UserDefaults.standard.object(forKey: "llmtray.quantizedKVStart") as? Int ?? 0
            args += ["--kv-bits", String(currentKVBits), "--kv-group-size", String(currentKVGroupSize), "--quantized-kv-start", String(quantizedKVStart)]
        }
        let decodeConcurrency = UserDefaults.standard.object(forKey: "llmtray.decodeConcurrency") as? Int ?? 1
        if decodeConcurrency > 1 {
            args += ["--decode-concurrency", String(decodeConcurrency)]
        }
        if !alias.isEmpty {
            args += ["--model-alias", alias]
        }
        if let drafter = mtpDrafterArgument(forModelPath: modelPath) {
            args += ["--draft-model", drafter]
        }
        // Advanced setting: reintroduces the per-token DEBUG logging this
        // app itself stopped needing once isBusy moved to the proxy's own
        // request tracking (see ModelProxyServer) -- still useful as a
        // manual diagnostic toggle when troubleshooting the model process
        // itself, just no longer required for the app to function.
        if UserDefaults.standard.bool(forKey: "llmtray.verboseServerLogging") {
            args += ["--log-level", "DEBUG"]
        }
        // Advanced escape hatch for any mlx_lm.server flag this UI doesn't
        // expose (--draft-model, etc.) rather than building a dedicated
        // control for every one of them.
        let extraArgsRaw = UserDefaults.standard.string(forKey: "llmtray.extraServerArgs") ?? ""
        args += extraArgsRaw.split(separator: " ").map(String.init)
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
                self.checkForReadySignal(text, modelPath: modelPath)
            }
        }

        task.terminationHandler = { [weak self] proc in
            // Must clear this HERE, not in stop()/idleUnload() -- this
            // handler is the one place that fires no matter WHY the process
            // exited (explicit stop, idle-unload, a crash, switchModel's
            // replacement). Left in place, the pipe's read end stays
            // permanently "readable" once the write end (the dead process)
            // closes -- availableData returns empty at EOF forever, and
            // libdispatch re-invokes the handler as fast as it can instead
            // of ever blocking, pegging a CPU core indefinitely. Confirmed
            // live: LLMTray at 100% CPU with no mlx_lm.server process left
            // alive at all, RES a few MB, sampled straight into this
            // closure's availableData loop.
            handle.readabilityHandler = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .running = self.state {
                    self.state = .stopped
                } else if case .starting = self.state {
                    let error = NSError(
                        domain: "ServerManager", code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "server exited during startup (code \(proc.terminationStatus))"]
                    )
                    self.state = .failed(error.localizedDescription)
                    self.startContinuation?.resume(throwing: error)
                    self.startContinuation = nil
                }
                self.process = nil
                // Safety net: don't wait on the proxy's in-flight requests to
                // notice the process died and unwind naturally -- whatever
                // they were waiting on just went away, so there's nothing
                // left to be busy about right now regardless.
                self.activeRequestCount = 0
                self.isBusy = false
                self.processExitContinuation?.resume()
                self.processExitContinuation = nil
            }
        }

        do {
            try task.run()
        } catch {
            state = .failed("failed to launch: \(error.localizedDescription)")
            process = nil
            startContinuation?.resume(throwing: error)
            startContinuation = nil
        }
    }

    func stop() {
        guard let process, process.isRunning else {
            state = .stopped
            proxy.stop()
            return
        }
        let processToKill = process
        processToKill.terminate()
        // Give it a moment, then hard-kill if it's still alive -- mlx_lm.server
        // doesn't always react to SIGTERM promptly while a generation is in flight.
        // Must confirm self.process is STILL this exact instance before
        // sending SIGKILL: if a switchModel() (or another stop()+start())
        // already replaced it by the time this fires, self.process points
        // at a brand new, unrelated, already-running process -- confirmed
        // this exact bug once already (see terminateAndWaitForExit below).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.process === processToKill, processToKill.isRunning else { return }
            kill(processToKill.processIdentifier, SIGKILL)
        }
        state = .stopped
        proxy.stop()
    }

    /// Used only by switchModel(): unlike the public stop() above, this
    /// actually waits for the old process to exit before returning, since
    /// launching the replacement needs the internal port free first --
    /// stop() itself stays fire-and-forget so the UI flips to "Stopped"
    /// immediately on click rather than waiting on the OS.
    private func terminateAndWaitForExit() async {
        guard let process, process.isRunning else { return }
        let processToKill = process
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            processExitContinuation = continuation
            processToKill.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                // Reference-identity check against processToKill, not just
                // "is self.process currently running" -- by the time this
                // fires, switchModel() has very likely already installed a
                // freshly launched process in self.process, and the naive
                // check would SIGKILL that brand new process instead of
                // doing nothing. Root-caused via live trace: a model switch
                // killed the *new* model mid-generation (status 9) exactly
                // 3 seconds after the *old* model's graceful terminate().
                guard let self, self.process === processToKill, processToKill.isRunning else { return }
                kill(processToKill.processIdentifier, SIGKILL)
            }
        }
    }

    /// For app-quit paths only (applicationWillTerminate): there's no time
    /// left to wait for a graceful SIGTERM, so signal SIGKILL directly and
    /// synchronously. The 3-second wait+SIGKILL-fallback in stop() is for
    /// the "user clicked Stop Server, app keeps running" case; this is for
    /// "the whole app is going away right now."
    func terminateImmediately() {
        proxy.stop()
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    /// Lets a caller outside this type (AppDelegate's auto-start) surface
    /// a failure through the same .failed state the UI already knows how
    /// to display, for a failure that happens before there's even a
    /// process to launch (e.g. couldn't resolve which model to start).
    func reportFailure(_ message: String) {
        guard case .stopped = state else { return }
        state = .failed(message)
    }

    /// GUI apps launched via Finder/LaunchServices don't inherit the
    /// interactive shell PATH that adds a package manager's bin dir -- so a
    /// plain "python3" (or hardcoded /usr/bin/python3) resolves to the
    /// ancient Xcode Command Line Tools Python (3.9.6 here), whose pip
    /// can't find wheels for a current `mlx` (needs 3.10+), and the venv
    /// creation silently succeeds while the mlx-lm install inside it then
    /// fails with a version-not-found error.
    ///
    /// Path presence alone isn't enough to trust, though -- not everyone
    /// uses Homebrew (or the same install prefix), so this actually checks
    /// each candidate's real version and picks the first that's modern
    /// enough, covering Homebrew (both CPU architectures), pyenv, MacPorts,
    /// and Anaconda/Miniconda. Deliberately does NOT fall back to
    /// /usr/bin/python3 -- on a genuinely clean Mac with no Xcode Command
    /// Line Tools installed yet, that path is a stub that pops a system
    /// "Install Command Line Developer Tools" dialog the first time
    /// anything runs it, which is a confusing thing to trigger silently
    /// from a background bootstrap step. Returning nil here instead lets
    /// the caller fail with a clear, actionable message up front.
    private func findModernPython3() -> String? {
        var candidates = [String]()
        // A previously-externalized Full-build framework (see
        // externalFrameworkDir) takes priority: it's guaranteed modern and
        // needs no network, unlike everything else in this list.
        if let vendored = externalFrameworkPython() { candidates.append(vendored) }
        candidates += [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            NSString(string: "~/.pyenv/shims/python3").expandingTildeInPath,
            "/opt/local/bin/python3",
            NSString(string: "~/miniconda3/bin/python3").expandingTildeInPath,
            NSString(string: "~/anaconda3/bin/python3").expandingTildeInPath,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) && isModernPython($0) }
    }

    /// Version directory name (e.g. "3.14") isn't known ahead of time, so
    /// this just looks at whatever's actually there instead of hardcoding it.
    private func externalFrameworkPython() -> String? {
        let versionsDir = externalFrameworkDir + "/Versions"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: versionsDir) else { return nil }
        for version in versions where version != "Current" {
            let candidate = "\(versionsDir)/\(version)/bin/python\(version)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func isModernPython(_ path: String) -> Bool {
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

    /// A downloaded .app has no external venv yet on first launch -- this
    /// does the same setup runtime/run_server.sh does for local dev, in-
    /// process, so "download the DMG, click Start Server" works without
    /// ever opening a terminal. Also the one place that notices a new
    /// release bumped the pinned mlx-lm commit and upgrades the existing
    /// external venv in place, since -- now that the venv lives outside
    /// Contents/ specifically so updates *don't* wipe it -- nothing else
    /// would ever pick that up otherwise.
    // This app installs mlx_lm exclusively from our own fork,
    // ipsupport-llc/mlx-lm -- never from PyPI. That fork carries real
    // fixes/features upstream mlx_lm doesn't have (NemotronH Multi-Token-
    // Prediction self-speculative decode, RotatingKVCache quantization,
    // native prism_hadamard_qwen35 support, --model-alias/--kv-bits/
    // /api/v0/models/disconnect-safety server flags) -- see that repo's
    // docs/FINDINGS.md. Always a deliberately pinned commit on `main`
    // (runtime/mlx_lm_runtime.json), bumped only via Check for Updates --
    // there used to also be an Advanced toggle tracking the
    // `nemotron-h-mtp` branch tip directly, for picking up in-progress
    // work before it was merged to `main`, but that branch's own work is
    // long since merged and every fix since has landed on `main` directly,
    // so the toggle was just a second, easy-to-forget place a fix could
    // land without reaching this app -- removed rather than kept as a
    // permanent fixture with no active use.

    private func ensureRuntimeReady() async throws {
        let runtimeDir = RuntimePaths.runtimeDir
        guard let pinData = FileManager.default.contents(atPath: runtimeDir + "/mlx_lm_runtime.json"),
              let pinObj = try? JSONSerialization.jsonObject(with: pinData) as? [String: Any],
              let pinnedRepo = pinObj["repo"] as? String,
              let pinnedRef = pinObj["pinned_ref"] as? String else {
            throw NSError(
                domain: "ServerManager", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not read mlx_lm_runtime.json"]
            )
        }
        let pinnedRuntimeGitURL = "git+https://github.com/\(pinnedRepo).git@\(pinnedRef)"
        let targetVersion = pinnedRef

        // The marker is only ever written after a fully successful install
        // (see the two write sites below), so its presence -- not just the
        // venv directory's -- is what distinguishes "ready" or "just needs
        // a version bump" from "leftover half-built venv from a prior
        // crashed attempt."
        let installedVersion = try? String(contentsOfFile: versionMarkerPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if FileManager.default.fileExists(atPath: venvServerBinary), installedVersion == targetVersion {
            return
        }

        try FileManager.default.createDirectory(
            atPath: RuntimePaths.externalRuntimeDir, withIntermediateDirectories: true
        )

        // Full build, first launch: a working venv (for this exact pinned
        // commit, since both were produced by the same build_full_app.sh
        // run) is already sitting in the bundle -- copying it out is a fast
        // local operation with no network, unlike everything below.
        if !FileManager.default.fileExists(atPath: venvDir),
           FileManager.default.fileExists(atPath: bundledVenvServerBinary) {
            appendLog("--- first run: copying vendored runtime out of the app bundle ---\n")
            try FileManager.default.copyItem(atPath: bundledVenvDir, toPath: venvDir)
            if let bundledFramework = bundledFrameworkDir {
                if !FileManager.default.fileExists(atPath: externalFrameworkDir) {
                    try? FileManager.default.copyItem(atPath: bundledFramework, toPath: externalFrameworkDir)
                }
                // The copied venv's own bin/python3.X is a symlink pointing
                // at the *bundled* framework by absolute path (that's how
                // `python -m venv` created it in build_full_app.sh) -- valid
                // only as long as that original .app sticks around. Left
                // alone, it dangles the instant the next Sparkle update
                // replaces Contents/, which is exactly the update this
                // whole external-copy was supposed to survive. Repoint it at
                // the framework copy that now lives right alongside it.
                relinkVendoredInterpreter(newFrameworkDir: externalFrameworkDir)
            }
            try pinnedRef.write(toFile: versionMarkerPath, atomically: true, encoding: .utf8)
            appendLog("--- runtime ready ---\n")
            return
        }

        appendLog("--- first run: setting up mlx-lm runtime (this can take a minute) ---\n")

        if FileManager.default.fileExists(atPath: venvDir), installedVersion == nil {
            // No marker means the previous attempt at this exact venv never
            // finished (e.g. it was created with an incompatible Python and
            // the mlx-lm install inside it failed) -- venv creation is
            // cheap, so start clean rather than trying to patch up a
            // half-working one. A venv WITH a marker just needs the pip
            // install/patch steps below re-run against the new version, not
            // a full recreation.
            try? FileManager.default.removeItem(atPath: venvDir)
        }

        if !FileManager.default.fileExists(atPath: venvDir) {
            guard let python = findModernPython3() else {
                throw NSError(
                    domain: "ServerManager", code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "No Python 3.10+ found. Install one from python.org or via Homebrew (https://brew.sh), then try Start Server again."]
                )
            }
            try await runProcess(python, ["-m", "venv", venvDir])
            // -m pip, not the pip console-script directly -- same
            // shebang-can't-survive-relocation-or-spaces reasoning as
            // launchServerProcess above.
            try await runProcess(venvPython, ["-m", "pip", "install", "--quiet", "--upgrade", "pip"])
        }
        // --force-reinstall: pip won't otherwise treat a git URL as newer
        // than an already-satisfied "mlx-lm" (e.g. picking up a bumped pin).
        try await runProcess(venvPython, ["-m", "pip", "install", "--quiet", "--force-reinstall", pinnedRuntimeGitURL])
        try targetVersion.write(toFile: versionMarkerPath, atomically: true, encoding: .utf8)
        appendLog("--- runtime ready ---\n")
    }

    /// Confirmed live (copying a vendored venv out to a scratch directory,
    /// then simulating a Sparkle update by moving the original .app aside):
    /// without this, `venvDir/bin/python3.X` still resolves fine as long as
    /// the source .app happens to still be sitting where it was, then
    /// starts failing with a bare "no such file or directory" -- a broken
    /// symlink, not a Python-level error -- the moment it's gone.
    ///
    /// Matches by the stable "Python.framework/..." *suffix* of each
    /// symlink's target, not by prefix against this run's own
    /// bundledFrameworkDir -- confirmed live on a real release build: the
    /// venv's symlink was created by `python -m venv` on whatever machine
    /// originally ran build_full_app.sh (a GitHub Actions runner, for an
    /// actual release), which has nothing in common with wherever this
    /// copy of the app ends up installed. Prefix-matching against the
    /// *current* Bundle.main path silently matched nothing there, leaving
    /// the dead runner path in place. A broken absolute symlink pointing
    /// somewhere inside *any* Python.framework is unambiguous regardless
    /// of what machine's path precedes that suffix.
    private func relinkVendoredInterpreter(newFrameworkDir: String) {
        if let binEntries = try? FileManager.default.contentsOfDirectory(atPath: venvDir + "/bin") {
            for entry in binEntries {
                let path = venvDir + "/bin/" + entry
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
                      !FileManager.default.fileExists(atPath: target),
                      let range = target.range(of: "Python.framework/") else { continue }
                let newTarget = newFrameworkDir + "/" + target[range.upperBound...]
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: newTarget)
            }
        }
        // pyvenv.cfg's home/executable/command fields aren't what actually
        // gets executed (bin/python3.X above is), but leaving them pointing
        // at a now-deleted path would confuse any tooling that does read it.
        // Same suffix-based approach: a regex matching "<anything non-space>
        // ending in Python.framework/" rather than a known literal prefix.
        let cfgPath = venvDir + "/pyvenv.cfg"
        if let cfg = try? String(contentsOfFile: cfgPath, encoding: .utf8),
           let regex = try? NSRegularExpression(pattern: #"\S*Python\.framework/"#) {
            let fullRange = NSRange(cfg.startIndex..., in: cfg)
            let replacement = NSRegularExpression.escapedTemplate(for: newFrameworkDir + "/")
            let fixed = regex.stringByReplacingMatches(in: cfg, range: fullRange, withTemplate: replacement)
            try? fixed.write(toFile: cfgPath, atomically: true, encoding: .utf8)
        }
    }

    /// Backing the "Uninstall Runtime Data" menu item: removes the
    /// externalized venv (and, for Full installs, the copied Python
    /// framework) entirely. Deleting the app bundle itself never touches
    /// this directory (it lives outside Contents/ specifically so Sparkle
    /// updates don't wipe it) -- without an explicit way to clear it, it
    /// would just sit there forever after an uninstall.
    func removeExternalRuntime() {
        stop()
        try? FileManager.default.removeItem(atPath: RuntimePaths.externalRuntimeDir)
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

    // Not private: ModelProxyServer's stall watchdog also writes into this
    // same log (see ProxyForwardDelegate) so a stalled/reset request shows
    // up right alongside the server's own output instead of vanishing
    // silently.
    func appendLog(_ text: String) {
        log += text
        // Cap the retained log so a long-running server doesn't grow this unbounded.
        if log.count > 200_000 {
            log = String(log.suffix(150_000))
        }
    }

    private func checkForReadySignal(_ chunk: String, modelPath: String) {
        guard case .starting = state else { return }
        // mlx_lm.server prints a "Starting httpd at ..." line (via werkzeug/uvicorn)
        // once it's actually accepting connections -- that's the real "ready" signal,
        // not just "process launched" (model loading can take tens of seconds).
        guard chunk.contains("Starting httpd") || chunk.contains("Uvicorn running") || chunk.contains("http://") else { return }

        let name = (modelPath as NSString).lastPathComponent
        let publicPort = currentPublicPort ?? 8765
        state = .running(port: publicPort, model: name)
        // Idempotent: a model switch re-enters this same "ready" path, but
        // the proxy is already listening on the public port from the
        // first start() and must NOT be rebound.
        if proxy.publicPort == nil {
            try? proxy.start(publicPort: publicPort, internalPort: internalPort)
        }
        proxy.noteCurrentModel(modelPath)
        startContinuation?.resume()
        startContinuation = nil
    }

    /// Called by ModelProxyServer once per request it starts handling
    /// (including the model-switch stretch ahead of an actual forward, if
    /// one's needed) -- paired 1:1 with endRequest() below. A counter, not a
    /// bool, because multiple clients can have requests in flight at once;
    /// isBusy should only drop once the *last* one finishes.
    func beginRequest() {
        activeRequestCount += 1
        isBusy = true
        lastActivityAt = Date()
    }

    /// Started once, lazily, on the first launchServerProcess call --
    /// left running for the app's lifetime rather than torn down between
    /// starts/stops, since checkIdleStop's own guards (state == .running,
    /// activeRequestCount == 0) already make it a no-op whenever it
    /// doesn't apply.
    private func startIdleStopTimer() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkIdleStop()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleStopTimer = timer
    }

    /// Advanced setting, minutes of no requests before the model is
    /// unloaded on its own -- 0 (the default) disables it. Exists so
    /// leaving a big model loaded and forgotten doesn't just sit there
    /// holding memory/battery indefinitely.
    private func checkIdleStop() {
        guard case .running = state, activeRequestCount == 0 else { return }
        let minutes = UserDefaults.standard.object(forKey: "llmtray.autoStopIdleMinutes") as? Int ?? 0
        guard minutes > 0, Date().timeIntervalSince(lastActivityAt) >= TimeInterval(minutes * 60) else { return }
        appendLog("--- unloading model after \(minutes) min idle (reloads automatically on the next request) ---\n")
        idleUnload()
    }

    /// Kills the model process but, unlike stop(), leaves the proxy's
    /// public-port listener running -- mlx_lm.server has no "unload the
    /// model but stay alive" mode of its own, so actually freeing its
    /// memory means killing the process, but a caller hitting the public
    /// port a minute later should see it transparently reload (via
    /// ensureModelLoaded(), from ModelProxyServer.route()) rather than a
    /// bare connection-refused because the whole proxy went down too.
    /// currentModelPath/currentAlias are deliberately left set -- that's
    /// exactly what ensureModelLoaded() reloads.
    private func idleUnload() {
        guard let process, process.isRunning else {
            state = .stopped
            return
        }
        let processToKill = process
        processToKill.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.process === processToKill, processToKill.isRunning else { return }
            kill(processToKill.processIdentifier, SIGKILL)
        }
        state = .stopped
    }

    /// Paired with beginRequest() above, for a request that actually
    /// completed (successfully or with a normal upstream error) -- floors
    /// at 0 rather than going negative, since the process-death safety net
    /// in launchServerProcess's terminationHandler can zero activeRequestCount
    /// out before a request that was in flight at the time gets around to
    /// calling this on its own. Resets consecutiveStallCount: any request
    /// that actually finishes proves the process is still doing real work,
    /// which is what should "forgive" an earlier isolated stall.
    func endRequest() {
        activeRequestCount = max(0, activeRequestCount - 1)
        isBusy = activeRequestCount > 0
        consecutiveStallCount = 0
    }

    /// Paired with beginRequest() above, for the proxy's stall watchdog
    /// specifically (ProxyForwardDelegate.finish(stalled: true)) rather
    /// than a normal completion -- same busy-indicator bookkeeping as
    /// endRequest(), plus tracks how many of these have happened in a row
    /// with nothing succeeding in between. After enough of them, the
    /// process itself is almost certainly wedged (see restartWedgedProcess's
    /// doc comment), not just one slow request, and gets restarted.
    func endRequestStalled() {
        activeRequestCount = max(0, activeRequestCount - 1)
        isBusy = activeRequestCount > 0
        consecutiveStallCount += 1

        let threshold = UserDefaults.standard.object(forKey: "llmtray.autoRestartStallThreshold") as? Int ?? 3
        guard threshold > 0, consecutiveStallCount >= threshold else { return }
        consecutiveStallCount = 0
        Task { await restartWedgedProcess() }
    }

    deinit {
        stdoutHandle?.readabilityHandler = nil
        process?.terminate()
    }
}
