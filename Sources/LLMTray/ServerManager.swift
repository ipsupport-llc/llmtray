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

    /// The current model process. Callbacks of an older one (still on its
    /// way out) are recognized by identity and don't touch state.
    private var process: ServerProcess?
    private lazy var proxy = ModelProxyServer(server: self)
    private lazy var installer = MLXRuntimeInstaller(log: { [weak self] in self?.appendLog($0) })

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

    // Resumed by checkForReadySignal (ready) or processDidExit (died while
    // starting) -- awaited by launchAndWaitReady, which only ever runs
    // inside a serialized transition, so there is at most one.
    private var startContinuation: CheckedContinuation<Void, Error>?
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

        // A downloaded .app has no venv at all (only run_server.sh's dev
        // flow created one before) -- someone who just dragged LLMTray.dmg
        // to Applications has no terminal-accessible path to run that
        // script anyway, so bootstrapping it here is the only way "download
        // and click Start Server" actually works end to end.
        let epoch = stopEpoch
        Task {
            do {
                try await serialized(epoch: epoch) {
                    // A transition queued ahead of this one may already have
                    // brought exactly this model up.
                    if case .running = self.state, self.currentModelPath == modelPath, self.currentPublicPort == port { return }
                    // Otherwise whatever it left running is replaced (waiting
                    // for it to exit on its own could wait forever).
                    await self.terminateAndWaitForExit()
                    try self.checkNotStopped(epoch)
                    // A listener left from a failed run may be on another
                    // port, forwarding to another internal port.
                    if let listening = self.proxy.publicPort, listening != port {
                        self.proxy.stop()
                    }
                    self.currentPublicPort = port
                    self.currentModelPath = modelPath
                    self.currentAlias = alias
                    self.state = .starting
                    try await self.installer.ensureReady()
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
            try self.checkAutoLoadAllowed()
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
        try checkAutoLoadAllowed()
        guard let modelPath = currentModelPath else { return }
        try await installer.ensureReady()
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

    /// Requests may bring the model (back) up only while it's running or
    /// idle-unloaded -- never after an explicit Stop (a connection accepted
    /// just before it, or an image generation that unloaded the model and
    /// reloads it afterwards) or a failure the user hasn't acted on.
    private func checkAutoLoadAllowed() throws {
        if case .running = state { return }
        guard isIdleUnloaded else {
            throw NSError(domain: "ServerManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "the server isn't running"])
        }
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
        if let old = process { await old.waitForExit() }
        try checkNotStopped(epoch)
        state = .starting
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            launchServerProcess(modelPath: modelPath, alias: alias)
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
              MLXRuntimeInstaller.supportsModelType("gemma4_assistant") else { return nil }
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

    private func launchServerProcess(modelPath: String, alias: String) {
        isIdleUnloaded = false
        lastActivityAt = Date()
        if idleStopTimer == nil { startIdleStopTimer() }
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

        let serverProcess = ServerProcess(executable: MLXRuntimeInstaller.venvPython, arguments: args)
        serverProcess.onOutput = { [weak self, weak serverProcess] text in
            guard let self else { return }
            self.appendLog(text)
            guard let serverProcess, self.process === serverProcess else { return }
            self.checkForReadySignal(text, modelPath: modelPath)
        }
        serverProcess.onExit = { [weak self] exited in
            self?.processDidExit(exited)
        }
        process = serverProcess
        do {
            try serverProcess.run()
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
    private func processDidExit(_ proc: ServerProcess) {
        // An older process dying after a newer one was launched: the state
        // and `process` belong to the new one now.
        guard proc === process else { return }
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
        process?.terminate()
    }

    /// Unlike stop(), waits for the old process to exit (the replacement
    /// needs the internal port) and keeps the public listener up.
    private func terminateAndWaitForExit() async {
        guard let process, process.isRunning else { return }
        process.terminate()
        await process.waitForExit()
    }

    /// For app-quit paths only (applicationWillTerminate): there's no time
    /// left to wait for a graceful SIGTERM, so signal SIGKILL directly and
    /// synchronously. The 3-second wait+SIGKILL-fallback in stop() is for
    /// the "user clicked Stop Server, app keeps running" case; this is for
    /// "the whole app is going away right now."
    func terminateImmediately() {
        proxy.stop()
        process?.killNow()
    }

    /// Lets a caller outside this type (AppDelegate's auto-start) surface
    /// a failure through the same .failed state the UI already knows how
    /// to display, for a failure that happens before there's even a
    /// process to launch (e.g. couldn't resolve which model to start).
    func reportFailure(_ message: String) {
        guard case .stopped = state else { return }
        state = .failed(message)
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
        let owner = process
        proxy.start(publicPort: publicPort, internalPort: internalPort) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                guard owner != nil, self.process === owner, self.proxyStartPending else { return }
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
        Task { await unloadModel(onlyIfIdle: true) }
    }

    /// Frees the model's memory but keeps the public listener, so the next
    /// request (in-app or external) reloads it -- idle-unload, and making
    /// room for image generation. The in-app chat stays usable. Queued like
    /// every transition, a no-op unless the model is running, and returns
    /// once the process has actually exited (its memory is free).
    func unloadModel(onlyIfIdle: Bool = false) async {
        let epoch = stopEpoch
        try? await serialized(epoch: epoch) {
            guard case .running = self.state else { return }
            // A request that arrived since the idle check is already
            // counted -- don't unload the model out from under it.
            guard !onlyIfIdle || self.activeRequestCount == 0 else { return }
            self.isIdleUnloaded = true
            self.state = .stopped
            await self.terminateAndWaitForExit()
        }
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

}
