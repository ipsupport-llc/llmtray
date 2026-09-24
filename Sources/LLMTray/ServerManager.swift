import Foundation
import LLMTrayCore
import Combine

enum ServerState: Equatable {
    case stopped
    case starting
    case running(port: Int, model: String)
    case failed(String)
}

@MainActor
final class ServerManager: ObservableObject {
    @Published private(set) var state: ServerState = .stopped {
        didSet { if state != oldValue { refreshPendingLaunchChange() } }
    }
    /// The running model's current profile (or the global verbose-logging
    /// setting) would launch it with different arguments than it's running
    /// with: shown as a "Restart Server" prompt, never applied on its own
    /// (a restart kills in-flight requests). Recomputed on state, profile
    /// and defaults changes -- not per render: it reads model files.
    @Published private(set) var pendingLaunchChange = false
    private var pendingLaunchObservers: [AnyCancellable] = []
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
    /// The model process was stopped by idle-unload but the proxy is still
    /// listening, so the next request (in-app or external) reloads it.
    /// The in-app chat stays usable in this state.
    @Published private(set) var isIdleUnloaded: Bool = false
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
    private var currentModelPath: String?
    /// Arguments the running process was started with, to tell whether
    /// profile edits since then need a restart (see pendingLaunchChange).
    private var lastLaunchArguments: [String]?
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

    // Resumed by checkForReadySignal (ready) or processDidExit (died while
    // starting) -- awaited by launchAndWaitReady, which only ever runs
    // inside a serialized transition, so there is at most one.
    private var startContinuation: CheckedContinuation<Void, Error>?
    /// Waiters for a specific process's exit (keyed by the Process), so a
    /// transition can wait for *its* old process without a later launch's
    /// exit being mistaken for it.
    private var exitWaiters: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]
    /// Bumped by every launch: callbacks of an older process compare it
    /// before touching state, so a slow-dying old process can't mark the
    /// new one stopped/failed or clear `process`.
    private var launchGeneration = 0
    /// Bumped by stop(): a transition queued before an explicit Stop must
    /// not bring the server back up after it.
    private var stopEpoch = 0
    /// Tail of the transition queue (start / switch / reload / restart):
    /// transitions run strictly one after another, never interleaved.
    private var transitionTail: Task<Void, Never>?
    /// Requests currently being served by the model process. A model switch
    /// or restart waits for these to finish instead of cutting them off.
    private var forwardingCount = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    /// The public listener is being started (between the model's "ready"
    /// line and the listener actually listening).
    private var proxyStartPending = false

    /// The model the server is (or was last) running -- the auto-tune
    /// sweep writes its results into this model's profile.
    var loadedModelPath: String? { currentModelPath }

    /// Launch settings (KV quantization, prefill, drafter...) come from the
    /// model's profile at every launch, see launchServerProcess -- so a
    /// proxy-driven model switch picks up the new model's own settings too.
    /// Also the way out of `.failed` (Play after an error).
    func start(modelPath: String, port: Int, alias: String) {
        switch state {
        case .stopped, .failed: break
        default: return
        }
        state = .starting
        isIdleUnloaded = false
        log = ""
        currentPublicPort = port
        currentModelPath = modelPath
        currentAlias = alias

        // A downloaded .app has no venv at all (only run_server.sh's dev
        // flow created one before) -- someone who just dragged LLMTray.dmg
        // to Applications has no terminal-accessible path to run that
        // script anyway, so bootstrapping it here is the only way "download
        // and click Start Server" actually works end to end.
        let epoch = stopEpoch
        Task {
            do {
                try await serialized(epoch: epoch) {
                    try await self.ensureRuntimeReady()
                    try self.checkNotStopped(epoch)
                    try await self.launchAndWaitReady(modelPath: modelPath, alias: alias, epoch: epoch)
                }
            } catch {
                // Only report the failure if the user hasn't already hit
                // Stop meanwhile -- clobbering .stopped back to .failed
                // would resurrect a state they already dismissed. Launch
                // failures set their own, more specific .failed.
                if case .starting = self.state {
                    self.state = .failed("runtime setup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Called by ModelProxyServer for every request before forwarding it:
    /// makes sure `modelPath` (nil = whatever was last loaded) is the one
    /// running -- switching models or reloading an idle-unloaded one as
    /// needed -- and counts the request as in flight on the process until
    /// its endRequest(). mlx_lm.server has no hot-swap, so a switch really
    /// stops the process and starts a fresh one; the public port stays up
    /// throughout since that's `proxy`, not this process. Transitions are
    /// serialized, and a switch first waits for requests still being served
    /// by the old model, so neither a concurrent switch nor someone else's
    /// generation gets cut off.
    func acquireModel(modelPath target: String?, alias: String) async throws {
        let epoch = stopEpoch
        try await serialized(epoch: epoch) {
            if let target, target != self.currentModelPath {
                await self.waitForForwardsToDrain()
                try self.checkNotStopped(epoch)
                await self.terminateAndWaitForExit()
                try self.checkNotStopped(epoch)
                self.currentModelPath = target
                self.currentAlias = alias
                try await self.launchAndWaitReady(modelPath: target, alias: alias, epoch: epoch)
            } else {
                try await self.loadIfNeeded(epoch: epoch)
            }
            self.forwardingCount += 1
        }
    }

    /// Reloads the last-used model if it isn't running (idle-unloaded, or
    /// stopped for image generation, see unloadModel). A no-op when it's
    /// already running.
    func ensureModelLoaded() async throws {
        let epoch = stopEpoch
        try await serialized(epoch: epoch) {
            try await self.loadIfNeeded(epoch: epoch)
        }
    }

    private func loadIfNeeded(epoch: Int) async throws {
        if case .running = state { return }
        guard let modelPath = currentModelPath else { return }
        try await ensureRuntimeReady()
        try checkNotStopped(epoch)
        try await launchAndWaitReady(modelPath: modelPath, alias: currentAlias, epoch: epoch)
    }

    /// Restarts the *same* model. Triggered by endRequestStalled() below
    /// after too many consecutive stalls: a mlx_lm.server worker thread can
    /// die (e.g. a METAL out-of-memory error) without taking the whole
    /// process down with it, since Python just prints a traceback and kills
    /// that one thread -- the process looks alive to
    /// Process.terminationHandler, but every request after that hangs
    /// forever, since nothing left is generating anything.
    private func restartWedgedProcess() async {
        let epoch = stopEpoch
        do {
            try await serialized(epoch: epoch) {
                guard case .running = self.state else { return }
                self.appendLog("--- restarting the model process after repeated stalls ---\n")
                try await self.restartSameModel(epoch: epoch)
            }
        } catch {
            if case .starting = state {
                state = .failed("auto-restart failed: \(error.localizedDescription)")
            }
        }
    }

    /// Restart-in-place to pick up changed launch settings (Restart banner,
    /// the benchmark's auto-tune sweep): they're only read at process launch
    /// (see launchServerProcess).
    func restartToApplyLaunchSettings() async throws {
        let epoch = stopEpoch
        try await serialized(epoch: epoch) {
            guard case .running = self.state else {
                throw NSError(domain: "ServerManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "server isn't running"])
            }
            try await self.restartSameModel(epoch: epoch)
        }
    }

    private func restartSameModel(epoch: Int) async throws {
        guard let modelPath = currentModelPath else { return }
        await waitForForwardsToDrain()
        try checkNotStopped(epoch)
        await terminateAndWaitForExit()
        try checkNotStopped(epoch)
        try await launchAndWaitReady(modelPath: modelPath, alias: currentAlias, epoch: epoch)
    }

    // MARK: - Transition plumbing

    /// Runs `body` after every previously queued transition has finished.
    /// Throws without running it if stop() was called since `epoch`.
    private func serialized(epoch: Int, _ body: @escaping @MainActor () async throws -> Void) async throws {
        let previous = transitionTail
        let task = Task { @MainActor in
            await previous?.value
            try self.checkNotStopped(epoch)
            try await body()
        }
        transitionTail = Task { @MainActor in _ = try? await task.value }
        try await task.value
    }

    private func checkNotStopped(_ epoch: Int) throws {
        guard epoch == stopEpoch else {
            throw NSError(domain: "ServerManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "the server was stopped"])
        }
    }

    /// Launches the model and returns once it answers (or throws if it
    /// dies first / can't be launched). A previous process still on its
    /// way out (Stop, idle-unload) is waited for first -- it holds the
    /// internal port.
    private func launchAndWaitReady(modelPath: String, alias: String, epoch: Int) async throws {
        if let old = process { await waitForExit(of: old) }
        try checkNotStopped(epoch)
        state = .starting
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            launchServerProcess(modelPath: modelPath, alias: alias)
        }
    }

    private func waitForExit(of process: Process) async {
        guard process.isRunning else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exitWaiters[ObjectIdentifier(process), default: []].append(continuation)
        }
    }

    private func waitForForwardsToDrain() async {
        guard forwardingCount > 0 else { return }
        appendLog("--- waiting for \(forwardingCount) in-flight request(s) to finish ---\n")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            drainWaiters.append(continuation)
        }
    }

    private func forwardEnded() {
        forwardingCount = max(0, forwardingCount - 1)
        guard forwardingCount == 0 else { return }
        let waiters = drainWaiters
        drainWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// `--draft-model` value for the model's MTP drafter (see
    /// ModelDiscovery.mtpDrafterRepo), or nil. Only when the installed
    /// mlx-lm actually has the drafter architecture: an older pinned
    /// runtime would fail to load it and the whole server start with it,
    /// so the setting simply has no effect until Check for Updates brings
    /// in a runtime that supports it. A --draft-model the user put in the
    /// extra arguments wins. mlx_lm.server loads the drafter from Hugging
    /// Face itself (~450MB, cached after the first start).
    private func mtpDrafterArgument(forModelPath modelPath: String, profile: ResolvedProfile) -> String? {
        let known = ModelDiscovery.mtpDrafterRepo(forModelPath: modelPath)
        let drafter = ServerLaunch.drafter(for: profile, available: availableDrafter(forModelPath: modelPath))
        if let drafter {
            appendLog("--- speculative decoding with MTP drafter \(drafter) ---\n")
        } else if known != nil, profile.mtpDrafter, !ServerLaunch.extraArgsSetDrafter(profile) {
            appendLog("--- MTP drafter available for this model, but the installed mlx-lm runtime doesn't support it yet (Check for Updates) ---\n")
        }
        return drafter
    }

    /// The drafter this model can actually use: one is known for it and the
    /// installed runtime has the architecture. An older pinned runtime
    /// would fail to load it and the whole server start with it.
    private func availableDrafter(forModelPath modelPath: String) -> String? {
        guard let repo = ModelDiscovery.mtpDrafterRepo(forModelPath: modelPath),
              runtimeSupportsModelType("gemma4_assistant") else { return nil }
        return repo
    }

    /// The model-specific facts the launch arguments depend on; drafterRepo
    /// is the drafter *available* to the model (see ServerLaunch.drafter).
    private func launchContext(modelPath: String, alias: String, drafterRepo: String?) -> ServerLaunch.Context {
        ServerLaunch.Context(
            modelPath: modelPath,
            internalPort: internalPort,
            alias: alias,
            disallowQuantizedKV: ModelDiscovery.disallowsQuantizedKV(forModelPath: modelPath),
            drafterRepo: drafterRepo,
            maxContext: ModelDiscovery.maxContextLength(forModelPath: modelPath),
            verboseLogging: UserDefaults.standard.bool(forKey: "llmtray.verboseServerLogging")
        )
    }

    init() {
        // Profile edits are debounced into files, but `profiles` changes at
        // once; the defaults cover the global verbose-logging switch.
        pendingLaunchObservers = [
            ProfileManager.shared.$profiles.dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshPendingLaunchChange() },
            ProfileManager.shared.$assignments.dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshPendingLaunchChange() },
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshPendingLaunchChange() },
        ]
    }

    private func refreshPendingLaunchChange() {
        let changed = computePendingLaunchChange()
        if changed != pendingLaunchChange { pendingLaunchChange = changed }
    }

    private func computePendingLaunchChange() -> Bool {
        guard case .running = state, let modelPath = currentModelPath, let last = lastLaunchArguments else { return false }
        let profile = ProfileManager.shared.resolved(for: modelPath)
        let planned = ServerLaunch.arguments(profile, launchContext(
            modelPath: modelPath, alias: currentAlias,
            drafterRepo: ServerLaunch.drafter(for: profile, available: availableDrafter(forModelPath: modelPath))
        ))
        return planned != last
    }

    /// Whether switching the loaded model from profile `a` to `b` would
    /// change its real launch arguments (so a restart is needed).
    func needsRestart(modelPath: String, from a: ResolvedProfile, to b: ResolvedProfile) -> Bool {
        ServerLaunch.needsRestart(from: a, to: b, context: launchContext(
            modelPath: modelPath, alias: currentAlias, drafterRepo: availableDrafter(forModelPath: modelPath)
        ))
    }

    private func runtimeSupportsModelType(_ modelType: String) -> Bool {
        let lib = venvDir + "/lib"
        guard let pythons = try? FileManager.default.contentsOfDirectory(atPath: lib) else { return false }
        return pythons.contains { py in
            FileManager.default.fileExists(atPath: "\(lib)/\(py)/site-packages/mlx_lm/models/\(modelType).py")
        }
    }

    private func launchServerProcess(modelPath: String, alias: String) {
        isIdleUnloaded = false
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
        // Everything launch-related comes from the model's profile (see
        // ProfileManager / LLMTrayCore.ServerLaunch), resolved fresh on
        // every launch: a model switch or the benchmark's auto-tune
        // restart picks up current values without a separate code path.
        // Notable defaults kept from before profiles:
        // - prompt cache capped (1 GiB): uncapped, a long session's
        //   cross-request KV cache grew until a later request's own
        //   allocation hit METAL "Insufficient Memory";
        // - KV quantization forced off for KV-shared models (Gemma 4
        //   E2B/E4B), which crash with quantized KV -- now also applied
        //   on proxy-driven model switches, which used to reuse the
        //   first start()'s KV bits.
        let profile = ProfileManager.shared.resolved(for: modelPath)
        appendLog("--- profile: \(profile.profileName) ---\n")
        let args = ServerLaunch.arguments(profile, launchContext(
            modelPath: modelPath, alias: alias,
            drafterRepo: mtpDrafterArgument(forModelPath: modelPath, profile: profile)
        ))
        lastLaunchArguments = args
        task.arguments = args
        task.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        self.stdoutPipe = pipe
        self.process = task

        launchGeneration += 1
        let generation = launchGeneration
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
                guard generation == self.launchGeneration else { return }
                self.checkForReadySignal(text, modelPath: modelPath)
            }
        }

        task.terminationHandler = { [weak self] proc in
            // Must clear this HERE, not in stop()/idleUnload() -- this
            // handler is the one place that fires no matter WHY the process
            // exited (explicit stop, idle-unload, a crash, a model switch's
            // replacement). Left in place, the pipe's read end stays
            // permanently "readable" once the write end (the dead process)
            // closes -- availableData returns empty at EOF forever, and
            // libdispatch re-invokes the handler as fast as it can instead
            // of ever blocking, pegging a CPU core indefinitely.
            handle.readabilityHandler = nil
            Task { @MainActor [weak self] in
                self?.processDidExit(proc, generation: generation)
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

    /// Requests still being served by this process end on their own: their
    /// upstream connection fails, and the proxy calls endRequest() for each
    /// -- the request counters belong to requests, not to the process.
    private func processDidExit(_ proc: Process, generation: Int) {
        let waiters = exitWaiters.removeValue(forKey: ObjectIdentifier(proc)) ?? []
        waiters.forEach { $0.resume() }
        // An older process dying after a newer one was launched: the state
        // and `process` belong to the new one now.
        guard generation == launchGeneration else { return }
        if case .running = state {
            state = .stopped
        } else if case .starting = state {
            let message = "server exited during startup (code \(proc.terminationStatus))"
            state = .failed(message)
        }
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: NSError(
                domain: "ServerManager", code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "server exited during startup (code \(proc.terminationStatus))"]
            ))
        }
        proxyStartPending = false
        process = nil
    }

    /// Stops the model process and the public listener. Fire-and-forget:
    /// the UI flips to "Stopped" at once; a Start right after waits for the
    /// old process to actually exit before launching (launchAndWaitReady).
    func stop() {
        stopEpoch += 1
        isIdleUnloaded = false
        proxy.stop()
        proxyStartPending = false
        state = .stopped
        guard let process, process.isRunning else { return }
        process.terminate()
        killIfStillRunning(process)
    }

    /// mlx_lm.server doesn't always react to SIGTERM promptly while a
    /// generation is in flight. Only ever signals this exact process: a
    /// replacement is never launched before it has exited.
    private func killIfStillRunning(_ processToKill: Process) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard processToKill.isRunning else { return }
            kill(processToKill.processIdentifier, SIGKILL)
        }
    }

    /// Unlike stop(), waits for the old process to exit (the replacement
    /// needs the internal port) and keeps the public listener up.
    private func terminateAndWaitForExit() async {
        guard let process, process.isRunning else { return }
        process.terminate()
        killIfStillRunning(process)
        await waitForExit(of: process)
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
    private func pythonCandidates() -> [String] {
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
        return candidates.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs blocking file / process work on a background thread.
    nonisolated private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
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

    /// Blocks until the probe exits -- call it off the main actor.
    nonisolated private static func isModernPython(_ path: String) -> Bool {
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
            // Hundreds of MB: copied off the main actor, the UI stays live.
            let (venvSource, venvTarget) = (bundledVenvDir, venvDir)
            try await Self.offMain { try FileManager.default.copyItem(atPath: venvSource, toPath: venvTarget) }
            if let bundledFramework = bundledFrameworkDir {
                let frameworkTarget = externalFrameworkDir
                if !FileManager.default.fileExists(atPath: frameworkTarget) {
                    try? await Self.offMain { try FileManager.default.copyItem(atPath: bundledFramework, toPath: frameworkTarget) }
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
            let candidates = pythonCandidates()
            let found = try await Self.offMain { candidates.first(where: Self.isModernPython) }
            guard let python = found else {
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
    ///
    /// User data in the same directory -- saved chats (`sessions`) and
    /// settings profiles (`profiles`) -- is kept: it's small, and losing it
    /// to "uninstall the runtime" would be a nasty surprise (profiles would
    /// be re-migrated from the stale pre-profiles settings).
    func removeExternalRuntime() {
        stop()
        let dir = RuntimePaths.externalRuntimeDir
        let keep: Set<String> = ["sessions", "profiles"]
        for item in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where !keep.contains(item) {
            try? FileManager.default.removeItem(atPath: dir + "/" + item)
        }
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

        guard !proxyStartPending else { return }
        let name = (modelPath as NSString).lastPathComponent
        let publicPort = currentPublicPort ?? 8765
        // A model switch / reload re-enters this same "ready" path while the
        // listener is already up from the first start() -- it must NOT be
        // rebound. Otherwise "Running" is only published once the listener
        // really listens: a taken public port is an error, not a Running
        // server nobody can reach.
        guard proxy.publicPort == nil else {
            markRunning(port: publicPort, model: name)
            return
        }
        proxyStartPending = true
        let generation = launchGeneration
        proxy.start(publicPort: publicPort, internalPort: internalPort) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                guard generation == self.launchGeneration, self.proxyStartPending else { return }
                self.proxyStartPending = false
                self.markRunning(port: publicPort, model: name)
            case .failure(let error):
                self.proxyFailed(port: publicPort, error: error)
            }
        }
    }

    private func markRunning(port: Int, model: String) {
        state = .running(port: port, model: model)
        startContinuation?.resume()
        startContinuation = nil
    }

    /// The public listener couldn't bind (port taken, invalid) or died
    /// later: nothing can reach the model, so the server is failed, not
    /// Running.
    private func proxyFailed(port: Int, error: Error) {
        let message = "couldn't listen on port \(port): \(error.localizedDescription)"
        appendLog("--- \(message) ---\n")
        let continuation = startContinuation
        startContinuation = nil
        stop()
        state = .failed(message)
        continuation?.resume(throwing: NSError(domain: "ServerManager", code: 6, userInfo: [NSLocalizedDescriptionKey: message]))
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
        unloadModel()
    }

    /// Frees the model's memory but keeps the public listener, so the next
    /// request (in-app or external) reloads it -- idle-unload, and making
    /// room for image generation. The in-app chat stays usable.
    func unloadModel() {
        isIdleUnloaded = true
        state = .stopped
        guard let process, process.isRunning else { return }
        process.terminate()
        killIfStillRunning(process)
    }

    /// Paired with beginRequest() above, for a request that completed
    /// (successfully or with a normal upstream error). `forwarded` is false
    /// for a request that never reached the model (its load failed), so it
    /// wasn't counted by acquireModel(). A forwarded one that finishes resets
    /// consecutiveStallCount: it proves the process is still doing real
    /// work, which is what should "forgive" an earlier isolated stall.
    func endRequest(forwarded: Bool = true) {
        activeRequestCount = max(0, activeRequestCount - 1)
        isBusy = activeRequestCount > 0
        guard forwarded else { return }
        consecutiveStallCount = 0
        forwardEnded()
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
        forwardEnded()
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
