import AudioToolbox
import Foundation

/// Generated music is kept as AAC in an .m4a (MPEG-4) container: a 30 s
/// 48 kHz stereo song is ~5.8 MB as the runner's 16-bit WAV and ~1 MB at
/// 256 kbit/s AAC. Encoded and read entirely in memory (AudioFile
/// callbacks over a byte buffer): a temporary chat writes nothing to disk.
/// Songs saved before this stay WAV and keep playing.
public enum AudioCodec {
    public enum Format: Equatable {
        case wav, m4a, unknown

        public var fileExtension: String {
            switch self {
            case .wav: return "wav"
            case .m4a, .unknown: return "m4a"
            }
        }
    }

    public struct CodecError: Error, CustomStringConvertible {
        public let step: String
        public let status: OSStatus
        public var description: String { "\(step) failed (OSStatus \(status))" }
    }

    /// From the bytes, not a filename.
    public static func format(of data: Data) -> Format {
        let head = [UInt8](data.prefix(12))
        guard head.count == 12 else { return .unknown }
        if head[0..<4] == [0x52, 0x49, 0x46, 0x46], head[8..<12] == [0x57, 0x41, 0x56, 0x45] { return .wav }   // RIFF....WAVE
        if head[4..<8] == [0x66, 0x74, 0x79, 0x70] { return .m4a }   // ....ftyp
        return .unknown
    }

    /// Length in seconds, for any format Core Audio reads.
    public static func duration(_ data: Data) -> TimeInterval? {
        if let wav = WAVInfo.duration(data) { return wav }
        let buffer = MemoryAudioFile(data)
        return try? buffer.withReader { file in
            var seconds: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            let status = AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &seconds)
            return status == noErr && seconds > 0 ? seconds : nil
        }
    }

    /// WAV (or anything Core Audio decodes) to AAC-LC in an .m4a.
    public static func m4a(from input: Data, bitRate: UInt32 = 256_000) throws -> Data {
        let source = MemoryAudioFile(input)
        let output = MemoryAudioFile(Data())
        try source.withReader { inFile in
            var reader: ExtAudioFileRef?
            try check("ExtAudioFileWrapAudioFileID (read)", ExtAudioFileWrapAudioFileID(inFile, false, &reader))
            guard let reader else { throw CodecError(step: "reader", status: -1) }
            defer { ExtAudioFileDispose(reader) }

            var sourceFormat = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check("source format", ExtAudioFileGetProperty(reader, kExtAudioFileProperty_FileDataFormat, &size, &sourceFormat))
            let channels = max(1, min(sourceFormat.mChannelsPerFrame, 2))
            var pcm = AudioStreamBasicDescription(
                mSampleRate: sourceFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
                mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0
            )
            try check("reader client format", ExtAudioFileSetProperty(reader, kExtAudioFileProperty_ClientDataFormat,
                                                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &pcm))

            var aac = AudioStreamBasicDescription(
                mSampleRate: sourceFormat.mSampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0
            )
            try output.withWriter(type: kAudioFileM4AType, format: &aac) { outFile in
                var writer: ExtAudioFileRef?
                try check("ExtAudioFileWrapAudioFileID (write)", ExtAudioFileWrapAudioFileID(outFile, true, &writer))
                guard let writer else { throw CodecError(step: "writer", status: -1) }
                defer { ExtAudioFileDispose(writer) }
                try check("writer client format", ExtAudioFileSetProperty(writer, kExtAudioFileProperty_ClientDataFormat,
                                                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &pcm))
                // The bit rate is the encoder's (the converter behind the writer).
                var converter: AudioConverterRef?
                var converterSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
                if ExtAudioFileGetProperty(writer, kExtAudioFileProperty_AudioConverter, &converterSize, &converter) == noErr,
                   let converter {
                    var rate = bitRate
                    AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
                    // A null config: the writer re-reads the converter's settings.
                    var none: UnsafeRawPointer?
                    ExtAudioFileSetProperty(writer, kExtAudioFileProperty_ConverterConfig,
                                            UInt32(MemoryLayout<UnsafeRawPointer?>.size), &none)
                }

                let framesPerChunk: UInt32 = 8192
                var samples = [Float](repeating: 0, count: Int(framesPerChunk * channels))
                while true {
                    var frames = framesPerChunk
                    let status: OSStatus = samples.withUnsafeMutableBytes { raw in
                        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                            mNumberChannels: channels, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                        let read = ExtAudioFileRead(reader, &frames, &list)
                        guard read == noErr, frames > 0 else { return read }
                        list.mBuffers.mDataByteSize = frames * pcm.mBytesPerFrame
                        return ExtAudioFileWrite(writer, frames, &list)
                    }
                    try check("encode", status)
                    if frames == 0 { break }
                }
            }
        }
        guard format(of: output.data) == .m4a else { throw CodecError(step: "container", status: -1) }
        return output.data
    }

    private static func check(_ step: String, _ status: OSStatus) throws {
        if status != noErr { throw CodecError(step: step, status: status) }
    }
}

/// A byte buffer Core Audio reads and writes as a file.
private final class MemoryAudioFile {
    var data: Data

    init(_ data: Data) { self.data = data }

    func withReader<T>(_ body: (AudioFileID) throws -> T) throws -> T {
        var file: AudioFileID?
        let status = AudioFileOpenWithCallbacks(Unmanaged.passUnretained(self).toOpaque(),
                                                Self.read, nil, Self.getSize, nil, 0, &file)
        guard status == noErr, let file else { throw AudioCodec.CodecError(step: "open", status: status) }
        defer { AudioFileClose(file) }
        return try body(file)
    }

    /// The container is finished (its index written) when the file closes.
    func withWriter(type: AudioFileTypeID, format: inout AudioStreamBasicDescription, _ body: (AudioFileID) throws -> Void) throws {
        var file: AudioFileID?
        let status = AudioFileInitializeWithCallbacks(Unmanaged.passUnretained(self).toOpaque(),
                                                      Self.read, Self.write, Self.getSize, Self.setSize,
                                                      type, &format, [], &file)
        guard status == noErr, let file else { throw AudioCodec.CodecError(step: "create", status: status) }
        do {
            try body(file)
        } catch {
            AudioFileClose(file)
            throw error
        }
        let closed = AudioFileClose(file)
        if closed != noErr { throw AudioCodec.CodecError(step: "close", status: closed) }
    }

    private static func me(_ p: UnsafeMutableRawPointer) -> MemoryAudioFile {
        Unmanaged<MemoryAudioFile>.fromOpaque(p).takeUnretainedValue()
    }

    private static let read: AudioFile_ReadProc = { client, position, count, buffer, actual in
        let file = me(client)
        let start = Int(position)
        guard start >= 0, start <= file.data.count else { actual.pointee = 0; return kAudioFileInvalidPacketOffsetError }
        let n = min(Int(count), file.data.count - start)
        file.data.withUnsafeBytes { src in
            if n > 0 { buffer.copyMemory(from: src.baseAddress! + start, byteCount: n) }
        }
        actual.pointee = UInt32(n)
        return noErr
    }

    private static let write: AudioFile_WriteProc = { client, position, count, buffer, actual in
        let file = me(client)
        let start = Int(position)
        let end = start + Int(count)
        if end > file.data.count { file.data.append(Data(count: end - file.data.count)) }
        file.data.replaceSubrange(start..<end, with: UnsafeRawBufferPointer(start: buffer, count: Int(count)))
        actual.pointee = count
        return noErr
    }

    private static let getSize: AudioFile_GetSizeProc = { client in
        Int64(me(client).data.count)
    }

    private static let setSize: AudioFile_SetSizeProc = { client, size in
        let file = me(client)
        let n = Int(size)
        if n < file.data.count {
            file.data.removeSubrange(n..<file.data.count)
        } else if n > file.data.count {
            file.data.append(Data(count: n - file.data.count))
        }
        return noErr
    }
}
