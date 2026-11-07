import AVFoundation
import Combine
import Foundation
import LLMTrayCore
import Speech

/// A spoken conversation with the chat's model (adr/0031): the microphone
/// and the answers' voice share Apple's voice-processing unit (echo
/// cancellation), the listen runner finds the user's turns, the chat
/// answers as usual with the voice-mode prompt, and SpokenAnswers reads the
/// answer. Speaking over the model ducks it at once; a backchannel lets it
/// go on, more is an interruption: it stops, the generation is cancelled,
/// and the answer keeps only what was heard.
@MainActor
final class VoiceConversation: ObservableObject {
    static let shared = VoiceConversation()

    enum Phase: Equatable {
        case off
        case starting(String)
        case listening
        case hearing
        case thinking
        case speaking
        case failed(String)
    }

    @Published private(set) var phase: Phase = .off
    /// The user's words as they're recognized (the live caption).
    @Published private(set) var userText = ""
    /// The answer's sentences heard so far, and the one playing.
    @Published private(set) var heard: [String] = []
    /// The microphone's level, 0...1, for the orb.
    @Published private(set) var level: Float = 0
    /// The chat the conversation is in.
    private(set) weak var chat: ChatClient?

    private var send: ((String, [Data]) -> Void)?
    private var io: VoiceProcessingIO?
    private var runner: DuplexProcess?
    private var apple: AppleRecognizer?
    private var cancellables: Set<AnyCancellable> = []
    /// The user spoke while the model talked: its voice is ducked until the
    /// turn shows whether that was a backchannel.
    private var bargeCandidate = false
    /// The turn's audio (16 kHz PCM16), for a model that hears.
    private var turnAudio = Data()
    private var recordingTurn = false
    /// The last ~0.6 s of the microphone: the runner reports a turn's start
    /// ~0.4 s into it, and those first syllables belong to the turn.
    private var recent = Data()
    private static let recentBytes = 16000 * 2 * 6 / 10
    private var language: String?
    private var fillerTimer: Timer?
    private var fillerPlayedThisTurn = false
    private var fillerOutput: SpeechOutput?
    private var sleepTimer: Timer?
    private var fillers = FillerBank()
    private var makingFiller = false

    static let duckGain: Float = 0.2
    static let fillerDelay: TimeInterval = 1.2
    static let sleepAfter: TimeInterval = 300

    private init() {}

    var isActive: Bool {
        switch phase {
        case .off, .failed: return false
        default: return true
        }
    }

    func isActive(in chat: ChatClient) -> Bool { isActive && self.chat === chat }

    // MARK: Start / stop

    func start(chat: ChatClient, send: @escaping (String, [Data]) -> Void) {
        if isActive { stop() }
        self.chat = chat
        self.send = send
        userText = ""
        heard = []
        let store = VoiceInputStore.shared
        guard store.isReady else {
            phase = .failed(NSLocalizedString("Download the speech recognizer first: Settings > Voice > Voice conversation.", comment: "voice conversation"))
            return
        }
        phase = .starting(NSLocalizedString("Starting…", comment: "voice conversation"))
        Task {
            guard await Self.microphoneAllowed() else {
                return fail(NSLocalizedString("LLMTray isn't allowed to use the microphone: System Settings > Privacy & Security > Microphone.", comment: "voice conversation"))
            }
            if store.recognizer == .apple {
                do { apple = try await AppleRecognizer.make() } catch { return fail(error.localizedDescription) }
            }
            if let error = await AudioRuntime.shared.ensureInstalledOrKeepError() { NSLog("LLMTray: audio runtime: %@", error) }
            launchRunner(recognizer: store.recognizer)
        }
    }

    func stop() {
        fillerTimer?.invalidate()
        sleepTimer?.invalidate()
        if let runner {
            _ = runner.write(VoiceFrame(.quit).encoded)
            runner.closeStdin()
        }
        runner = nil
        io?.stop()
        io = nil
        apple?.cancel()
        apple = nil
        cancellables = []
        let spoken = SpokenAnswers.shared
        spoken.stop()
        spoken.voiceMode = false
        spoken.audioSink = nil
        spoken.onSentencePlayed = nil
        chat?.voiceMode = false
        chat = nil
        send = nil
        bargeCandidate = false
        recordingTurn = false
        level = 0
        phase = .off
    }

    private func fail(_ message: String) {
        let chat = self.chat
        stop()
        // The message shows in that chat until dismissed.
        self.chat = chat
        phase = .failed(message)
    }

    /// Hides a failure's message.
    func dismiss() {
        if case .failed = phase { phase = .off; chat = nil }
    }

    // MARK: Runner

    private func launchRunner(recognizer: VoiceRecognizer) {
        var args = [
            RuntimePaths.runtimeDir + "/llmtray_listen_runner.py",
            "--vad", VoiceInputStore.path(.vad),
            "--turn", VoiceInputStore.path(.turn),
        ]
        switch recognizer {
        case .parakeet: args += ["--stt", "parakeet", "--stt-model", VoiceInputStore.path(.parakeet)]
        case .whisper: args += ["--stt", "whisper", "--stt-model", VoiceInputStore.path(.whisper)]
        case .apple: args += ["--stt", "none"]
        }
        let child = DuplexProcess(executable: AudioRuntime.venvPython, arguments: args, environment: [
            "PYTHONDONTWRITEBYTECODE": "1", "PYTHONUNBUFFERED": "1", "HF_HUB_OFFLINE": "1",
            "TOKENIZERS_PARALLELISM": "false", OrphanScan.listenRunnerMarker: "1",
        ])
        let reader = ListenFrameReader()
        let stderrTail = TextTail()
        do {
            try child.start(onStdout: { [weak self, weak child] data in
                let frames = (try? reader.append(data)) ?? []
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self, let child, self.runner === child else { return }
                    frames.forEach { self.handle($0) }
                } }
            }, onStderr: { data in
                stderrTail.append(String(decoding: data, as: UTF8.self))
            }, onExit: { [weak self, weak child] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self, let child, self.runner === child else { return }
                    let last = stderrTail.lastLine
                    self.fail(String(format: NSLocalizedString("The speech recognizer stopped: %@", comment: "voice conversation"), last))
                } }
            })
        } catch {
            return fail(error.localizedDescription)
        }
        runner = child
    }

    private func handle(_ frame: VoiceFrame) {
        let info = (try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any]
        switch frame.type {
        case UInt8(ascii: "R"):
            startAudio()
        case UInt8(ascii: "V"):
            speechStarted()
        case UInt8(ascii: "U"):
            partial(info?["text"] as? String ?? "")
        case UInt8(ascii: "Z"):
            turnEnded(info?["text"] as? String ?? "")
        case UInt8(ascii: "E"):
            let message = info?["message"] as? String ?? frame.text
            if info?["fatal"] as? Bool == true { fail(message) } else { NSLog("LLMTray listen runner: %@", message) }
        case UInt8(ascii: "L"):
            NSLog("LLMTray listen runner: %@", frame.text)
        default:
            break
        }
    }

    // MARK: Audio

    private func startAudio() {
        let io: VoiceProcessingIO
        do {
            io = try VoiceProcessingIO(inputSampleRate: 16000)
        } catch {
            return fail(String(format: NSLocalizedString("Echo cancellation isn't available: %@", comment: "voice conversation"), error.localizedDescription))
        }
        self.io = io
        let spoken = SpokenAnswers.shared
        spoken.stop()
        spoken.voiceMode = true
        spoken.audioSink = io
        spoken.onSentencePlayed = { [weak self] text in self?.sentencePlayed(text) }
        chat?.voiceMode = true
        observeChat()
        let runner = self.runner
        let levelBox = LevelBox()
        do {
            try io.start { [weak self] data, rms in
                // On the I/O queue: the runner first, then the UI's level.
                _ = runner?.write(VoiceFrame(.audio, payload: data).encoded)
                if levelBox.shouldPublish() {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.micChunk(data, rms: rms) } }
                } else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.record(data) } }
                }
            }
        } catch {
            return fail(error.localizedDescription)
        }
        phase = .listening
        tellRunner()
        resetSleep()
        makeNextFiller()
    }

    private func micChunk(_ data: Data, rms: Float) {
        level = PCM16.meterLevel(rms: rms)
        record(data)
    }

    private func record(_ data: Data) {
        guard recordingTurn else {
            recent.append(data)
            if recent.count > Self.recentBytes { recent.removeFirst(recent.count - Self.recentBytes) }
            return
        }
        if turnAudio.count < 16000 * 2 * 30 { turnAudio.append(data) }
        apple?.append(data)
    }

    private func tellRunner() {
        let speaking = phase == .speaking
        let payload = (try? JSONSerialization.data(withJSONObject: ["speaking": speaking, "language": language as Any])) ?? Data()
        _ = runner?.write(VoiceFrame(.mode, payload: payload).encoded)
    }

    // MARK: Turns

    private func speechStarted() {
        resetSleep()
        if phase == .speaking || SpokenAnswers.shared.speakingMessage != nil {
            bargeCandidate = true
            io?.speechGain = Self.duckGain
        } else {
            phase = .hearing
            userText = ""
        }
        turnAudio = recent
        recent = Data()
        recordingTurn = true
        apple?.beginTurn()
        apple?.append(turnAudio)
    }

    private func partial(_ text: String) {
        guard !text.isEmpty else { return }
        if bargeCandidate {
            // More than a few words over the model: an interruption.
            if text.split(whereSeparator: \.isWhitespace).count > 3 { interrupt() } else { return }
        }
        userText = text
    }

    private func turnEnded(_ runnerText: String) {
        recordingTurn = false
        Task {
            var text = runnerText
            if let apple { text = await apple.endTurn() }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if bargeCandidate {
                if text.isEmpty || VoiceConversationText.isBackchannel(text) {
                    // "угу": the model goes on.
                    bargeCandidate = false
                    io?.speechGain = 1
                    return
                }
                interrupt()
            }
            guard !text.isEmpty else {
                if phase == .hearing { phase = .listening }
                return
            }
            submit(text)
        }
    }

    private func interrupt() {
        bargeCandidate = false
        io?.speechGain = 1
        fillerOutput?.reset()
        let kept = heard
        SpokenAnswers.shared.stop()
        if let chat {
            if chat.isTurnInProgress { chat.cancel() }
            chat.cutLastAnswer(toSpoken: kept)
        }
        heard = []
        phase = .hearing
    }

    private func submit(_ text: String) {
        userText = text
        heard = []
        language = SpeechLanguage.detect(text, fallback: language ?? Locale.current.language.languageCode?.identifier)
        phase = .thinking
        fillerPlayedThisTurn = false
        let audio = UserDefaults.standard[Pref.voiceSendAudio] && turnAudio.count > 3200
            ? [WAVFile.pcm16(turnAudio, sampleRate: 16000)] : []
        send?(text, audio)
        tellRunner()
        armFiller()
    }

    private func sentencePlayed(_ text: String) {
        heard.append(text)
    }

    // MARK: The chat's state

    private func observeChat() {
        cancellables = []
        SpokenAnswers.shared.$speakingMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in self?.speakingChanged(message != nil) }
            .store(in: &cancellables)
        chat?.$isRunningTools
            .receive(on: RunLoop.main)
            .sink { [weak self] running in if running { self?.toolStarted() } }
            .store(in: &cancellables)
        chat?.$isStreaming
            .receive(on: RunLoop.main)
            .sink { [weak self] streaming in if !streaming { self?.maybeDone() } }
            .store(in: &cancellables)
    }

    private func speakingChanged(_ speaking: Bool) {
        guard isActive else { return }
        if speaking {
            fillerTimer?.invalidate()
            fillerOutput?.reset()
            if phase != .hearing || !bargeCandidate { phase = .speaking }
        } else {
            maybeDone()
        }
        tellRunner()
    }

    private func maybeDone() {
        guard isActive, SpokenAnswers.shared.speakingMessage == nil, chat?.isBusy != true else { return }
        if phase == .speaking || phase == .thinking {
            phase = .listening
            bargeCandidate = false
            io?.speechGain = 1
            tellRunner()
            resetSleep()
            makeNextFiller()
        }
    }

    private func resetSleep() {
        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(withTimeInterval: Self.sleepAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .listening else { return }
                self.stop()
            }
        }
    }

    // MARK: Fillers (adr/0031)

    private var fillersOn: Bool { UserDefaults.standard[Pref.voiceFillers] }
    private var lang: String { language ?? Locale.current.language.languageCode?.identifier ?? "en" }

    private func armFiller() {
        fillerTimer?.invalidate()
        guard fillersOn else { return }
        fillerTimer = Timer.scheduledTimer(withTimeInterval: Self.fillerDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.playFiller(VoiceConversationText.thinking(self?.lang ?? "en")) }
        }
    }

    private func toolStarted() {
        guard isActive, fillersOn, SpokenAnswers.shared.speakingMessage == nil else { return }
        let name = chat?.messages.last(where: { $0.role == "assistant" })?.toolCalls.last?.name ?? ""
        playFiller([VoiceConversationText.tool(VoiceConversationText.toolKind(name), lang)])
    }

    /// One of `texts` that's ready, never twice in a turn and never the
    /// last one again.
    private func playFiller(_ texts: [String]) {
        guard isActive, !fillerPlayedThisTurn, SpokenAnswers.shared.speakingMessage == nil, let io else { return }
        let key = SpokenAnswers.shared.fillerVoiceKey(language: lang)
        guard let (samples, rate) = fillers.pick(texts, voice: key, language: lang) else { return }
        fillerPlayedThisTurn = true
        let output = io.speechOutput(sampleRate: rate)
        fillerOutput = output
        output?.schedule(samples) {}
    }

    /// Made one at a time while the conversation is quiet: the answer
    /// always comes first.
    private func makeNextFiller() {
        guard isActive, fillersOn, !makingFiller, phase == .listening else { return }
        let language = lang
        let key = SpokenAnswers.shared.fillerVoiceKey(language: language)
        guard let text = fillers.missing(VoiceConversationText.allFillers(language), voice: key, language: language) else { return }
        makingFiller = true
        Task {
            let audio = await SpokenAnswers.shared.renderFiller(text, language: language)
            makingFiller = false
            if let audio { fillers.store(text, audio.samples, rate: audio.rate, voice: key, language: language) }
            if audio != nil { makeNextFiller() }
        }
    }

    // MARK: Helpers

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// Publishes the mic level ~15 times a second (the I/O queue delivers a
/// chunk every 10 ms).
private final class LevelBox: @unchecked Sendable {
    private var last = DispatchTime.now().uptimeNanoseconds
    func shouldPublish() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - last > 66_000_000 else { return false }
        last = now
        return true
    }
}

/// The runner's stderr tail, appended from the reader thread.
private final class TextTail: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ s: String) { lock.withLock { text = String((text + s).suffix(1500)) } }
    var lastLine: String { lock.withLock { text.split(separator: "\n").last.map(String.init) ?? "" } }
}

private final class ListenFrameReader: @unchecked Sendable {
    private var decoder = VoiceFrameDecoder()
    func append(_ data: Data) throws -> [VoiceFrame] { try decoder.append(data) }
}

/// Fillers made with the answers' voice, kept on disk by voice and
/// language (adr/0031): made in the silences, played on a long pause.
struct FillerBank {
    private var last: String?
    private var memory: [String: ([Float], Int)] = [:]

    private static var root: String { RuntimePaths.externalRuntimeDir + "/voice_fillers" }

    private func file(_ text: String, voice: String, language: String) -> String {
        let safe = voice.replacingOccurrences(of: "/", with: "_")
        let name = String(text.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }, radix: 16)
        return Self.root + "/\(safe)/\(language)/\(name).pcm"
    }

    private mutating func load(_ path: String) -> ([Float], Int)? {
        if let hit = memory[path] { return hit }
        guard let data = FileManager.default.contents(atPath: path), data.count > 4 else { return nil }
        let rate = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let samples = PCM16.samples(from: data.dropFirst(4))
        memory[path] = (samples, rate)
        return (samples, rate)
    }

    func missing(_ texts: [String], voice: String, language: String) -> String? {
        texts.first { !FileManager.default.fileExists(atPath: file($0, voice: voice, language: language)) }
    }

    mutating func store(_ text: String, _ samples: [Float], rate: Int, voice: String, language: String) {
        let path = file(text, voice: voice, language: language)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var data = Data()
        withUnsafeBytes(of: UInt32(rate)) { data.append(contentsOf: $0) }
        data.append(PCM16.data(from: samples))
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        memory[path] = (samples, rate)
    }

    mutating func pick(_ texts: [String], voice: String, language: String) -> ([Float], Int)? {
        let ready = texts.filter { $0 != last && FileManager.default.fileExists(atPath: file($0, voice: voice, language: language)) }
        guard let text = ready.randomElement(), let audio = load(file(text, voice: voice, language: language)) else { return nil }
        last = text
        return audio
    }
}

/// macOS's recognizer for the user's turns, on-device only (adr/0031):
/// fed the microphone between the runner's turn start and end.
@MainActor
final class AppleRecognizer {
    enum Failure: LocalizedError {
        case notAllowed, noOnDevice(String)
        var errorDescription: String? {
            switch self {
            case .notAllowed:
                return NSLocalizedString("Speech recognition isn't allowed, or Siri and Dictation are off: System Settings > Keyboard > Dictation.", comment: "voice conversation")
            case .noOnDevice(let language):
                return String(format: NSLocalizedString("macOS can't recognize %@ on this Mac without sending it off the Mac. Pick Parakeet in Settings > Voice.", comment: "voice conversation: a language"), language)
            }
        }
    }

    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var finished: CheckedContinuation<String, Never>?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private init(_ recognizer: SFSpeechRecognizer) { self.recognizer = recognizer }

    static func make() async throws -> AppleRecognizer {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized, let r = SFSpeechRecognizer(locale: Locale.current) else { throw Failure.notAllowed }
        guard r.supportsOnDeviceRecognition else { throw Failure.noOnDevice(Locale.current.identifier) }
        return AppleRecognizer(r)
    }

    func beginTurn() {
        cancelTask()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        latest = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? true
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                if let text { self.latest = text }
                if final, let c = self.finished { self.finished = nil; c.resume(returning: self.latest) }
            } }
        }
        self.request = request
    }

    func append(_ pcm: Data) {
        guard let request else { return }
        let samples = PCM16.samples(from: pcm)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        request.append(buffer)
    }

    /// The final text, or what's there after a second.
    func endTurn() async -> String {
        guard let request else { return latest }
        request.endAudio()
        self.request = nil
        let text: String = await withCheckedContinuation { c in
            finished = c
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let c = self.finished else { return }
                    self.finished = nil
                    c.resume(returning: self.latest)
                }
            }
        }
        task = nil
        return text
    }

    func cancel() { cancelTask() }

    private func cancelTask() {
        task?.cancel()
        task = nil
        request = nil
        if let c = finished { finished = nil; c.resume(returning: latest) }
    }
}
