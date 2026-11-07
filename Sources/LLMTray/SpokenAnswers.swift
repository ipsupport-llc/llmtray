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
    /// A streaming message the user stopped (or talked over with Speak):
    /// its later deltas aren't read.
    private var silenced: UUID?
    private var answerLanguage: String?

    // Voice conversation (adr/0031)
    /// Every answer is read as it streams, whatever `readsAloud` says, and
    /// the voice runner stays warm.
    var voiceMode = false {
        didSet { chatterbox?.keepWarm = voiceMode }
    }
    /// Where the answers play: the voice-processing unit, so echo
    /// cancellation hears them. nil: each voice's own output.
    var audioSink: VoiceProcessingIO? {
        didSet {
            system?.audioSink = audioSink
            chatterbox?.audioSink = audioSink
        }
    }
    /// A sentence finished playing (what the user heard).
    var onSentencePlayed: ((String) -> Void)?

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
        guard readsAloud || voiceMode, messageID != silenced else { return }
        if streamClient != client {
            // Another chat streaming at the same time waits its turn: the
            // answer being streamed and read keeps the voice.
            if streamClient != nil, stream != nil { return }
            stop()
            streamClient = client
        }
        if streamMessage != messageID {
            // The next message of this turn (after a tool call): the last
            // one's rest is read first, in order.
            finishStream()
            streamMessage = messageID
            stream = SentenceStream(codeBlock: Self.codeBlockPhrase, eagerFirst: voiceMode)
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
        if let streamMessage { silenced = streamMessage }
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
                c.onFailure = { [weak self, weak c] message, unspoken in
                    // After Stop (or another answer) it's no news.
                    guard let self, let c, self.active === c else { return }
                    self.note = message
                    // Never silence: the system voice reads what's left.
                    let s = self.makeSystem()
                    s.onIdle = { [weak self] in self?.idle(s) }
                    self.active = s
                    for (text, lang) in unspoken { s.enqueue(text, language: lang) }
                    if self.stream == nil { s.endOfInput() }
                }
                return c
            }
        }
        let s = makeSystem()
        s.onIdle = { [weak self] in self?.idle(s) }
        return s
    }

    private func makeChatterbox() -> ChatterboxSpeaker {
        let c = ChatterboxSpeaker(clip: clipPath)
        c.onIdle = { [weak self, weak c] in if let c { self?.idle(c) } }
        c.onPlayed = { [weak self] text in self?.onSentencePlayed?(text) }
        c.audioSink = audioSink
        c.keepWarm = voiceMode
        chatterbox = c
        return c
    }

    private func makeSystem() -> SystemSpeaker {
        if let system { return system }
        let s = SystemSpeaker()
        s.onPlayed = { [weak self] text in self?.onSentencePlayed?(text) }
        s.audioSink = audioSink
        system = s
        return s
    }

    /// Which voice a filler is made with, for the filler cache's key: the
    /// same choice `speaker(for:)` makes.
    func fillerVoiceKey(language: String) -> String {
        if voiceKind == .chatterbox, SpokenVoiceStore.isReady, SpeechLanguage.chatterbox.contains(language) {
            let clip = clipPath.map { ($0 as NSString).lastPathComponent } ?? "builtin"
            return "chatterbox-\(SpokenVoiceFile.model.repo.replacingOccurrences(of: "/", with: "_"))-\(clip)"
        }
        return "system-" + (SystemSpeaker.voice(for: language)?.identifier ?? language)
    }

    /// A filler's audio, made with the answers' voice without playing it
    /// (adr/0031: made in the silences, cached by the caller).
    func renderFiller(_ text: String, language: String) async -> (samples: [Float], rate: Int)? {
        if voiceKind == .chatterbox, SpokenVoiceStore.isReady, SpeechLanguage.chatterbox.contains(language) {
            let c = chatterbox ?? makeChatterbox()
            return await c.render(text, language: language)
        }
        return await SystemSpeaker.render(text, language: language)
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
    /// A sentence finished playing.
    var onPlayed: ((String) -> Void)? { get set }
    /// Plays through this unit when set (voice conversation).
    var audioSink: VoiceProcessingIO? { get set }
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
    var onPlayed: ((String) -> Void)?
    /// Voice conversation: sentences are rendered to buffers
    /// (AVSpeechSynthesizer.write) and played through this unit, so echo
    /// cancellation hears them; speak() would bypass it.
    var audioSink: VoiceProcessingIO? {
        didSet { if audioSink !== oldValue { outputs = [:] } }
    }
    /// What spoke() is saying, in order (the delegate path).
    private var spoken: [String] = []
    // The buffered path.
    private var waiting: [(id: Int, utterance: AVSpeechUtterance, text: String)] = []
    private var writing = false
    private var nextID = 0
    private var chunks: [Int: Int] = [:]
    private var made: Set<Int> = []
    private var texts: [Int: String] = [:]
    private var generation = 0
    private var outputs: [Double: SpeechOutput] = [:]

    override init() {
        super.init()
        synth.delegate = self
    }

    func enqueue(_ sentence: String, language: String) {
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = Self.voice(for: language)
        queued += 1
        ended = false
        if audioSink != nil {
            nextID += 1
            texts[nextID] = sentence
            waiting.append((nextID, utterance, sentence))
            pump()
        } else {
            spoken.append(sentence)
            synth.speak(utterance)
        }
    }

    func endOfInput() {
        ended = true
        if queued == 0 { onIdle?() }
    }

    func stop() {
        queued = 0
        ended = false
        generation += 1
        waiting = []
        writing = false
        chunks = [:]
        made = []
        texts = [:]
        spoken = []
        synth.stopSpeaking(at: .immediate)
        outputs.values.forEach { $0.reset() }
    }

    // MARK: Buffered (through the voice-processing unit)

    private func pump() {
        guard !writing, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        writing = true
        let gen = generation
        synth.write(next.utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            let samples = Self.floats(pcm)
            let rate = pcm.format.sampleRate
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                if pcm.frameLength == 0 {
                    self.made.insert(next.id)
                    self.writing = false
                    self.checkPlayed(next.id)
                    self.pump()
                } else if let output = self.output(rate) {
                    self.chunks[next.id, default: 0] += 1
                    output.schedule(samples) { [weak self] in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.chunkPlayed(next.id, gen) } }
                    }
                }
            } }
        }
    }

    private func output(_ rate: Double) -> SpeechOutput? {
        if let o = outputs[rate] { return o }
        let o = audioSink?.speechOutput(sampleRate: Int(rate))
        outputs[rate] = o
        return o
    }

    private func chunkPlayed(_ id: Int, _ gen: Int) {
        guard gen == generation else { return }
        chunks[id] = max(0, (chunks[id] ?? 1) - 1)
        checkPlayed(id)
    }

    private func checkPlayed(_ id: Int) {
        guard made.contains(id), (chunks[id] ?? 0) == 0 else { return }
        made.remove(id)
        chunks[id] = nil
        if let text = texts.removeValue(forKey: id) { onPlayed?(text) }
        finished()
    }

    nonisolated static func floats(_ pcm: AVAudioPCMBuffer) -> [Float] {
        let n = Int(pcm.frameLength)
        guard n > 0 else { return [] }
        if let f = pcm.floatChannelData { return Array(UnsafeBufferPointer(start: f[0], count: n)) }
        if let i = pcm.int16ChannelData { return UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 32768 } }
        if let i = pcm.int32ChannelData { return UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 2_147_483_648 } }
        return []
    }

    /// A sentence's audio without playing it (a filler for the cache).
    static func render(_ text: String, language: String) async -> (samples: [Float], rate: Int)? {
        let synth = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(for: language)
        return await withCheckedContinuation { continuation in
            var samples: [Float] = []
            var rate = 22050.0
            var done = false
            synth.write(utterance) { buffer in
                guard !done, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    done = true
                    _ = synth   // kept alive until the end
                    continuation.resume(returning: samples.isEmpty ? nil : (samples, Int(rate)))
                } else {
                    rate = pcm.format.sampleRate
                    samples += floats(pcm)
                }
            }
        }
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
        MainActor.assumeIsolated {
            if !spoken.isEmpty { onPlayed?(spoken.removeFirst()) }
            finished()
        }
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
    var onPlayed: ((String) -> Void)?
    /// The runner failed: why, for the user, and the sentences it hadn't
    /// played (text, language), in order.
    var onFailure: ((String, [(String, String)]) -> Void)?
    /// Voice conversation: audio plays through this unit.
    var audioSink: VoiceProcessingIO? {
        didSet {
            guard audioSink !== oldValue else { return }
            output?.reset()
            closeAudio()
        }
    }
    /// Voice conversation: no idle quit (a cold start costs a warm-up).
    var keepWarm = false {
        didSet { if keepWarm { idleTimer?.invalidate() } else if process != nil { scheduleQuit() } }
    }

    private var process: DuplexProcess?
    private var audio: VoiceAudioEngine?
    private var output: SpeechOutput?
    private var engineOutput: EngineSpeechOutput?
    private var sampleRate = 24000
    /// Sentences made for a cache, not played: their audio, by id.
    private var renders: [Int: (samples: [Float], resume: (([Float]?) -> Void))] = [:]
    private var clip: String?
    private var nextID = 0
    /// Sentences sent and not yet played, by id.
    private var outstanding: Set<Int> = []
    /// Their text and language, for a fallback voice if this one fails:
    /// kept until the sentence has played, not just been made.
    private var texts: [Int: (String, String)] = [:]
    /// Per sentence, its audio chunks scheduled and not yet played.
    private var chunksPlaying: [Int: Int] = [:]
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
        // Recorded first: a launch that fails hands it to the fallback.
        nextID += 1
        outstanding.insert(nextID)
        texts[nextID] = (sentence, language)
        if process == nil {
            launch()
            guard process != nil else { return }
        }
        send(VoiceFrame(.speak, payload: Self.json(["id": nextID, "text": sentence, "lang": language])))
    }

    func endOfInput() {
        ended = true
        checkIdle()
    }

    /// A sentence's audio without playing it (a filler for the cache).
    func render(_ text: String, language: String) async -> (samples: [Float], rate: Int)? {
        idleTimer?.invalidate()
        if process == nil {
            launch()
            guard process != nil else { return nil }
        }
        nextID += 1
        let id = nextID
        let samples: [Float]? = await withCheckedContinuation { continuation in
            renders[id] = ([], { continuation.resume(returning: $0) })
            send(VoiceFrame(.speak, payload: Self.json(["id": id, "text": text, "lang": language])))
        }
        if outstanding.isEmpty { scheduleQuit() }
        return samples.map { ($0, sampleRate) }
    }

    func stop() {
        generation += 1
        outstanding = []
        texts = [:]
        chunksPlaying = [:]
        // A filler being made is dropped too: the runner's cancel may never
        // answer for it.
        for render in renders.values { render.resume(nil) }
        renders = [:]
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
            // Every callback names its child: an old runner's last frames
            // or its exit, arriving after a new one started, are ignored.
            try child.start(onStdout: { [weak self, weak child] data in
                let frames = (try? reader.append(data)) ?? []
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self, let child, self.process === child else { return }
                    frames.forEach { self.handle($0) }
                } }
            }, onStderr: { [weak self] data in
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.keepStderr(text) } }
            }, onExit: { [weak self, weak child] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self, let child, self.process === child else { return }
                    self.exited()
                } }
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
            sampleRate = (Self.object(frame.payload)?["sample_rate"] as? Int) ?? 24000
        case .begin:
            let id = Self.object(frame.payload)?["id"] as? Int
            current = id.flatMap { outstanding.contains($0) || renders[$0] != nil ? $0 : nil }
        case .speech:
            guard let id = current else { return }
            if renders[id] != nil {
                renders[id]?.samples += PCM16.samples(from: frame.payload)
                return
            }
            guard let output = currentOutput() else { return }
            let samples = PCM16.samples(from: frame.payload)
            let scheduled = generation
            playing += 1
            chunksPlaying[id, default: 0] += 1
            output.schedule(samples) { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.played(id: id, generation: scheduled) } }
            }
        case .replyDone:
            if let id = Self.object(frame.payload)?["id"] as? Int, let render = renders.removeValue(forKey: id) {
                render.resume(render.samples.isEmpty ? nil : render.samples)
                current = nil
                return
            }
            if let id = Self.object(frame.payload)?["id"] as? Int {
                outstanding.remove(id)
                if chunksPlaying[id, default: 0] == 0 { texts[id] = nil }   // no audio, or all played
            }
            current = nil
            checkIdle()
        case .error:
            let info = Self.object(frame.payload)
            let message = info?["message"] as? String ?? frame.text
            if let id = info?["id"] as? Int, let render = renders.removeValue(forKey: id) {
                render.resume(nil)
            } else if let id = info?["id"] as? Int {
                outstanding.remove(id)
                texts[id] = nil
                NSLog("LLMTray: spoken answer sentence failed: %@", message)
                checkIdle()
            } else if info?["fatal"] as? Bool == false {
                // A bad clip: the voice it had stays.
                NSLog("LLMTray: spoken answers: %@", message)
            } else {
                fail(String(format: NSLocalizedString("The voice failed: %@", comment: "spoken answers"), message))
            }
        case .log:
            NSLog("LLMTray tts runner: %@", frame.text)
        default:
            break
        }
    }

    /// The voice-processing unit's output in a conversation, else an
    /// engine of its own; made on the first audio.
    private func currentOutput() -> SpeechOutput? {
        if let output { return output }
        if let sink = audioSink {
            output = sink.speechOutput(sampleRate: sampleRate)
            return output
        }
        let audio = VoiceAudioEngine()
        guard let engine = EngineSpeechOutput(audio: audio, sampleRate: sampleRate) else {
            fail(NSLocalizedString("The voice couldn't open the audio output.", comment: "spoken answers"))
            return nil
        }
        do {
            try audio.start()
            engine.play()
        } catch {
            fail(String(format: NSLocalizedString("The voice couldn't open the audio output: %@", comment: "spoken answers"),
                        error.localizedDescription))
            return nil
        }
        self.audio = audio
        engineOutput = engine
        output = engine
        return engine
    }

    private func played(id: Int, generation scheduled: Int) {
        guard scheduled == generation else { return }
        playing = max(0, playing - 1)
        let left = max(0, chunksPlaying[id, default: 1] - 1)
        chunksPlaying[id] = left == 0 ? nil : left
        // Heard to the end once made and played: no fallback needs it.
        if left == 0, !outstanding.contains(id), let text = texts.removeValue(forKey: id) { onPlayed?(text.0) }
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
        guard !keepWarm else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.quit() }
        }
    }

    private func quit() {
        guard outstanding.isEmpty, playing == 0, renders.isEmpty, !keepWarm else { return }
        send(VoiceFrame(.quit))
        process?.closeStdin()
        process = nil
        closeAudio()
    }

    private func keepStderr(_ text: String) {
        stderrTail = String((stderrTail + text).suffix(2000))
    }

    private func exited() {
        process = nil
        closeAudio()
        for render in renders.values { render.resume(nil) }
        renders = [:]
        if !outstanding.isEmpty {
            let last = stderrTail.split(separator: "\n").last.map(String.init) ?? ""
            fail(String(format: NSLocalizedString("The voice stopped: %@", comment: "spoken answers"), last))
        }
    }

    private func fail(_ message: String) {
        NSLog("LLMTray: %@", message)
        // Not yet heard to the end: made or not (one cut off mid-way is
        // read again whole).
        let unspoken = texts.keys.sorted().compactMap { texts[$0] }
        texts = [:]
        for render in renders.values { render.resume(nil) }
        renders = [:]
        chunksPlaying = [:]
        generation += 1
        outstanding = []
        playing = 0
        current = nil
        ended = false
        process?.kill()
        process = nil
        closeAudio()
        onFailure?(message, unspoken)
    }

    private func closeAudio() {
        output?.stop()
        audio?.stop()
        output = nil
        engineOutput = nil
        audio = nil
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
