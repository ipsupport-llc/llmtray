import AVFoundation
import Foundation
import LLMTrayCore

/// The composer's microphone (adr/0023): a spoken message for a model that
/// hears. Voice Lab's capture (16 kHz mono, in memory), collected until
/// Stop and handed back as a WAV -- nothing written to disk, a temporary
/// chat included. At most `maxSeconds`; it stops itself there.
@MainActor
final class ChatRecorder: ObservableObject {
    static let sampleRate = 16_000
    /// The server takes 30 s a clip (Gemma 4's extractor).
    static let maxSeconds = 30.0

    @Published private(set) var isRecording = false
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Float = 0
    /// Why it couldn't start (no permission, no microphone).
    @Published var problem: String?

    private var audio: VoiceAudioEngine?
    private var capture: MicrophoneCapture?
    private let buffer = Buffer()
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
        guard !isRecording else { return }
        problem = nil
        guard await Self.microphoneAllowed() else {
            problem = NSLocalizedString("LLMTray isn't allowed to use the microphone. Allow it in System Settings › Privacy & Security › Microphone.", comment: "")
            return
        }
        let audio = VoiceAudioEngine()
        let capture = MicrophoneCapture(audio: audio, sampleRate: Self.sampleRate)
        _ = buffer.take()
        do {
            let buffer = self.buffer
            try capture.start { [weak self] frame, rms in
                buffer.append(frame)
                let seconds = Double(buffer.count) / Double(2 * Self.sampleRate)
                Task { @MainActor [weak self] in self?.tick(seconds: seconds, level: rms) }
            }
            try audio.start()
        } catch {
            capture.stop()
            problem = error.localizedDescription
            return
        }
        self.audio = audio
        self.capture = capture
        seconds = 0
        isRecording = true
    }

    /// The recording as a WAV; nil when there was nothing (under 0.3 s).
    func stop() -> Data? {
        guard isRecording else { return nil }
        capture?.stop()
        audio?.stop()
        capture = nil
        audio = nil
        isRecording = false
        level = 0
        let pcm = buffer.take()
        guard pcm.count >= Self.sampleRate * 2 * 3 / 10 else { return nil }
        return WAVFile.pcm16(pcm, sampleRate: Self.sampleRate)
    }

    func cancel() {
        _ = stop()
    }

    private func tick(seconds: Double, level: Float) {
        guard isRecording else { return }
        self.seconds = seconds
        self.level = level
        if seconds >= Self.maxSeconds, let wav = stop() { onLimit?(wav) }
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
