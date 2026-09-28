import AVFoundation
import AppKit
import Foundation
import LLMTrayCore

/// One Voice Lab conversation (adr/0016, mode 1): the runner
/// (runtime/llmtray_voice_runner.py, in the audio venv) with the voice
/// model, the microphone streaming to it, its speech played as it comes.
/// Full duplex: the mic stays open while the model talks -- it decides when
/// to speak and when to yield.
///
/// While it runs it holds the app-wide generator queue (an image or a song
/// waits its turn, the project indexer pauses) and the chat model is
/// unloaded the way image generation unloads it, reloaded after.
@MainActor
final class VoiceLabSession: ObservableObject {
    static let shared = VoiceLabSession()

    enum Phase: Equatable {
        case idle
        /// Before the model is ready: waiting for a generator, unloading the
        /// chat model, loading the voice model.
        case preparing(String)
        case running
        case stopping
        case failed(String)
        /// The microphone permission was refused.
        case microphoneDenied
    }

    @Published private(set) var phase: Phase = .idle
    /// What was said, a paragraph per turn: the user's words (the model's
    /// own transcript of them) and the model's text channel, as they stream.
    @Published private(set) var transcript = ""
    /// Of a walkie-talkie reply made so far (before it starts playing).
    @Published private(set) var replyReadySeconds: Double = 0
    /// The microphone, 0...1.
    @Published private(set) var level: Float = 0
    @Published private(set) var isSpeaking = false
    @Published private(set) var startedAt: Date?
    /// The runner's log lines and stderr (capped), for the window's Log.
    @Published private(set) var log = ""
    /// Talk, then listen (VoiceLabMode): the mic is sent only while the
    /// user talks, the reply plays once the model has made all of it.
    @Published private(set) var isWalkieTalkie = false
    /// Where walkie-talkie is in its turns.
    @Published private(set) var turn: Turn = .waiting
    /// "This Mac runs the model at ~0.5× real time…", when automatic mode
    /// picked walkie-talkie for that reason.
    @Published private(set) var speedNotice: String?
    /// About the last reply or the conversation, when there's something to
    /// say (no answer, cut short, the context started over).
    @Published private(set) var replyNote: String?

    enum Turn: Equatable {
        /// For the user to press Talk (or the reply is playing).
        case waiting
        case talking
        /// The model is making its reply.
        case thinking
    }

    private weak var server: ServerManager?
    private var process: DuplexProcess?
    private var mic: MicrophoneCapture?
    private var player: SpeechPlayer?
    private var ticket: GenerationQueue.Ticket?
    private var reloadChatModel = false
    private var suspended = false
    private var stopRequested = false
    /// Bumped per start: a late callback from an earlier run is ignored.
    private var generation = 0
    private var lastError: String?
    private var meterTimer: Timer?
    private let meter = LevelBox()
    private let gate = MicGate()
    private var router: SpeechRouter?
    private var ready: VoiceRunnerReady?
    /// The walkie-talkie turn a `D` was sent for; its `Z` must match.
    private var turnNumber = 0
    private var transcriptTurns = VoiceTranscript(userLabel: NSLocalizedString("You:", comment: "Voice Lab transcript"),
                                                  modelLabel: NSLocalizedString("Model:", comment: "Voice Lab transcript"))

    /// Walkie-talkie holds this much of a reply before playing it: the model
    /// makes it slower than it plays, so it starts with a lead.
    static let replyPrebufferMilliseconds = 3000
    static let duplexPrebufferMilliseconds = 160

    /// A session is starting, running or stopping (Settings won't remove the model meanwhile).
    var isActive: Bool {
        switch phase {
        case .preparing, .running, .stopping: return true
        default: return false
        }
    }

    func attach(server: ServerManager) {
        self.server = server
    }

    // MARK: Start

    /// Voice Lab is on and its model downloaded: Start can work.
    func canStart(model: VoiceLabModel = .default) -> Bool {
        VoiceModelStore.shared.isEnabled && VoiceModelStore.shared.isDownloaded(model)
    }

    func start(model: VoiceLabModel = .default) {
        guard !isActive, canStart(model: model) else { return }
        generation += 1
        let run = generation
        stopRequested = false
        lastError = nil
        transcript = ""
        transcriptTurns = VoiceTranscript(userLabel: NSLocalizedString("You:", comment: "Voice Lab transcript"),
                                          modelLabel: NSLocalizedString("Model:", comment: "Voice Lab transcript"))
        replyReadySeconds = 0
        log = ""
        speedNotice = nil
        replyNote = nil
        turn = .waiting
        isWalkieTalkie = false
        ready = nil
        phase = .preparing(NSLocalizedString("Starting…", comment: "Voice Lab"))
        Task { await self.prepare(model: model, run: run) }
    }

    private func prepare(model: VoiceLabModel, run: Int) async {
        // The bare dev binary has no Info.plist: macOS ends a process that
        // opens the microphone without its usage description.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            return fail(NSLocalizedString("The microphone needs the LLMTray app bundle (scripts/build_app.sh), not the bare binary.", comment: ""), run: run)
        }
        guard VoiceModelStore.shared.isDownloaded(model) else {
            return fail(NSLocalizedString("The voice model isn't downloaded -- download it in Settings > Voice.", comment: ""), run: run)
        }
        guard await Self.microphoneAllowed() else {
            if run == generation { phase = .microphoneDenied }
            return
        }
        // The generator queue: an image or a song first, then the Lab.
        do {
            ticket = try await GenerationQueue.shared.acquire(
                isCancelled: { [weak self] in self?.stopRequested ?? true || self?.generation != run },
                onPosition: { [weak self] ahead in
                    guard let self, let ahead, ahead > 0 else { return }
                    self.phase = .preparing(NSLocalizedString("Waiting for an image or song to finish…", comment: "Voice Lab"))
                }
            )
        } catch {
            return finish(run: run)
        }
        // A Settings download of an image or music model holds a generator too.
        while ChatTabs.shared.mflux.isBusy || ChatTabs.shared.music.isBusy, !stopRequested {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !stopRequested, run == generation else { return finish(run: run) }
        // Requirements changed since the download (an update): installed now.
        do {
            try await AudioRuntime.shared.ensureInstalled { [weak self] text in
                if !text.isEmpty, self?.generation == run { self?.phase = .preparing(text) }
            }
        } catch {
            return fail(error.localizedDescription, run: run)
        }
        guard !stopRequested, run == generation else { return finish(run: run) }
        if let server {
            phase = .preparing(NSLocalizedString("Unloading the chat model…", comment: "Voice Lab"))
            do {
                reloadChatModel = try await server.suspendForVoice()
                suspended = true
            } catch {
                return fail(error.localizedDescription, run: run)
            }
        }
        guard !stopRequested, run == generation else { return finish(run: run) }
        phase = .preparing(NSLocalizedString("Loading the voice model…", comment: "Voice Lab"))
        launchRunner(model: model, run: run)
    }

    /// Asked the first time, not at launch (adr/0016).
    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func launchRunner(model: VoiceLabModel, run: Int) {
        let child = DuplexProcess(executable: AudioRuntime.venvPython, arguments: [
            RuntimePaths.runtimeDir + "/llmtray_voice_runner.py",
            "--model", VoiceModelStore.modelDir(model),
        ], environment: [
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONUNBUFFERED": "1",
            "HF_HUB_OFFLINE": "1",
            "TOKENIZERS_PARALLELISM": "false",
            OrphanScan.voiceRunnerMarker: "1",
        ])
        let decoder = FrameReader()
        let router = SpeechRouter()
        self.router = router
        do {
            try child.start(onStdout: { [weak self] data in
                let frames: [VoiceFrame]
                do {
                    frames = try decoder.append(data)
                } catch {
                    onMain { self?.runnerFailed(String(describing: error), run: run) }
                    return
                }
                for frame in frames {
                    // Speech goes straight to the player (or a reply's
                    // buffer), not through the main actor: nothing between
                    // the pipe and the speaker.
                    if frame.kind == .speech {
                        router.route(frame.payload)
                    } else {
                        onMain { self?.handle(frame, router: router, run: run) }
                    }
                }
            }, onStderr: { [weak self] data in
                let text = String(decoding: data, as: UTF8.self)
                onMain { self?.appendLog(text, run: run) }
            }, onExit: { [weak self] exit in
                onMain { self?.runnerExited(exit, run: run) }
            })
        } catch {
            return fail(String(format: NSLocalizedString("Couldn't start the voice runner: %@", comment: ""), error.localizedDescription), run: run)
        }
        process = child
    }

    private func handle(_ frame: VoiceFrame, router: SpeechRouter, run: Int) {
        guard run == generation else { return }
        switch frame.kind {
        case .ready:
            guard let ready = VoiceRunnerReady(payload: frame.payload) else {
                return runnerFailed(NSLocalizedString("The voice runner sent an unreadable ready message.", comment: ""), run: run)
            }
            startAudio(ready, router: router, run: run)
        case .text:
            transcriptTurns.append(frame.text, from: .model)
            transcript = transcriptTurns.text
        case .userText:
            transcriptTurns.append(frame.text, from: .user)
            transcript = transcriptTurns.text
        case .note:
            replyNote = frame.text
        case .error:
            lastError = frame.text
            appendLog("error: " + frame.text + "\n", run: run)
        case .log:
            appendLog(frame.text + "\n", run: run)
        case .replyDone:
            replyDone(VoiceReplyDone(payload: frame.payload))
        default:
            break
        }
    }

    private func startAudio(_ ready: VoiceRunnerReady, router: SpeechRouter, run: Int) {
        guard !stopRequested, let process else { return }
        guard let player = SpeechPlayer(sampleRate: ready.sampleRate) else {
            return runnerFailed(NSLocalizedString("The voice model's audio format isn't supported.", comment: ""), run: run)
        }
        self.ready = ready
        applyMode()
        let mic = MicrophoneCapture(sampleRate: ready.inputSampleRate)
        let meter = self.meter, gate = self.gate
        do {
            try player.start()
            router.player = player
            try mic.start { data, rms in
                meter.set(PCM16.meterLevel(rms: rms))
                // Walkie-talkie: only while the user talks.
                if gate.isOpen { process.write(VoiceFrame(.audio, payload: data).encoded) }
            }
        } catch {
            player.stop()
            router.player = nil
            return runnerFailed(String(format: NSLocalizedString("The microphone couldn't start: %@", comment: ""), error.localizedDescription), run: run)
        }
        self.player = player
        self.mic = mic
        startedAt = Date()
        phase = .running
        // The meter and the speaking state, 20 times a second.
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.level = self.meter.get()
                self.isSpeaking = self.player?.isSpeaking ?? false
                if self.turn == .thinking, let router = self.router, let rate = self.ready?.sampleRate, rate > 0 {
                    self.replyReadySeconds = Double(router.replySamples) / Double(rate)
                }
            }
        }
    }

    // MARK: Full duplex / walkie-talkie

    /// The mode setting, applied now: at ready, and when it's changed
    /// during a session (the window's picker). The runner is told (`M`).
    func applyMode() {
        guard let ready else { return }
        let mode = VoiceLabMode(rawValue: UserDefaults.standard[Pref.voiceLabMode]) ?? .auto
        let walkie = mode.usesWalkieTalkie(rtf: ready.rtf)
        speedNotice = mode == .auto && walkie
            ? String(format: NSLocalizedString("This Mac runs the model at ~%@× real time: talk, then listen.", comment: "Voice Lab: speed"),
                     VoiceLabMode.speedText(rtf: ready.rtf ?? 1))
            : nil
        guard walkie != isWalkieTalkie || router?.mode == nil else { return }
        if turn == .thinking { process?.write(VoiceFrame(.cancelReply).encoded) }
        isWalkieTalkie = walkie
        turn = .waiting
        replyNote = nil
        process?.write(VoiceFrame(.mode, text: VoiceLabMode.runnerMode(walkieTalkie: walkie)).encoded)
        player?.cancelPlayback()
        player?.setPrebuffer(milliseconds: walkie ? Self.replyPrebufferMilliseconds : Self.duplexPrebufferMilliseconds)
        if walkie {
            gate.isOpen = false
            router?.mode = .discard
        } else {
            gate.isOpen = true
            router?.mode = .live
        }
    }

    /// Walkie-talkie's big button. Waiting: talk. Talking: done, the model
    /// answers. Thinking: cancel the reply. A reply still playing is cut
    /// when the user talks again.
    func toggleTalk() {
        guard phase == .running, isWalkieTalkie, let process, let router else { return }
        replyNote = nil
        switch turn {
        case .talking:
            gate.isOpen = false
            router.startReply()
            replyReadySeconds = 0
            transcriptTurns.endTurn()
            process.write(VoiceFrame(.endOfTurn, text: String(turnNumber)).encoded)
            turn = .thinking
        case .thinking:
            process.write(VoiceFrame(.cancelReply).encoded)
            router.mode = .discard
            player?.cancelPlayback()
            transcriptTurns.endTurn()
            turn = .waiting
        case .waiting:
            router.mode = .discard
            player?.cancelPlayback()
            transcriptTurns.endTurn()
            turnNumber += 1
            gate.isOpen = true
            turn = .talking
        }
    }

    private func replyDone(_ done: VoiceReplyDone?) {
        guard isWalkieTalkie, turn == .thinking, let done, done.turn == turnNumber, let router else { return }
        router.mode = .discard
        turn = .waiting
        transcriptTurns.endTurn()
        switch done.reason {
        case .noReply:
            replyNote = NSLocalizedString("The model didn't answer -- try again.", comment: "Voice Lab")
        case .limit:
            replyNote = NSLocalizedString("The reply was cut at its length limit.", comment: "Voice Lab")
        case .done, .interrupted, .reset:
            break
        }
        // Complete: whatever is held below the prebuffer plays now.
        player?.flush()
    }

    // MARK: Stop

    /// Stop, the window closing, or quitting from the menu: the audio stops
    /// at once, the runner is asked to quit (and killed if it doesn't), the
    /// chat model reloads.
    func stop() {
        guard isActive, !stopRequested else { return }
        stopRequested = true
        stopAudio()
        guard let process else {
            // Still preparing: prepare() sees stopRequested and tidies up.
            phase = .stopping
            return
        }
        phase = .stopping
        process.write(VoiceFrame(.quit).encoded)
        endProcess(graceSeconds: 3)
    }

    /// stdin closed (the runner quits at EOF); SIGTERM after `graceSeconds`
    /// if it's still there, SIGKILL 3 s later -- its ~9 GB must not linger.
    private func endProcess(graceSeconds: UInt64) {
        process?.closeStdin()
        let run = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: graceSeconds * 1_000_000_000)
            guard let self, self.generation == run, let p = self.process else { return }
            p.terminate()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard self.generation == run, let p = self.process else { return }
            p.kill()
        }
    }

    /// App quit: no time to wait.
    func terminateNow() {
        stopAudio()
        process?.kill()
    }

    private func stopAudio() {
        gate.isOpen = false
        router?.player = nil
        router = nil
        meterTimer?.invalidate()
        meterTimer = nil
        mic?.stop()
        mic = nil
        player?.stop()
        player = nil
        level = 0
        isSpeaking = false
    }

    private func runnerFailed(_ message: String, run: Int) {
        guard run == generation else { return }
        lastError = lastError ?? message
        stopRequested = true
        stopAudio()
        phase = .stopping
        endProcess(graceSeconds: 1)
    }

    private func runnerExited(_ exit: DuplexProcess.Exit, run: Int) {
        guard run == generation else { return }
        process = nil
        stopAudio()
        if let lastError {
            phase = .failed(lastError)
        } else if !stopRequested {
            let how = exit.signaled ? "signal \(exit.status)" : "code \(exit.status)"
            let tail = log.split(separator: "\n").suffix(3).joined(separator: "\n")
            phase = .failed(String(format: NSLocalizedString("The voice runner stopped unexpectedly (%@).", comment: ""), how)
                            + (tail.isEmpty ? "" : "\n" + tail))
        }
        finish(run: run)
    }

    private func fail(_ message: String, run: Int) {
        guard run == generation else { return }
        lastError = message
        finish(run: run)
    }

    /// Brings the chat model back, then hands the generator queue on (not
    /// before: the next generator would start beside the reloading model).
    private func finish(run: Int) {
        guard run == generation else { return }
        let ticket = self.ticket
        self.ticket = nil
        startedAt = nil
        if let lastError {
            phase = .failed(lastError)
        } else if case .failed = phase {
        } else {
            phase = .idle
        }
        guard suspended else {
            ticket?.release()
            return
        }
        suspended = false
        let reload = reloadChatModel
        reloadChatModel = false
        Task { [weak self, server] in
            do {
                try await server?.endVoiceSuspension(reload: reload)
            } catch {
                self?.appendLog("reloading the chat model failed: \(error.localizedDescription)\n", run: run)
            }
            ticket?.release()
        }
    }

    private func appendLog(_ text: String, run: Int) {
        guard run == generation else { return }
        log += text
        if log.count > 20_000 { log = String(log.suffix(15_000)) }
    }
}

/// Onto the main actor in the order called (a Task per frame could reorder
/// text deltas; the exit must come after the frames before it).
private func onMain(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
}

/// The stdout reader's decoder: used from that one thread only.
private final class FrameReader: @unchecked Sendable {
    private var decoder = VoiceFrameDecoder()
    func append(_ data: Data) throws -> [VoiceFrame] { try decoder.append(data) }
}

/// Where the runner's speech goes, decided on the main actor and applied
/// on the stdout reader thread: to the player (full duplex), into a
/// walkie-talkie reply's buffer until it's complete, or nowhere (the user
/// is talking; a reply they talked over).
private final class SpeechRouter: @unchecked Sendable {
    /// `live`: to the player as it comes (full duplex). `reply`: a
    /// walkie-talkie reply -- its leading silence dropped, the rest to the
    /// player, which holds ~3 s before it starts. `discard`: the user is
    /// talking, or a reply was cancelled.
    enum Mode { case live, reply, discard }

    private let lock = NSLock()
    private var storedPlayer: SpeechPlayer?
    private var storedMode: Mode?
    private var trim = LeadingSilenceTrim()
    private var samples = 0

    var player: SpeechPlayer? {
        get { lock.lock(); defer { lock.unlock() }; return storedPlayer }
        set { lock.lock(); storedPlayer = newValue; lock.unlock() }
    }

    /// nil until the mode is first applied (speech before that is dropped).
    var mode: Mode? {
        get { lock.lock(); defer { lock.unlock() }; return storedMode }
        set { lock.lock(); storedMode = newValue; lock.unlock() }
    }

    /// Of the current reply, after the trim.
    var replySamples: Int {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    func startReply() {
        lock.lock()
        trim.reset()
        samples = 0
        storedMode = .reply
        lock.unlock()
    }

    func route(_ pcm: Data) {
        lock.lock()
        switch storedMode {
        case .live:
            let player = storedPlayer
            lock.unlock()
            player?.enqueue(PCM16.samples(from: pcm))
        case .reply:
            let chunk = PCM16.samples(from: pcm)
            guard trim.admit(rms: PCM16.rms(chunk)) else { lock.unlock(); return }
            samples += chunk.count
            let player = storedPlayer
            lock.unlock()
            player?.enqueue(chunk)
        case .discard, nil:
            lock.unlock()
        }
    }
}

/// Whether the mic's frames go to the runner: read on the audio thread.
private final class MicGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    var isOpen: Bool {
        get { lock.lock(); defer { lock.unlock() }; return open }
        set { lock.lock(); open = newValue; lock.unlock() }
    }
}

/// The latest mic level, written by the audio thread.
private final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0
    func set(_ v: Float) { lock.lock(); value = v; lock.unlock() }
    func get() -> Float { lock.lock(); defer { lock.unlock() }; return value }
}
