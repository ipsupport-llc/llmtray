import Foundation

/// One message between the app and an audio runner (spoken answers'
/// runtime/llmtray_tts_runner.py, the voice conversation's
/// runtime/llmtray_listen_runner.py): a type byte, a 4-byte big-endian
/// payload length, the payload. Binary rather than the embed runner's JSON
/// lines, which would base64 every 80 ms of audio. Each runner's header
/// says which types it sends and takes; the letters were first Voice Lab's
/// (adr/0016, removed).
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
        // Spoken answers' runner (runtime/llmtray_tts_runner.py): app ->
        // runner `P` speak {id, text, lang}, `V` voice {clip}; runner ->
        // app `B` {id} before a sentence's audio; `C` cancel, `Q` quit,
        // `R` ready, `S` speech, `Z` {id, rtf} done, `E` {id, message},
        // `L` a log line.
        case speak = 0x50   // P
        case voice = 0x56   // V
        case begin = 0x42   // B
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
