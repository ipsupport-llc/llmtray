import AVFoundation
import Foundation
import LLMTrayCore

/// Audio without echo cancellation: one AVAudioEngine for the microphone
/// and the model's speech.
final class VoiceAudioEngine {
    let engine = AVAudioEngine()

    /// After the microphone's tap and the player are in place.
    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
    }
}

/// Where microphone frames come from: `onFrame` gets int16 PCM at the
/// runner's rate, mono, and the chunk's RMS.
protocol VoiceMicrophone: AnyObject {
    func start(onFrame: @escaping (Data, Float) -> Void) throws
    func stop()
}

/// Where the model's speech goes: chunks at the model's rate, each
/// `completion` called once it has played (or was dropped).
protocol SpeechOutput: AnyObject {
    func schedule(_ samples: [Float], completion: @escaping () -> Void)
    /// Drops what's queued; ready for more.
    func reset()
    func stop()
}

/// The microphone without echo cancellation: an AVAudioEngine input tap,
/// converted to 16 kHz mono float32 and handed on as int16 PCM. Nothing is
/// written to disk. `onFrame` runs on the audio thread -- it must not block
/// (DuplexProcess.write doesn't).
final class MicrophoneCapture: VoiceMicrophone {
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

    private let engine: AVAudioEngine
    private let sampleRate: Double

    init(audio: VoiceAudioEngine, sampleRate: Int = 16_000) {
        engine = audio.engine
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
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
    }
}

/// The model's speech through an AVAudioPlayerNode on the shared engine.
final class EngineSpeechOutput: SpeechOutput {
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    init?(audio: VoiceAudioEngine, sampleRate: Int) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)
        else { return nil }
        engine = audio.engine
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Once the engine runs.
    func play() { player.play() }

    func schedule(_ samples: [Float], completion: @escaping () -> Void) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return completion() }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        player.scheduleBuffer(buffer, completionHandler: completion)
    }

    func reset() {
        player.stop()
        player.play()
    }

    func stop() {
        player.stop()
    }
}
