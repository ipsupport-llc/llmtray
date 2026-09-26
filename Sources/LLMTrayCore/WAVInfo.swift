import Foundation

/// A PCM WAV's length from its header (RIFF chunks), without decoding it.
public enum WAVInfo {
    public static func duration(_ data: Data) -> TimeInterval? {
        let bytes = [UInt8](data.prefix(4096))
        func u32(_ i: Int) -> Int? {
            guard i + 4 <= bytes.count else { return nil }
            return Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
        }
        guard bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x41, 0x56, 0x45]
        else { return nil }
        var i = 12
        var byteRate: Int?
        while i + 8 <= bytes.count, let size = u32(i + 4) {
            let id = String(decoding: bytes[i..<i + 4], as: UTF8.self)
            if id == "fmt " { byteRate = u32(i + 16) }
            if id == "data" {
                guard let byteRate, byteRate > 0 else { return nil }
                return TimeInterval(size) / TimeInterval(byteRate)
            }
            i += 8 + size + (size & 1)
        }
        return nil
    }
}
