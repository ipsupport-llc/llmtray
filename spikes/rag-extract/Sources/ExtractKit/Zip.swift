import Compression
import Foundation

/// A minimal read-only zip reader: central directory + stored/deflate
/// members, inflated in memory with Compression's raw-DEFLATE decoder
/// (COMPRESSION_ZLIB is raw DEFLATE, no zlib header -- exactly zip's).
///
/// Why in-process rather than `ditto -x -k` / `unzip` into a temp dir:
/// - only the members we need are inflated (document.xml, sharedStrings...),
///   never the whole archive, never to disk;
/// - declared sizes are not trusted: every member is inflated against a byte
///   cap, a total cap across members and a ratio cap, so a bomb stops at the
///   cap instead of filling the disk;
/// - nested archives are never opened (embedded objects are out of scope);
/// - no child-of-a-child process, no temp directory to clean up.
public final class ZipArchive {
    public struct Entry {
        public let name: String
        public let method: UInt16
        public let flags: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let localHeaderOffset: Int
    }

    public let data: Data
    public private(set) var entries: [String: Entry] = [:]
    public private(set) var order: [String] = []
    let limits: Limits
    private var inflatedTotal = 0

    public init(data: Data, limits: Limits) throws {
        self.data = data
        self.limits = limits
        try readCentralDirectory()
    }

    private func u16(_ o: Int) throws -> Int {
        guard o >= 0, o + 2 <= data.count else { throw ExtractError("zip: read past end") }
        return data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian) }
    }

    private func u32(_ o: Int) throws -> Int {
        guard o >= 0, o + 4 <= data.count else { throw ExtractError("zip: read past end") }
        return data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian) }
    }

    private func readCentralDirectory() throws {
        guard data.count >= 22 else { throw ExtractError("zip: too short") }
        // End of central directory: the last 22 bytes plus up to 64 KB comment.
        var eocd = -1
        let lowest = max(0, data.count - 22 - 65_535)
        var i = data.count - 22
        while i >= lowest {
            if try u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ExtractError("zip: no end of central directory (truncated?)") }
        let count = try u16(eocd + 10)
        let cdSize = try u32(eocd + 12)
        let cdOffset = try u32(eocd + 16)
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF { throw ExtractError("zip: zip64 not supported") }
        guard count <= limits.maxZipEntries else { throw ExtractError("zip: \(count) entries > cap \(limits.maxZipEntries)") }
        guard cdOffset + cdSize <= data.count else { throw ExtractError("zip: central directory past end (truncated?)") }
        var p = cdOffset
        for _ in 0..<count {
            guard try u32(p) == 0x0201_4B50 else { throw ExtractError("zip: bad central directory entry") }
            let flags = try u16(p + 8)
            let method = try u16(p + 10)
            let csize = try u32(p + 20)
            let usize = try u32(p + 24)
            let nlen = try u16(p + 28)
            let xlen = try u16(p + 30)
            let clen = try u16(p + 32)
            let lho = try u32(p + 42)
            guard p + 46 + nlen <= data.count else { throw ExtractError("zip: name past end") }
            let name = String(decoding: data[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            let e = Entry(name: name, method: UInt16(method), flags: UInt16(flags),
                          compressedSize: csize, uncompressedSize: usize, localHeaderOffset: lho)
            if entries[name] == nil { order.append(name) }
            entries[name] = e
            p += 46 + nlen + xlen + clen
        }
    }

    public func has(_ name: String) -> Bool { entries[name] != nil }

    /// Inflates one member, bounded by the per-member, total and ratio caps.
    /// `keep: false` only counts (the pre-check before handing the archive
    /// to a reader that unzips by itself).
    public func read(_ name: String, keep: Bool = true) throws -> Data {
        guard let e = entries[name] else { throw ExtractError("zip: no member \(name)") }
        if e.flags & 1 != 0 { throw ExtractError("zip: \(name) is encrypted") }
        // Declared sizes are checked, but only as an early out -- they can lie.
        if e.uncompressedSize > limits.maxZipEntryBytes {
            throw ExtractError("zip: \(name) declares \(e.uncompressedSize) bytes > cap")
        }
        let lh = e.localHeaderOffset
        guard try u32(lh) == 0x0403_4B50 else { throw ExtractError("zip: bad local header for \(name)") }
        let start = lh + 30 + (try u16(lh + 26)) + (try u16(lh + 28))
        let end = start + e.compressedSize
        guard end <= data.count, start <= end else { throw ExtractError("zip: \(name) past end (truncated?)") }
        let cap = min(limits.maxZipEntryBytes, limits.maxZipTotalBytes - inflatedTotal)
        switch e.method {
        case 0:
            guard e.compressedSize <= cap else { throw ExtractError("zip: \(name) over the inflate cap") }
            inflatedTotal += e.compressedSize
            return data.subdata(in: start..<end)
        case 8:
            let ratioCap = Int(Double(max(e.compressedSize, 1)) * limits.maxZipRatio) + 1_048_576
            let (out, n) = try inflate(start: start, end: end, cap: min(cap, ratioCap), name: name,
                                       ratioLimited: ratioCap < cap, keep: keep)
            inflatedTotal += n
            return out
        default:
            throw ExtractError("zip: \(name) uses method \(e.method)")
        }
    }

    private func inflate(start: Int, end: Int, cap: Int, name: String, ratioLimited: Bool, keep: Bool) throws -> (Data, Int) {
        var out = Data()
        var total = 0
        let chunk = 256 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        let sp = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { sp.deallocate() }
        guard compression_stream_init(sp, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ExtractError("zip: inflate init failed")
        }
        defer { compression_stream_destroy(sp) }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress! + start
            sp.pointee.src_ptr = UnsafePointer(base)
            sp.pointee.src_size = end - start
            while true {
                sp.pointee.dst_ptr = dst
                sp.pointee.dst_size = chunk
                let st = compression_stream_process(sp, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - sp.pointee.dst_size
                if total + produced > cap {
                    throw ExtractError(ratioLimited
                        ? "zip: \(name) inflates past \(Int(limits.maxZipRatio))x its compressed size (bomb?)"
                        : "zip: \(name) inflates past the byte cap (bomb?)")
                }
                if keep { out.append(dst, count: produced) }
                total += produced
                if st == COMPRESSION_STATUS_END { break }
                if st == COMPRESSION_STATUS_ERROR { throw ExtractError("zip: \(name) corrupt deflate data") }
                if produced == 0 && sp.pointee.src_size == 0 { throw ExtractError("zip: \(name) truncated deflate data") }
            }
        }
        return (out, total)
    }
}
