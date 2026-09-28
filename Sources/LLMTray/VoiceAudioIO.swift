import AVFoundation
import Foundation
import LLMTrayCore

/// The microphone for Voice Lab (adr/0016): an AVAudioEngine input tap,
/// converted to 16 kHz mono float32 and handed on as int16 PCM. Nothing is
/// written to disk. `onFrame` runs on the audio thread -- it must not block
/// (DuplexProcess.write doesn't).
final class MicrophoneCapture {
    enum CaptureError: LocalizedError {
        case noInput
        case converter

        var errorDescription: String? {
            switch self {
            case .noInput: return NSLocalizedString("No microphone is available.", comment: "")
            case .converter: return NSLocalizedString("The microphone's audio format isn't supported.", comment: "")
            }
        }
    }

    private let engine = AVAudioEngine()
    private let sampleRate: Double

    init(sampleRate: Int = 16_000) {
        self.sampleRate = Double(sampleRate)
    }

    /// `onFrame`: int16 PCM at `sampleRate`, mono, and the chunk's RMS.
    func start(onFrame: @escaping (Data, Float) -> Void) throws {
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw CaptureError.noInput }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: hardware, to: target) else { throw CaptureError.converter }
        let ratio = sampleRate / hardware.sampleRate
        // ~100 ms per tap at 48 kHz; the runner takes any chunk size.
        input.installTap(onBus: 0, bufferSize: 4096, format: hardware) { buffer, _ in
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if fed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
            let samples = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
            onFrame(PCM16.data(from: samples), PCM16.rms(samples))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Plays the model's speech as it streams in (adr/0016: in the app, so a
/// stop cuts it at once), through a small jitter buffer (JitterBuffer,
/// 160 ms). `enqueue` may be called from any thread.
final class SpeechPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var jitter: JitterBuffer
    private var activity = SpeechActivity()
    private var stopped = false
    private let clockStart = DispatchTime.now().uptimeNanoseconds

    init?(sampleRate: Int, prebufferMilliseconds: Int = 160) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)
        else { return nil }
        self.format = format
        jitter = JitterBuffer(sampleRate: sampleRate, milliseconds: prebufferMilliseconds)
    }

    func start() throws {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.play()
    }

    private var now: TimeInterval { Double(DispatchTime.now().uptimeNanoseconds - clockStart) / 1e9 }

    /// The model is audibly speaking now (or was within the last 0.4 s).
    var isSpeaking: Bool {
        lock.lock(); defer { lock.unlock() }
        return activity.isSpeaking(at: now)
    }

    var underruns: Int {
        lock.lock(); defer { lock.unlock() }
        return jitter.underruns
    }

    func enqueue(_ samples: [Float]) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let chunks = jitter.push(samples)
        lock.unlock()
        for chunk in chunks { schedule(chunk) }
    }

    private func schedule(_ samples: [Float]) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        let rms = PCM16.rms(samples)
        let count = samples.count
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.jitter.played(count)
            self.activity.observe(rms: rms, at: self.now)
            self.lock.unlock()
        }
    }

    /// How much is held before playing starts (or starts again after an underrun).
    func setPrebuffer(milliseconds: Int) {
        lock.lock()
        jitter.prebufferSamples = Int(format.sampleRate) * milliseconds / 1000
        lock.unlock()
    }

    /// Starts what's held even below the prebuffer: a complete reply.
    func flush() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let chunks = jitter.flush()
        lock.unlock()
        for chunk in chunks { schedule(chunk) }
    }

    /// Drops whatever is queued or playing (the user talks over it); the
    /// player stays ready for the next.
    func cancelPlayback() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        jitter.reset()
        activity.reset()
        lock.unlock()
        player.stop()
        player.play()
    }

    func stop() {
        lock.lock()
        stopped = true
        jitter.reset()
        activity.reset()
        lock.unlock()
        player.stop()
        engine.stop()
    }
}
