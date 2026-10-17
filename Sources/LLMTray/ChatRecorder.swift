import AVFoundation
import Foundation
import LLMTrayCore

/// The composer's microphone (adr/0023): a spoken message for a model that
/// hears. Voice Lab's capture (16 kHz mono, in memory, through voice
/// processing where it starts), collected until Stop and handed back as a
/// WAV -- nothing written to disk, a temporary chat included. At most
/// `maxSeconds`; it stops itself there.
@MainActor
final class ChatRecorder: ObservableObject {
    static let sampleRate = 16_000
    /// The server takes 30 s a clip (Gemma 4's extractor).
    static let maxSeconds = 30.0

    @Published private(set) var isRecording = false
    /// Asking for the microphone: a second click waits, a cancel (another
    /// model, a closed tab) ends it before it starts.
    @Published private(set) var isStarting = false
    private var startToken = 0
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Float = 0
    /// The last levels, for the composer's meter (newest last).
    @Published private(set) var levels: [Float] = []
    /// Held to talk: released, it sends (the composer's RecordButton).
    @Published var holdToSend = false
    /// Held, and the pointer moved off the button: released, it's dropped.
    @Published var holdAway = false
    /// A held recording that hit the limit: kept until the hold ends
    /// (released over the button: sent; away: dropped).
    private var heldClip: Data? { didSet { heldPending = heldClip != nil } }
    /// A held clip waits for the release (the bar stays up for it).
    @Published private(set) var heldPending = false

    func takeHeldClip() -> Data? {
        defer { heldClip = nil }
        return heldClip
    }
    /// Why it couldn't start (no permission, no microphone).
    @Published var problem: String?

    private var audio: VoiceAudioEngine?
    private var capture: VoiceMicrophone?
    /// This recording's: a late frame from the last one lands in its own.
    private var buffer = Buffer()
    /// Called with the WAV when it stops by itself at the limit.
    var onLimit: ((Data) -> Void)?

    /// Collected on the audio thread, read on the main one.
    final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        func take() -> Data { lock.lock(); defer { data = Data(); lock.unlock() }; return data }
        var count: Int { lock.lock(); defer { lock.unlock() }; return data.count }
    }

    func start() async {
        guard !isRecording, !isStarting else { return }
        problem = nil
        isStarting = true
        let token = startToken
        let allowed = await Self.microphoneAllowed()
        isStarting = false
        // Cancelled while asked: not started behind the user's back.
        guard token == startToken else { return }
        guard allowed else {
            problem = NSLocalizedString("LLMTray isn't allowed to use the microphone. Allow it in System Settings › Privacy & Security › Microphone.", comment: "")
            return
        }
        let buffer = Buffer()
        self.buffer = buffer
        let onFrame: (Data, Float) -> Void = { [weak self] frame, rms in
            buffer.append(frame)
            let seconds = Double(buffer.count) / Double(2 * Self.sampleRate)
            Task { @MainActor [weak self] in self?.tick(seconds: seconds, level: rms, token: token) }
        }
        // Apple's voice processing first: it takes background sound (music
        // from the speakers, a fan) out of the clip, and lets the user pick
        // Voice Isolation in Control Center. The plain microphone if it
        // can't start on this Mac.
        var audio: VoiceAudioEngine?
        let capture: VoiceMicrophone
        if let io = try? VoiceProcessingIO(inputSampleRate: Self.sampleRate), (try? io.start(onFrame: onFrame)) != nil {
            capture = io
        } else {
            let engine = VoiceAudioEngine()
            let plain = MicrophoneCapture(audio: engine, sampleRate: Self.sampleRate)
            do {
                try plain.start(onFrame: onFrame)
                try engine.start()
            } catch {
                plain.stop()
                problem = error.localizedDescription
                return
            }
            audio = engine
            capture = plain
        }
        self.audio = audio
        self.capture = capture
        seconds = 0
        levels = []
        isRecording = true
    }

    /// The recording as a WAV; nil when there was nothing (under 0.3 s).
    func stop() -> Data? {
        startToken += 1
        holdToSend = false
        holdAway = false
        guard isRecording else { return nil }
        capture?.stop()
        audio?.stop()
        capture = nil
        audio = nil
        isRecording = false
        level = 0
        // Never past the server's limit (a last frame can overshoot it).
        let pcm = buffer.take().prefix(Int(Self.maxSeconds) * Self.sampleRate * 2)
        guard pcm.count >= Self.sampleRate * 2 * 3 / 10 else { return nil }
        return WAVFile.pcm16(pcm, sampleRate: Self.sampleRate)
    }

    func cancel() {
        _ = stop()
        heldClip = nil
    }

    private func tick(seconds: Double, level: Float, token: Int) {
        guard isRecording, token == startToken else { return }
        self.seconds = seconds
        self.level = level
        levels.append(level)
        if levels.count > 400 { levels.removeFirst(levels.count - 400) }
        if seconds >= Self.maxSeconds {
            let held = holdToSend
            if let wav = stop() {
                if held { heldClip = wav } else { onLimit?(wav) }
            }
        }
    }

    /// Asked the first time it's used, not at launch.
    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
