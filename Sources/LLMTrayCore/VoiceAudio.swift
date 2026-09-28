import Foundation

/// Voice Lab's sample conversions (adr/0016): the microphone's float32 to
/// the runner's int16 PCM, and back for the model's speech. Little-endian,
/// as the runner's numpy reads and writes it.
public enum PCM16 {
    /// Clamped to -1...1, then scaled by 32767 (so 1.0 and -1.0 map to
    /// ±32767; -32768 is never produced).
    public static func data<C: Collection>(from samples: C) -> Data where C.Element == Float {
        var out = Data(count: samples.count * 2)
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for (i, s) in samples.enumerated() {
                let v = s.isNaN ? 0 : min(max(s, -1), 1)
                p[i] = Int16((v * 32767).rounded()).littleEndian
            }
        }
        return out
    }

    /// int16 little-endian to float32 in -1...1 (divided by 32768); an odd
    /// trailing byte is dropped.
    public static func samples(from data: Data) -> [Float] {
        let n = data.count / 2
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let lo = UInt16(raw[2 * i]), hi = UInt16(raw[2 * i + 1])
                out[i] = Float(Int16(bitPattern: lo | hi << 8)) / 32768
            }
        }
        return out
    }

    /// Root mean square, 0...1.
    public static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// A level meter's 0...1: the RMS on a -60...0 dBFS scale.
    public static func meterLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(max((db + 60) / 60, 0), 1)
    }
}

/// When to start playing the model's speech, and what to hand the player:
/// chunks are held until `prebufferSamples` are queued (160 ms by default),
/// so the runner's 80 ms steps arriving a little late don't click; once
/// playing, each chunk is scheduled at once. When everything scheduled has
/// played (an underrun: the runner fell behind), it buffers again.
public struct JitterBuffer: Sendable {
    /// Changeable between replies (walkie-talkie holds ~3 s: the model makes
    /// its reply slower than it plays).
    public var prebufferSamples: Int {
        didSet { prebufferSamples = max(1, prebufferSamples) }
    }
    /// Scheduled on the player and not yet played.
    public private(set) var scheduledSamples = 0
    /// Held back until the prebuffer fills.
    public private(set) var heldSamples = 0
    public private(set) var isPlaying = false
    /// Underruns since the start, for the log.
    public private(set) var underruns = 0
    private var held: [[Float]] = []

    public init(prebufferSamples: Int) {
        self.prebufferSamples = max(1, prebufferSamples)
    }

    /// `milliseconds` of prebuffer at `sampleRate`.
    public init(sampleRate: Int, milliseconds: Int = 160) {
        self.init(prebufferSamples: sampleRate * milliseconds / 1000)
    }

    /// New speech from the runner; returns the chunks to schedule now, in order.
    public mutating func push(_ samples: [Float]) -> [[Float]] {
        guard !samples.isEmpty else { return [] }
        if isPlaying {
            scheduledSamples += samples.count
            return [samples]
        }
        held.append(samples)
        heldSamples += samples.count
        guard heldSamples >= prebufferSamples else { return [] }
        isPlaying = true
        let out = held
        scheduledSamples += heldSamples
        held = []
        heldSamples = 0
        return out
    }

    /// Starts playing what's held even below the prebuffer (a walkie-talkie
    /// reply is complete: nothing more is coming to fill it).
    public mutating func flush() -> [[Float]] {
        guard !held.isEmpty else { return [] }
        isPlaying = true
        let out = held
        scheduledSamples += heldSamples
        held = []
        heldSamples = 0
        return out
    }

    /// A scheduled chunk of `count` samples finished playing.
    public mutating func played(_ count: Int) {
        scheduledSamples = max(0, scheduledSamples - count)
        if isPlaying, scheduledSamples == 0 {
            isPlaying = false
            underruns += 1
        }
    }

    /// Everything dropped (stop, barge-in).
    public mutating func reset() {
        held = []
        heldSamples = 0
        scheduledSamples = 0
        isPlaying = false
    }
}

/// A walkie-talkie reply's leading silence (the model's thinking, the
/// codec's warm-up), dropped before it's played: chunks are admitted from
/// the first one at least `threshold` loud.
public struct LeadingSilenceTrim: Sendable {
    public var threshold: Float
    public private(set) var started = false

    public init(threshold: Float = 0.001) {
        self.threshold = threshold
    }

    public mutating func admit(rms: Float) -> Bool {
        if !started, rms >= threshold { started = true }
        return started
    }

    public mutating func reset() { started = false }
}

/// The Voice Lab transcript: a paragraph per turn, "You:" or "Model:",
/// deltas appended to the turn they belong to.
public struct VoiceTranscript: Equatable, Sendable {
    public enum Speaker: Equatable, Sendable { case user, model }

    public private(set) var text = ""
    private var last: Speaker?
    private let userLabel: String
    private let modelLabel: String

    public init(userLabel: String = "You:", modelLabel: String = "Model:") {
        self.userLabel = userLabel
        self.modelLabel = modelLabel
    }

    public mutating func append(_ delta: String, from speaker: Speaker) {
        guard !delta.isEmpty else { return }
        if speaker != last {
            // Nothing but blanks yet: no turn to start.
            let body = delta.drop { $0.isWhitespace }
            guard !body.isEmpty else { return }
            if !text.isEmpty { text += "\n\n" }
            text += (speaker == .user ? userLabel : modelLabel) + " " + body
            last = speaker
        } else {
            text += delta
        }
    }

    /// The next delta starts a new turn even from the same speaker (a
    /// walkie-talkie turn ended).
    public mutating func endTurn() { last = nil }
}

/// "Speaking…" vs "Listening…" in the Voice Lab window: the model sends
/// audio every 80 ms whether it talks or not (silence in between), so it's
/// speaking while what it plays is louder than `threshold`, and for `hold`
/// seconds after (no flicker between words).
public struct SpeechActivity: Sendable {
    public var threshold: Float
    public var hold: TimeInterval
    private var lastVoiced: TimeInterval?

    public init(threshold: Float = 0.01, hold: TimeInterval = 0.4) {
        self.threshold = threshold
        self.hold = hold
    }

    /// A played chunk's RMS at time `now` (seconds, any monotonic clock).
    public mutating func observe(rms: Float, at now: TimeInterval) {
        if rms >= threshold { lastVoiced = now }
    }

    public func isSpeaking(at now: TimeInterval) -> Bool {
        guard let lastVoiced else { return false }
        return now - lastVoiced <= hold
    }

    public mutating func reset() { lastVoiced = nil }
}
