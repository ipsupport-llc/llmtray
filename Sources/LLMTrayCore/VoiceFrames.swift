import Foundation

/// One message between the app and the Voice Lab runner
/// (runtime/llmtray_voice_runner.py, adr/0016): a type byte, a 4-byte
/// big-endian payload length, the payload. Binary rather than the embed
/// runner's JSON lines, which would base64 every 80 ms of audio.
///
/// App -> runner: `A` int16 PCM, 16 kHz mono; `M` the mode ("duplex" or
/// "walkie"); `D` the user's turn ended (walkie-talkie: payload = the turn's
/// number, UTF-8); `C` cancel the reply in progress; `Q` quit.
/// Runner -> app: `R` ready (JSON), `T` the model's text delta, `U` the
/// user's transcript delta (UTF-8), `S` speech (int16 PCM at the ready
/// JSON's `sample_rate`), `Z` the reply to a `D` is complete (JSON), `N` a
/// note for the user, `E` error, `L` a log line (UTF-8).
public struct VoiceFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case audio = 0x41   // A
        case quit = 0x51    // Q
        case endOfTurn = 0x44   // D
        case mode = 0x4D        // M
        case cancelReply = 0x43 // C
        case replyDone = 0x5A   // Z
        case userText = 0x55    // U
        case note = 0x4E        // N
        case ready = 0x52   // R
        case text = 0x54    // T
        case speech = 0x53  // S
        case error = 0x45   // E
        case log = 0x4C     // L
    }

    /// The raw type byte: a type this build doesn't know is passed on (and
    /// ignored by the session), not an error.
    public var type: UInt8
    public var payload: Data

    public init(type: UInt8, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    public init(_ kind: Kind, payload: Data = Data()) {
        self.init(type: kind.rawValue, payload: payload)
    }

    public init(_ kind: Kind, text: String) {
        self.init(kind, payload: Data(text.utf8))
    }

    public var kind: Kind? { Kind(rawValue: type) }
    public var text: String { String(decoding: payload, as: UTF8.self) }

    public static let headerSize = 5

    /// The frame as it goes on the wire.
    public var encoded: Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(type)
        let n = UInt32(payload.count)
        out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        out.append(payload)
        return out
    }
}

/// The runner's `R` payload.
public struct VoiceRunnerReady: Equatable, Sendable, Decodable {
    /// Of the `S` frames' PCM (22 050 Hz for VoiceChat).
    public var sampleRate: Int
    /// What the runner expects in `A` frames (16 000 Hz).
    public var inputSampleRate: Int
    /// Samples per model step (1280 = 80 ms at 16 kHz), informational.
    public var frameSamples: Int?
    public var model: String?
    /// Real-time factor measured at warmup: compute time per second of
    /// audio (above 1: slower than real time, full duplex falls behind).
    public var rtf: Double?

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case inputSampleRate = "input_sample_rate"
        case frameSamples = "frame_samples"
        case model
        case rtf
    }

    public init(sampleRate: Int, inputSampleRate: Int, frameSamples: Int? = nil, model: String? = nil, rtf: Double? = nil) {
        self.sampleRate = sampleRate
        self.inputSampleRate = inputSampleRate
        self.frameSamples = frameSamples
        self.model = model
        self.rtf = rtf
    }

    public init?(payload: Data) {
        guard let ready = try? JSONDecoder().decode(Self.self, from: payload),
              (8_000...192_000).contains(ready.sampleRate), (8_000...192_000).contains(ready.inputSampleRate) else { return nil }
        self = ready
    }
}

/// The runner's `Z` payload: a walkie-talkie reply is complete.
public struct VoiceReplyDone: Equatable, Sendable, Decodable {
    public enum Reason: String, Sendable, Decodable {
        /// The model spoke and fell quiet.
        case done
        /// It didn't start speaking within the runner's wait.
        case noReply = "no_reply"
        /// The runner's length cap.
        case limit
        /// The user started talking again, cancelled it, or quit first.
        case interrupted
        /// The context limit: the runner started a new conversation.
        case reset
    }

    public var reason: Reason
    /// The `D` it answers.
    public var turn: Int?
    /// Of speech sent.
    public var seconds: Double?

    public init(reason: Reason, turn: Int? = nil, seconds: Double? = nil) {
        self.reason = reason
        self.turn = turn
        self.seconds = seconds
    }

    public init?(payload: Data) {
        guard let done = try? JSONDecoder().decode(Self.self, from: payload) else { return nil }
        self = done
    }
}

/// Full duplex (the model hears you while it talks, both in real time) or
/// walkie-talkie (you talk, then it answers: the model steps through its
/// reply as fast as it can and the app plays it once it's complete) --
/// for a Mac that runs the model slower than real time. `auto` picks by
/// the runner's measured real-time factor.
public enum VoiceLabMode: String, CaseIterable, Sendable {
    case auto
    case duplex
    case walkieTalkie

    /// Above this measured RTF, `auto` is walkie-talkie.
    public static let realTimeLimit = 1.0

    /// Walkie-talkie for this mode and measured RTF (nil: not measured,
    /// taken as fast enough).
    public func usesWalkieTalkie(rtf: Double?) -> Bool {
        switch self {
        case .duplex: return false
        case .walkieTalkie: return true
        case .auto: return (rtf ?? 0) > Self.realTimeLimit
        }
    }

    /// The `M` frame's payload for the runner.
    public static func runnerMode(walkieTalkie: Bool) -> String { walkieTalkie ? "walkie" : "duplex" }

    /// The speed for the "~0.5× real time" notice: 1 / RTF, one decimal.
    public static func speedText(rtf: Double) -> String {
        String(format: "%.1f", rtf > 0 ? 1 / rtf : 0)
    }
}

/// Splits a byte stream into VoiceFrames, whatever the chunking: a frame
/// split over several reads, several frames in one read. A length above
/// `maxPayload` means the stream is out of step (or not ours) -- nothing
/// after it can be trusted, so the decoder stays failed.
public struct VoiceFrameDecoder: Sendable {
    public enum Failure: Error, Equatable {
        /// The type byte and the length that was refused.
        case badLength(type: UInt8, length: UInt32)
    }

    /// 16 MB: ~6 minutes of 22 kHz speech in one frame -- far above
    /// anything the runner sends (80 ms per frame).
    public static let defaultMaxPayload = 16 << 20

    public let maxPayload: Int
    private var buffer = Data()
    private var failure: Failure?

    public init(maxPayload: Int = VoiceFrameDecoder.defaultMaxPayload) {
        self.maxPayload = maxPayload
    }

    /// Bytes received but not yet a whole frame.
    public var pendingBytes: Int { buffer.count }

    /// The complete frames `data` finishes, in order.
    public mutating func append(_ data: Data) throws -> [VoiceFrame] {
        if let failure { throw failure }
        buffer.append(data)
        var frames: [VoiceFrame] = []
        var at = buffer.startIndex
        while buffer.endIndex - at >= VoiceFrame.headerSize {
            let type = buffer[at]
            let length = buffer[(at + 1)..<(at + 5)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard length <= UInt32(maxPayload) else {
                let failed = Failure.badLength(type: type, length: length)
                failure = failed
                buffer = Data()
                throw failed
            }
            let start = at + VoiceFrame.headerSize
            let end = start + Int(length)
            guard end <= buffer.endIndex else { break }
            frames.append(VoiceFrame(type: type, payload: Data(buffer[start..<end])))
            at = end
        }
        buffer = Data(buffer[at...])
        return frames
    }
}
