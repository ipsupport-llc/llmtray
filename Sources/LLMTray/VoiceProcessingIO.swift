import AudioToolbox
import AVFoundation
import Foundation
import LLMTrayCore
import os

/// Voice Lab's audio with echo cancellation: Apple's voice-processing I/O
/// unit (what FaceTime uses) plays the model's speech and records the
/// microphone, and takes what it played out of what it records -- the
/// model doesn't hear itself from the speakers. Other apps' audio isn't
/// ducked.
///
/// The raw AudioUnit rather than AVAudioEngine's voice processing: on some
/// Macs (a MacBook Air with its built-in mic and speakers, macOS 27) the
/// engine's output node fails to initialize with it (-10875), while the
/// unit itself works.
///
/// Its I/O runs at 48 kHz mono float32. The audio threads only copy into
/// or out of preallocated rings under a try-lock (silence or a dropped
/// mic chunk if it's busy) -- no allocation, no waiting. A 10 ms timer off
/// those threads resamples the microphone to `inputSampleRate`, hands it
/// on, and runs the completions of played speech.
final class VoiceProcessingIO: VoiceMicrophone, @unchecked Sendable {
    enum VPIOError: LocalizedError {
        case unavailable
        case status(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .unavailable: return NSLocalizedString("Echo cancellation isn't available on this Mac.", comment: "")
            case .status(let call, let status): return "\(call): \(status)"
            }
        }
    }

    static let ioRate = 48_000.0
    private static let maxFrames = 8192

    private var unit: AudioUnit?
    private let inputSampleRate: Double
    private let ioFormat: AVAudioFormat
    private let micFormat: AVAudioFormat
    private let micConverter: AVAudioConverter
    private let queue = DispatchQueue(label: "llmtray.voice.io")
    private var timer: DispatchSourceTimer?
    private var onFrame: ((Data, Float) -> Void)?   // on `queue`
    private let micScratch: UnsafeMutablePointer<Float>

    // Guarded by `lock`; the audio threads only try it.
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let speech = FloatRing(capacity: Int(ioRate) * 120)
    private let mic = FloatRing(capacity: Int(ioRate) * 4)
    /// Speech chunks queued, by the ring position they end at.
    private var pending: [(end: Int, completion: () -> Void)] = []

    init(inputSampleRate: Int) throws {
        self.inputSampleRate = Double(inputSampleRate)
        guard let io = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.ioRate, channels: 1, interleaved: false),
              let micFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(inputSampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: io, to: micFormat)
        else { throw VPIOError.unavailable }
        ioFormat = io
        self.micFormat = micFormat
        micConverter = converter
        micScratch = .allocate(capacity: Self.maxFrames)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw VPIOError.unavailable }
        var created: AudioUnit?
        try Self.check("AudioComponentInstanceNew", AudioComponentInstanceNew(component, &created))
        guard let unit = created else { throw VPIOError.unavailable }
        self.unit = unit
        do {
            var one: UInt32 = 1
            try Self.check("EnableIO", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4))
            var ducking = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min)
            try Self.check("Ducking", AudioUnitSetProperty(unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0,
                                                           &ducking, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)))
            var format = AudioStreamBasicDescription(mSampleRate: Self.ioRate, mFormatID: kAudioFormatLinearPCM,
                                                     mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                     mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                     mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
            let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check("Speaker format", AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, size))
            try Self.check("Mic format", AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, size))
            // Unretained: the unit is stopped and disposed in deinit, before
            // `self` goes, and AudioOutputUnitStop waits for the callbacks.
            let context = Unmanaged.passUnretained(self).toOpaque()
            var render = AURenderCallbackStruct(inputProc: { context, _, _, _, frames, data in
                Unmanaged<VoiceProcessingIO>.fromOpaque(context).takeUnretainedValue().render(frames: Int(frames), into: data)
            }, inputProcRefCon: context)
            try Self.check("Render callback", AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                                                   &render, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            var input = AURenderCallbackStruct(inputProc: { context, flags, time, _, frames, _ in
                Unmanaged<VoiceProcessingIO>.fromOpaque(context).takeUnretainedValue().capture(flags: flags, time: time, frames: frames)
            }, inputProcRefCon: context)
            try Self.check("Input callback", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                                                  &input, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try Self.check("AudioUnitInitialize", AudioUnitInitialize(unit))
        } catch {
            AudioComponentInstanceDispose(unit)
            self.unit = nil
            throw error
        }
    }

    deinit {
        timer?.cancel()
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        micScratch.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    private static func check(_ call: String, _ status: OSStatus) throws {
        if status != noErr { throw VPIOError.status(call, status) }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }

    // MARK: VoiceMicrophone

    func start(onFrame: @escaping (Data, Float) -> Void) throws {
        guard let unit else { throw VPIOError.unavailable }
        queue.sync { self.onFrame = onFrame }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        do {
            try Self.check("AudioOutputUnitStart", AudioOutputUnitStart(unit))
        } catch {
            timer.cancel()
            self.timer = nil
            throw error
        }
    }

    func stop() {
        if let unit { AudioOutputUnitStop(unit) }
        timer?.cancel()
        timer = nil
        queue.sync { onFrame = nil }
        dropSpeech()
    }

    /// The model's speech at `sampleRate`, played through this unit.
    func speechOutput(sampleRate: Int) -> SpeechOutput? {
        VPIOSpeechOutput(io: self, sampleRate: Double(sampleRate))
    }

    // MARK: Audio threads: copy only, never wait

    private func render(frames: Int, into data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let data, let out = UnsafeMutableAudioBufferListPointer(data).first?.mData?.assumingMemoryBound(to: Float.self)
        else { return noErr }
        var played = 0
        if os_unfair_lock_trylock(lock) {
            played = speech.read(into: out, count: frames)
            os_unfair_lock_unlock(lock)
        }
        if played < frames { (out + played).update(repeating: 0, count: frames - played) }
        return noErr
    }

    private func capture(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, time: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard let unit, Int(frames) <= Self.maxFrames else { return noErr }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4,
                                                                            mData: UnsafeMutableRawPointer(micScratch)))
        let status = AudioUnitRender(unit, flags, time, 1, frames, &list)
        guard status == noErr else { return status }
        if os_unfair_lock_trylock(lock) {
            _ = mic.write(UnsafeBufferPointer(start: micScratch, count: Int(frames)))
            os_unfair_lock_unlock(lock)
        }
        return noErr
    }

    // MARK: Off the audio threads

    /// On `queue`, every 10 ms.
    private func tick() {
        var samples: [Float] = []
        var done: [() -> Void] = []
        withLock {
            if mic.available > 0 {
                samples = [Float](repeating: 0, count: mic.available)
                samples.withUnsafeMutableBufferPointer { _ = mic.read(into: $0.baseAddress!, count: $0.count) }
            }
            let position = speech.readPosition
            while let first = pending.first, first.end <= position { done.append(pending.removeFirst().completion) }
        }
        done.forEach { $0() }
        if !samples.isEmpty { deliver(samples) }
    }

    private func deliver(_ samples: [Float]) {
        guard let onFrame,
              let input = AVAudioPCMBuffer(pcmFormat: ioFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = AVAudioPCMBuffer(pcmFormat: micFormat,
                                         frameCapacity: AVAudioFrameCount((Double(samples.count) * inputSampleRate / Self.ioRate).rounded(.up)) + 32)
        else { return }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var fed = false
        var error: NSError?
        let status = micConverter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
        let converted = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        onFrame(PCM16.data(from: converted), PCM16.rms(converted))
    }

    /// Queues speech at ioRate; false (nothing queued) if the ring is full.
    fileprivate func enqueue(_ samples: UnsafeBufferPointer<Float>, completion: @escaping () -> Void) -> Bool {
        withLock {
            guard speech.free >= samples.count else { return false }
            _ = speech.write(samples)
            pending.append((speech.writePosition, completion))
            return true
        }
    }

    /// Drops the speech not played yet (its completions still run).
    fileprivate func dropSpeech() {
        let dropped: [() -> Void] = withLock {
            speech.clear()
            defer { pending.removeAll() }
            return pending.map(\.completion)
        }
        dropped.forEach { $0() }
    }
}

/// Samples in a preallocated ring; positions count every sample ever
/// written or read. The caller serializes access.
private final class FloatRing {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private(set) var writePosition = 0
    private(set) var readPosition = 0

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
    }

    deinit { storage.deallocate() }

    var available: Int { writePosition - readPosition }
    var free: Int { capacity - available }

    func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        let count = min(samples.count, free)
        for i in 0..<count { storage[(writePosition + i) % capacity] = samples[i] }
        writePosition += count
        return count
    }

    func read(into out: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let n = min(count, available)
        for i in 0..<n { out[i] = storage[(readPosition + i) % capacity] }
        readPosition += n
        return n
    }

    func clear() { readPosition = writePosition }
}

/// The model's speech into a VoiceProcessingIO, resampled to its 48 kHz.
/// Converting and queueing are one step under `lock`, as is a reset, so a
/// cancelled reply's chunk can't slip in after it.
private final class VPIOSpeechOutput: SpeechOutput {
    private weak var io: VoiceProcessingIO?
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let lock = NSLock()

    init?(io: VoiceProcessingIO, sampleRate: Double) {
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VoiceProcessingIO.ioRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { return nil }
        self.io = io
        self.inFormat = inFormat
        self.outFormat = outFormat
        self.converter = converter
    }

    func schedule(_ samples: [Float], completion: @escaping () -> Void) {
        guard let io, !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = AVAudioPCMBuffer(pcmFormat: outFormat,
                                         frameCapacity: AVAudioFrameCount((Double(samples.count) * outFormat.sampleRate / inFormat.sampleRate).rounded(.up)) + 64)
        else { return completion() }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        lock.lock()
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        let queued = status != .error && out.frameLength > 0 && out.floatChannelData != nil
            && io.enqueue(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)), completion: completion)
        lock.unlock()
        if !queued { completion() }
    }

    func reset() {
        lock.lock()
        io?.dropSpeech()
        converter.reset()
        lock.unlock()
    }

    func stop() {
        lock.lock()
        io?.dropSpeech()
        lock.unlock()
    }
}
