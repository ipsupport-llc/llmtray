import Compression
import Foundation

/// A read-only zip reader for Office containers (docx, odt) that never trusts
/// the archive: every part is inflated in memory against a per-part cap, a
/// cap across all parts read and a compression-ratio cap -- declared sizes
/// are only an early out, they can lie. `NSAttributedString` unzips by itself
/// with no caps (a 1.9 MB bomb docx took it to 14.3 GB, adr/0012), so a
/// container goes through here first and only then to it.
///
/// Refused outright: zip64, encrypted parts, more entries than the cap, two
/// entries with one name or overlapping data (a reader that picks the other
/// one would see something unchecked), and a part that is itself an archive
/// -- nested archives are never opened.
public final class CappedZip {
    public struct Entry: Equatable {
        public let name: String
        let method: Int
        let flags: Int
        let compressedSize: Int
        let declaredSize: Int
        let localHeaderOffset: Int
    }

    public let entries: [Entry]
    private let data: Data
    private let caps: ExtractionCaps
    private var inflatedTotal = 0

    public init(data: Data, caps: ExtractionCaps) throws {
        // Offsets below are from the archive's first byte.
        self.data = data.startIndex == 0 ? data : Data(data)
        self.caps = caps
        entries = try Self.centralDirectory(self.data, caps: caps)
    }

    public func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    /// Inflates one part. `keep: false` only counts, for the check before the
    /// archive goes to a reader that unzips it by itself.
    @discardableResult
    public func read(_ name: String, keep: Bool = true) throws -> Data {
        guard let e = entry(name) else { throw Self.corrupt("no part \(name)") }
        return try read(e, keep: keep)
    }

    @discardableResult
    public func read(_ e: Entry, keep: Bool = true) throws -> Data {
        if e.flags & 1 != 0 { throw ExtractionError.encrypted }
        if e.declaredSize > caps.maxZipPartBytes { throw ExtractionError.tooLarge(.zipPart) }
        let start = try dataStart(of: e)
        let end = start + e.compressedSize
        guard end <= data.count else { throw Self.corrupt("\(e.name) runs past the end (truncated?)") }
        let room = caps.maxZipTotalBytes - inflatedTotal
        let out: Data
        let produced: Int
        switch e.method {
        case 0:
            if e.compressedSize > caps.maxZipPartBytes { throw ExtractionError.tooLarge(.zipPart) }
            if e.compressedSize > room { throw ExtractionError.tooLarge(.zipTotal) }
            out = keep ? data.subdata(in: (data.startIndex + start)..<(data.startIndex + end)) : Data()
            produced = e.compressedSize
        case 8:
            (out, produced) = try inflate(e, from: start, to: end, room: room, keep: keep)
        default:
            throw Self.corrupt("\(e.name) uses compression method \(e.method)")
        }
        inflatedTotal += produced
        if keep, Self.isArchive(out) { throw Self.corrupt("\(e.name) is a nested archive") }
        return out
    }

    /// Inflates (counting only) every part, and hands each XML part to
    /// `XMLPartCheck` -- what has to pass before `NSAttributedString` sees it.
    /// `allowExternalDoctype`: ODF (see XMLPartCheck).
    public func checkAll(allowExternalDoctype: Bool = false) throws {
        for e in entries {
            let lower = e.name.lowercased()
            if lower.hasSuffix(".xml") || lower.hasSuffix(".rels") {
                try XMLPartCheck.check(try read(e), part: e.name, maxDepth: caps.maxXMLDepth,
                                       allowExternalDoctype: allowExternalDoctype)
            } else {
                try read(e, keep: false)
            }
        }
    }

    // MARK: Layout

    static func corrupt(_ why: String) -> ExtractionError { .unreadable("zip: \(why)") }

    static func isArchive(_ d: Data) -> Bool {
        d.starts(with: [0x50, 0x4B, 0x03, 0x04]) || d.starts(with: CompoundFile.magic)
    }

    private static func u16(_ d: Data, _ o: Int) throws -> Int {
        guard o >= 0, o + 2 <= d.count else { throw corrupt("read past the end (truncated?)") }
        return d.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian) }
    }

    private static func u32(_ d: Data, _ o: Int) throws -> Int {
        guard o >= 0, o + 4 <= d.count else { throw corrupt("read past the end (truncated?)") }
        return d.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian) }
    }

    private static func centralDirectory(_ data: Data, caps: ExtractionCaps) throws -> [Entry] {
        guard data.count >= 22 else { throw corrupt("too short") }
        // End of central directory: the last 22 bytes, plus a comment of up to 64 KB.
        var eocd = -1
        var i = data.count - 22
        while i >= max(0, data.count - 22 - 65_535) {
            if try u32(data, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw corrupt("no end of central directory (truncated?)") }
        let count = try u16(data, eocd + 10)
        let cdSize = try u32(data, eocd + 12)
        let cdOffset = try u32(data, eocd + 16)
        // A zip64 locator sits right before the classic record.
        let zip64Locator = eocd >= 20 ? try u32(data, eocd - 20) == 0x0706_4B50 : false
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF || zip64Locator {
            throw corrupt("zip64 is not supported")
        }
        guard count <= caps.maxZipEntries else { throw ExtractionError.tooLarge(.zipEntries) }
        guard cdOffset + cdSize <= eocd else { throw corrupt("central directory past its end (truncated?)") }
        var entries: [Entry] = []
        var names = Set<String>()
        var p = cdOffset
        for _ in 0..<count {
            guard try u32(data, p) == 0x0201_4B50 else { throw corrupt("bad central directory entry") }
            let nameLength = try u16(data, p + 28)
            guard p + 46 + nameLength <= data.count else { throw corrupt("name past the end") }
            let name = String(decoding: data[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            let e = Entry(name: name, method: try u16(data, p + 10), flags: try u16(data, p + 8),
                          compressedSize: try u32(data, p + 20), declaredSize: try u32(data, p + 24),
                          localHeaderOffset: try u32(data, p + 42))
            if e.compressedSize == 0xFFFF_FFFF || e.declaredSize == 0xFFFF_FFFF || e.localHeaderOffset == 0xFFFF_FFFF {
                throw corrupt("zip64 is not supported")
            }
            guard names.insert(name).inserted else { throw corrupt("two entries named \(name)") }
            entries.append(e)
            p += 46 + nameLength + (try u16(data, p + 30)) + (try u16(data, p + 32))
        }
        // Each entry's local header and data must lie apart from every other's:
        // overlapping entries are how a small file claims many large parts.
        let byOffset = entries.sorted { $0.localHeaderOffset < $1.localHeaderOffset }
        for (n, e) in byOffset.enumerated() {
            let end = e.localHeaderOffset + 30 + (try u16(data, e.localHeaderOffset + 26))
                + (try u16(data, e.localHeaderOffset + 28)) + e.compressedSize
            let next = n + 1 < byOffset.count ? byOffset[n + 1].localHeaderOffset : cdOffset
            if end > next { throw corrupt("entry \(e.name) overlaps the next one") }
        }
        return entries
    }

    /// Where an entry's data starts, after its local header -- which must
    /// name the same part (a streaming reader goes by the local headers).
    private func dataStart(of e: Entry) throws -> Int {
        let lh = e.localHeaderOffset
        guard try Self.u32(data, lh) == 0x0403_4B50 else { throw Self.corrupt("bad local header for \(e.name)") }
        let nameLength = try Self.u16(data, lh + 26)
        let extraLength = try Self.u16(data, lh + 28)
        guard lh + 30 + nameLength <= data.count else { throw Self.corrupt("\(e.name) runs past the end (truncated?)") }
        let base = data.startIndex
        let localName = String(decoding: data[(base + lh + 30)..<(base + lh + 30 + nameLength)], as: UTF8.self)
        guard localName == e.name else { throw Self.corrupt("local header of \(e.name) names \(localName)") }
        return lh + 30 + nameLength + extraLength
    }

    private func inflate(_ e: Entry, from start: Int, to end: Int, room: Int, keep: Bool) throws -> (Data, Int) {
        // The ratio cap has 1 MB of slack: a tiny part may legitimately inflate
        // far past 200x (a run of spaces).
        let ratioCap = Int(Double(max(e.compressedSize, 1)) * caps.maxZipRatio) + 1_048_576
        let limit = min(caps.maxZipPartBytes, room, ratioCap)
        func overLimit(_ n: Int) -> ExtractionError {
            n > ratioCap ? .tooLarge(.zipRatio) : n > room ? .tooLarge(.zipTotal) : .tooLarge(.zipPart)
        }
        var out = Data()
        var total = 0
        let chunk = 256 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        // COMPRESSION_ZLIB is raw DEFLATE, no zlib header -- exactly zip's.
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Self.corrupt("inflate failed to start")
        }
        defer { compression_stream_destroy(stream) }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw Self.corrupt("empty") }
            stream.pointee.src_ptr = base + start
            stream.pointee.src_size = end - start
            while true {
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                if total + produced > limit { throw overLimit(total + produced) }
                if keep { out.append(dst, count: produced) }
                total += produced
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR { throw Self.corrupt("\(e.name) has corrupt deflate data") }
                if produced == 0 && stream.pointee.src_size == 0 { throw Self.corrupt("\(e.name) is truncated") }
            }
        }
        return (out, total)
    }
}
