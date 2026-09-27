import Compression
import Foundation

/// Just enough zip writing to build OOXML samples and bombs.
final class ZipWriter {
    private var out = Data()
    private var central = Data()
    private var count = 0

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        var c = ~seed
        data.withUnsafeBytes { raw in
            for b in raw.bindMemory(to: UInt8.self) { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return ~c
    }

    private func le16(_ v: Int, _ d: inout Data) { var x = UInt16(truncatingIfNeeded: v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
    private func le32(_ v: Int, _ d: inout Data) { var x = UInt32(truncatingIfNeeded: v).littleEndian; d.append(Data(bytes: &x, count: 4)) }

    /// Raw DEFLATE of a stream produced by `produce` (called until it returns nil).
    static func deflate(_ produce: () -> Data?) -> (data: Data, size: Int, crc: UInt32) {
        var out = Data()
        var crc: UInt32 = 0
        var size = 0
        let sp = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { sp.deallocate() }
        compression_stream_init(sp, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
        defer { compression_stream_destroy(sp) }
        let cap = 1 << 20
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        var chunk = produce()
        while true {
            let final = chunk == nil
            let src = chunk ?? Data()
            if let c = chunk { crc = crc32Update(crc, c); size += c.count }
            src.withUnsafeBytes { raw in
                sp.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dst)
                sp.pointee.src_size = src.count
                repeat {
                    sp.pointee.dst_ptr = dst
                    sp.pointee.dst_size = cap
                    let st = compression_stream_process(sp, final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    out.append(dst, count: cap - sp.pointee.dst_size)
                    if st == COMPRESSION_STATUS_END { break }
                } while sp.pointee.src_size > 0 || (final && sp.pointee.dst_size == 0)
            }
            if final { break }
            chunk = produce()
        }
        return (out, size, crc)
    }

    static func crc32Update(_ crc: UInt32, _ d: Data) -> UInt32 { Self.crc(d, seed: crc) }

    func add(_ name: String, _ data: Data, store: Bool = false) {
        if store {
            addRaw(name, method: 0, payload: data, size: data.count, crc: Self.crc(data))
        } else {
            var once: Data? = data
            let d = Self.deflate { defer { once = nil }; return once }
            addRaw(name, method: 8, payload: d.data, size: d.size, crc: d.crc)
        }
    }

    func add(_ name: String, _ s: String) { add(name, Data(s.utf8)) }

    /// `declaredSize` lets a sample lie about its inflated size.
    func addRaw(_ name: String, method: Int, payload: Data, size: Int, crc: UInt32, declaredSize: Int? = nil) {
        let nameData = Data(name.utf8)
        let offset = out.count
        let dsize = declaredSize ?? size
        var lh = Data()
        le32(0x0403_4B50, &lh); le16(20, &lh); le16(0, &lh); le16(method, &lh); le16(0, &lh); le16(0x21, &lh)
        le32(Int(crc), &lh); le32(payload.count, &lh); le32(dsize, &lh); le16(nameData.count, &lh); le16(0, &lh)
        out.append(lh); out.append(nameData); out.append(payload)
        var ch = Data()
        le32(0x0201_4B50, &ch); le16(20, &ch); le16(20, &ch); le16(0, &ch); le16(method, &ch); le16(0, &ch); le16(0x21, &ch)
        le32(Int(crc), &ch); le32(payload.count, &ch); le32(dsize, &ch); le16(nameData.count, &ch)
        le16(0, &ch); le16(0, &ch); le16(0, &ch); le16(0, &ch); le32(0, &ch); le32(offset, &ch)
        central.append(ch); central.append(nameData)
        count += 1
    }

    func finish() -> Data {
        var d = out
        let cdOffset = d.count
        d.append(central)
        var e = Data()
        le32(0x0605_4B50, &e); le16(0, &e); le16(0, &e); le16(count, &e); le16(count, &e)
        le32(central.count, &e); le32(cdOffset, &e); le16(0, &e)
        d.append(e)
        return d
    }
}
