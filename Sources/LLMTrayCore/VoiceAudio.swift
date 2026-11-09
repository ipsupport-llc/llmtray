import Foundation

/// Sample conversions for the audio runners (adr/0016, adr/0031): the
/// microphone's float32 to the runner's int16 PCM, and back for speech.
/// Little-endian, as the runners' numpy reads and writes it.
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

/// A WAV file of mono 16-bit PCM, built in memory: a recording sent to a
/// model that hears (adr/0023) never touches the disk on its way.
public enum WAVFile {
    public static func pcm16(_ samples: Data, sampleRate: Int) -> Data {
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8)
        d += le(UInt32(36 + samples.count))
        d += Data("WAVEfmt ".utf8)
        d += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1))            // PCM, mono
        d += le(UInt32(sampleRate)) + le(UInt32(sampleRate * 2))       // byte rate
        d += le(UInt16(2)) + le(UInt16(16))                            // block align, bits
        d += Data("data".utf8) + le(UInt32(samples.count))
        return d + samples
    }
}
