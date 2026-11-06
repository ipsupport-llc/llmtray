import AVFoundation
import Foundation
import LLMTrayCore

/// Reads answers aloud (adr/0016, spoken answers): Speak on an answer, or
/// every new answer as it streams when "Read answers aloud" is on. The
/// text goes through SentenceStream (Markdown made speakable, cut into
/// sentences) to a voice: macOS's own, or Chatterbox through its runner.
@MainActor
final class SpokenAnswers: ObservableObject {
    static let shared = SpokenAnswers()

    /// Each new answer is read as it streams.
    @Published var readsAloud: Bool {
        didSet {
            UserDefaults.standard[Pref.spokenAnswersAuto] = readsAloud
            if !readsAloud, streamClient != nil { stop() }
        }
    }
    @Published var voiceKind: SpokenVoiceKind {
        didSet {
            UserDefaults.standard[Pref.spokenAnswersVoice] = voiceKind.rawValue
            if voiceKind != oldValue { stop() }
        }
    }
    /// The clip Chatterbox imitates (in the support folder); nil: its
    /// built-in voice.
    @Published private(set) var clipPath: String?
    /// The answer being read.
    @Published private(set) var speakingMessage: UUID?
    /// Why the last answer wasn't read with Chatterbox (shown in Settings).
    @Published private(set) var note: String?

    private var system: SystemSpeaker?
    private var chatterbox: ChatterboxSpeaker?
    private weak var active: SentenceSpeaker?
    private var stream: SentenceStream?
    private var streamClient: ObjectIdentifier?
    /// The message `stream` holds (it may have no sentence yet).
    private var streamMessage: UUID?
    private var answerLanguage: String?

    private init() {
        readsAloud = UserDefaults.standard[Pref.spokenAnswersAuto]
        voiceKind = SpokenVoiceKind(rawValue: UserDefaults.standard[Pref.spokenAnswersVoice]) ?? .system
        let clip = UserDefaults.standard[Pref.spokenAnswersClip]
        clipPath = clip.isEmpty || !FileManager.default.fileExists(atPath: clip) ? nil : clip
    }

    var isRunnerActive: Bool { chatterbox?.isRunning ?? false }

    static var codeBlockPhrase: String { NSLocalizedString("Code in the chat.", comment: "spoken answers: read instead of a code block") }

    // MARK: What the chat calls

    /// Speak on an answer: reads it, or stops when it's the one being read.
    func toggle(messageID: UUID, markdown: String) {
        if speakingMessage == messageID { return stop() }
        stop()
        var s = SentenceStream(codeBlock: Self.codeBlockPhrase)
        let sentences = s.feed(markdown) + s.finish()
        guard !sentences.isEmpty else { return }
        start(messageID: messageID, sample: sentences.prefix(3).joined(separator: " "))
        for sentence in sentences { say(sentence) }
        active?.endOfInput()
    }

    /// A delta of the answer `messageID` streaming in `client`'s chat.
    func streamed(client: ObjectIdentifier, messageID: UUID, delta: String) {
        guard readsAloud else { return }
        if streamClient != client {
            // Another chat's answer: what was being read stops.
            stop()
            streamClient = client
        }
        if streamMessage != messageID {
            // The next message of this turn (after a tool call): the last
            // one's rest is read first, in order.
            finishStream()
            streamMessage = messageID
            stream = SentenceStream(codeBlock: Self.codeBlockPhrase)
        }
        guard var s = stream else { return }
        let sentences = s.feed(delta)
        stream = s
        guard !sentences.isEmpty else { return }
        if active == nil {
            start(messageID: messageID, sample: sentences.joined(separator: " "))
        } else {
            speakingMessage = messageID
        }
        for sentence in sentences { say(sentence) }
    }

    /// The client's stream stopped: the rest of the answer is spoken.
    func streamEnded(client: ObjectIdentifier) {
        guard streamClient == client else { return }
        finishStream()
    }

    /// A new message is sent, Stop pressed, the voice changed.
    func stop() {
        stream = nil
        streamClient = nil
        streamMessage = nil
        answerLanguage = nil
        speakingMessage = nil
        system?.stop()
        chatterbox?.stop()
        active = nil
    }

    // MARK: Voice clip

    /// Stores `url` as the voice clip, as a 16-bit WAV whatever it was
    /// (M4A, MP3...: the runner's audio loader reads WAV for sure); nil:
    /// back to the built-in voice.
    func setClip(_ url: URL?) throws {
        let fm = FileManager.default
        let dir = RuntimePaths.externalRuntimeDir + "/voice_clips"
        var stored: String?
        if let url {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let dest = URL(fileURLWithPath: dir + "/voice-\(UUID().uuidString.prefix(8)).wav")
            try Self.writeWAV(from: url, to: dest, maxSeconds: VoiceClipCheck.maxSeconds)
            stored = dest.path
        }
        if let old = clipPath, old.hasPrefix(dir), old != stored { try? fm.removeItem(atPath: old) }
        clipPath = stored
        UserDefaults.standard[Pref.spokenAnswersClip] = stored ?? ""
        chatterbox?.setClip(stored)
    }

    /// The first `maxSeconds` of any audio file AVFoundation reads, as
    /// 16-bit PCM WAV at its own rate and channel count.
    static func writeWAV(from source: URL, to dest: URL, maxSeconds: Double) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let frames = AVAudioFrameCount(min(Double(input.length), format.sampleRate * maxSeconds))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try input.read(into: buffer, frameCount: frames)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let output = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: format.commonFormat,
                                     interleaved: format.isInterleaved)
        try output.write(from: buffer)
    }

    // MARK: Inside

    private func finishStream() {
        guard var s = stream else { return }
        let rest = s.finish()
        let message = streamMessage
        stream = nil
        streamMessage = nil
        // A message too short for a sentence before its end starts here.
        if !rest.isEmpty, active == nil, let message {
            start(messageID: message, sample: rest.joined(separator: " "))
        }
        for sentence in rest { say(sentence) }
        active?.endOfInput()
    }

    /// The first sentences of an answer: its language picks the voice.
    private func start(messageID: UUID, sample: String) {
        speakingMessage = messageID
        answerLanguage = SpeechLanguage.detect(sample, fallback: Locale.current.language.languageCode?.identifier)
        active = speaker(for: answerLanguage)
    }

    private func say(_ sentence: String) {
        guard let active else { return }
        let lang = SpeechLanguage.detect(sentence, fallback: answerLanguage, confidence: 0.8) ?? answerLanguage ?? "en"
        active.enqueue(sentence, language: lang)
    }

    /// Chatterbox when it's picked, ready and speaks the answer's language;
    /// macOS's voice otherwise.
    private func speaker(for language: String?) -> SentenceSpeaker {
        if voiceKind == .chatterbox {
            if !SpokenVoiceStore.isReady {
                note = NSLocalizedString("Chatterbox isn't downloaded: the system voice read the answer.", comment: "spoken answers")
            } else if let language, !SpeechLanguage.chatterbox.contains(language) {
                note = String(format: NSLocalizedString("Chatterbox doesn't speak this language (%@): the system voice read the answer.",
                                                        comment: "spoken answers: a language code"), language)
            } else {
                note = nil
                let c = chatterbox ?? makeChatterbox()
                c.onFailure = { [weak self] message in
                    self?.note = message
                    self?.speakingMessage = nil
                    self?.active = nil
                }
                return c
            }
        }
        let s = system ?? SystemSpeaker()
        system = s
        s.onIdle = { [weak self] in self?.idle(s) }
        return s
    }

    private func makeChatterbox() -> ChatterboxSpeaker {
        let c = ChatterboxSpeaker(clip: clipPath)
        c.onIdle = { [weak self, weak c] in if let c { self?.idle(c) } }
        chatterbox = c
        return c
    }

    private func idle(_ speaker: SentenceSpeaker) {
        guard active === speaker, stream == nil else { return }
        speakingMessage = nil
        active = nil
    }
}

/// A voice that reads sentences in order.
@MainActor
protocol SentenceSpeaker: AnyObject {
    func enqueue(_ sentence: String, language: String)
    /// No more sentences for this answer: idle once they've played.
    func endOfInput()
    func stop()
    var onIdle: (() -> Void)? { get set }
}

// MARK: - macOS voices

/// AVSpeechSynthesizer with the best installed voice for each sentence's
/// language (premium or enhanced first, as the user installed them).
@MainActor
final class SystemSpeaker: NSObject, SentenceSpeaker, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var queued = 0
    private var ended = false
    var onIdle: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func enqueue(_ sentence: String, language: String) {
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = Self.voice(for: language)
        queued += 1
        ended = false
        synth.speak(utterance)
    }

    func endOfInput() {
        ended = true
        if queued == 0 { onIdle?() }
    }

    func stop() {
        queued = 0
        ended = false
        synth.stopSpeaking(at: .immediate)
    }

    static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == language || $0.language.hasPrefix(language + "-")
        }
        let preferred = Locale.current.region.map { language + "-" + $0.identifier }
        return voices.max { a, b in
            (a.quality.rawValue, a.language == preferred ? 1 : 0) < (b.quality.rawValue, b.language == preferred ? 1 : 0)
        } ?? AVSpeechSynthesisVoice(language: language)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {}

    private func finished() {
        queued = max(0, queued - 1)
        if queued == 0, ended { onIdle?() }
    }
}

// MARK: - Chatterbox

/// The Chatterbox runner (runtime/llmtray_tts_runner.py) and the player
/// for its audio. Started on the first sentence; stopped after five
/// minutes with nothing to say, or with the app.
@MainActor
final class ChatterboxSpeaker: SentenceSpeaker {
    static let idleTimeout: TimeInterval = 300

    var onIdle: (() -> Void)?
    /// The runner failed: why, for the user.
    var onFailure: ((String) -> Void)?

    private var process: DuplexProcess?
    private var audio: VoiceAudioEngine?
    private var output: EngineSpeechOutput?
    private var clip: String?
    private var nextID = 0
    /// Sentences sent and not yet played, by id.
    private var outstanding: Set<Int> = []
    /// Audio chunks scheduled and not yet played.
    private var playing = 0
    private var ended = false
    /// Bumped by stop: chunks and frames from before it are dropped.
    private var generation = 0
    /// The id whose audio the S frames carry now.
    private var current: Int?
    private var idleTimer: Timer?
    private var stderrTail = ""

    init(clip: String?) { self.clip = clip }

    var isRunning: Bool { process != nil }

    func setClip(_ path: String?) {
        clip = path
        send(VoiceFrame(.voice, payload: Self.json(["clip": path as Any])))
    }

    func enqueue(_ sentence: String, language: String) {
        idleTimer?.invalidate()
        ended = false
        if process == nil { launch() }
        nextID += 1
        outstanding.insert(nextID)
        send(VoiceFrame(.speak, payload: Self.json(["id": nextID, "text": sentence, "lang": language])))
    }

    func endOfInput() {
        ended = true
        checkIdle()
    }

    func stop() {
        generation += 1
        outstanding = []
        playing = 0
        current = nil
        ended = false
        output?.reset()
        send(VoiceFrame(.cancelReply))
        scheduleQuit()
    }

    // MARK: Runner

    private func launch() {
        let child = DuplexProcess(executable: AudioRuntime.venvPython, arguments: [
            RuntimePaths.runtimeDir + "/llmtray_tts_runner.py",
            "--model", SpokenVoiceStore.path(.model),
            "--s3tokenizer", SpokenVoiceStore.path(.tokenizer),
            "--stress", SpokenVoiceStore.path(.russianStress),
        ], environment: [
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONUNBUFFERED": "1",
            "HF_HUB_OFFLINE": "1",
            "TOKENIZERS_PARALLELISM": "false",
            OrphanScan.speechRunnerMarker: "1",
        ])
        let reader = SpeechFrameReader()
        do {
            try child.start(onStdout: { [weak self] data in
                let frames = (try? reader.append(data)) ?? []
                DispatchQueue.main.async { MainActor.assumeIsolated { frames.forEach { self?.handle($0) } } }
            }, onStderr: { [weak self] data in
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.keepStderr(text) } }
            }, onExit: { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited() } }
            })
        } catch {
            return fail(String(format: NSLocalizedString("Couldn't start the voice: %@", comment: "spoken answers"), error.localizedDescription))
        }
        process = child
        if let clip { setClip(clip) }
    }

    private func send(_ frame: VoiceFrame) {
        _ = process?.write(frame.encoded)
    }

    private func handle(_ frame: VoiceFrame) {
        switch frame.kind {
        case .ready:
            let rate = (Self.object(frame.payload)?["sample_rate"] as? Int) ?? 24000
            startAudio(sampleRate: rate)
        case .begin:
            let id = Self.object(frame.payload)?["id"] as? Int
            current = id.flatMap { outstanding.contains($0) ? $0 : nil }
        case .speech:
            guard current != nil, let output else { return }
            let samples = PCM16.samples(from: frame.payload)
            let scheduled = generation
            playing += 1
            output.schedule(samples) { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.played(generation: scheduled) } }
            }
        case .replyDone:
            if let id = Self.object(frame.payload)?["id"] as? Int { outstanding.remove(id) }
            current = nil
            checkIdle()
        case .error:
            let info = Self.object(frame.payload)
            let message = info?["message"] as? String ?? frame.text
            if let id = info?["id"] as? Int {
                outstanding.remove(id)
                NSLog("LLMTray: spoken answer sentence failed: %@", message)
                checkIdle()
            } else {
                fail(String(format: NSLocalizedString("The voice failed: %@", comment: "spoken answers"), message))
            }
        case .log:
            NSLog("LLMTray tts runner: %@", frame.text)
        default:
            break
        }
    }

    private func startAudio(sampleRate: Int) {
        guard output == nil else { return }
        let audio = VoiceAudioEngine()
        guard let output = EngineSpeechOutput(audio: audio, sampleRate: sampleRate) else {
            return fail(NSLocalizedString("The voice couldn't open the audio output.", comment: "spoken answers"))
        }
        do {
            try audio.start()
            output.play()
        } catch {
            return fail(String(format: NSLocalizedString("The voice couldn't open the audio output: %@", comment: "spoken answers"),
                               error.localizedDescription))
        }
        self.audio = audio
        self.output = output
    }

    private func played(generation scheduled: Int) {
        guard scheduled == generation else { return }
        playing = max(0, playing - 1)
        checkIdle()
    }

    private func checkIdle() {
        guard ended, outstanding.isEmpty, playing == 0 else { return }
        ended = false
        onIdle?()
        scheduleQuit()
    }

    private func scheduleQuit() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.quit() }
        }
    }

    private func quit() {
        guard outstanding.isEmpty, playing == 0 else { return }
        send(VoiceFrame(.quit))
        process?.closeStdin()
        process = nil
        output?.stop()
        audio?.stop()
        output = nil
        audio = nil
    }

    private func keepStderr(_ text: String) {
        stderrTail = String((stderrTail + text).suffix(2000))
    }

    private func exited() {
        guard process != nil else { return }   // quit on purpose
        process = nil
        output?.stop()
        audio?.stop()
        output = nil
        audio = nil
        if !outstanding.isEmpty {
            let last = stderrTail.split(separator: "\n").last.map(String.init) ?? ""
            fail(String(format: NSLocalizedString("The voice stopped: %@", comment: "spoken answers"), last))
        }
    }

    private func fail(_ message: String) {
        NSLog("LLMTray: %@", message)
        outstanding = []
        playing = 0
        process?.kill()
        process = nil
        onFailure?(message)
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// The stdout reader's decoder, used from that one thread only.
private final class SpeechFrameReader: @unchecked Sendable {
    private var decoder = VoiceFrameDecoder()
    func append(_ data: Data) throws -> [VoiceFrame] { try decoder.append(data) }
}
