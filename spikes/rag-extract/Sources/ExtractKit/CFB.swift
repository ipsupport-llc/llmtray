import Foundation

/// OLE2 / Compound File Binary reader ([MS-CFB]): enough to pull a named
/// top-level stream out of .xls / .ppt / .doc. Every chain walk is bounded by
/// the sector count, so a FAT loop is an error, not a hang.
public final class CFB {
    public static let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    struct DirEntry {
        let name: String
        let type: UInt8
        let left: Int, right: Int, child: Int
        let start: Int
        let size: Int
    }

    let data: Data
    let sectorSize: Int
    let miniSectorSize: Int
    let miniCutoff: Int
    var fat: [UInt32] = []
    var miniFat: [UInt32] = []
    var dir: [DirEntry] = []
    var miniStream = Data()

    public init(data: Data) throws {
        self.data = data
        guard data.count >= 512, Array(data.prefix(8)) == CFB.magic else { throw ExtractError("cfb: not a compound file") }
        let shift = CFB.u16(data, 0x1E)
        guard shift == 9 || shift == 12 else { throw ExtractError("cfb: bad sector shift \(shift)") }
        sectorSize = 1 << shift
        miniSectorSize = 1 << CFB.u16(data, 0x20)
        miniCutoff = CFB.u32(data, 0x38)
        try load()
    }

    static func u16(_ d: Data, _ o: Int) -> Int {
        guard o >= 0, o + 2 <= d.count else { return 0 }
        return d.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian) }
    }

    static func u32(_ d: Data, _ o: Int) -> Int {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        return d.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian) }
    }

    private var sectorCount: Int { max(0, data.count / sectorSize - 1) }

    private func sector(_ n: Int) throws -> Data {
        let off = (n + 1) * sectorSize
        guard n >= 0, off + sectorSize <= data.count else {
            // The last sector of a file may be short; pad instead of failing.
            if n >= 0, off < data.count {
                var d = data.subdata(in: off..<data.count)
                d.append(Data(count: sectorSize - d.count))
                return d
            }
            throw ExtractError("cfb: sector \(n) past end (truncated?)")
        }
        return data.subdata(in: off..<(off + sectorSize))
    }

    private func load() throws {
        let nFat = CFB.u32(data, 0x2C)
        let firstDir = CFB.u32(data, 0x30)
        let firstMiniFat = CFB.u32(data, 0x3C)
        let nMiniFat = CFB.u32(data, 0x40)
        var difatNext = CFB.u32(data, 0x44)
        let nDifat = CFB.u32(data, 0x48)
        guard nFat <= sectorCount + 1 else { throw ExtractError("cfb: FAT sector count \(nFat) > file") }

        var fatSectors: [Int] = []
        for i in 0..<109 { let s = CFB.u32(data, 0x4C + i * 4); if s < 0xFFFF_FFFA { fatSectors.append(s) } }
        var guardN = 0
        while difatNext < 0xFFFF_FFFA, guardN < nDifat + 1, guardN <= sectorCount {
            let s = try sector(difatNext)
            let per = sectorSize / 4 - 1
            for i in 0..<per { let v = CFB.u32(s, i * 4); if v < 0xFFFF_FFFA { fatSectors.append(v) } }
            difatNext = CFB.u32(s, per * 4)
            guardN += 1
        }
        fatSectors = Array(fatSectors.prefix(nFat))
        fat.reserveCapacity(fatSectors.count * sectorSize / 4)
        for fs in fatSectors {
            let s = try sector(fs)
            s.withUnsafeBytes { raw in
                for i in 0..<(sectorSize / 4) { fat.append(raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian) }
            }
        }
        let dirData = try chain(firstDir, maxBytes: Int.max)
        let n = dirData.count / 128
        for i in 0..<n {
            let o = i * 128
            let nameLen = min(64, CFB.u16(dirData, o + 64))
            var units: [UInt16] = []
            var j = 0
            while j + 1 < nameLen - 1 { units.append(UInt16(CFB.u16(dirData, o + j))); j += 2 }
            let type = dirData[dirData.startIndex + o + 66]
            let sizeLo = CFB.u32(dirData, o + 120)
            dir.append(DirEntry(
                name: String(decoding: units, as: UTF16.self), type: type,
                left: CFB.u32(dirData, o + 68), right: CFB.u32(dirData, o + 72), child: CFB.u32(dirData, o + 76),
                start: CFB.u32(dirData, o + 116), size: sizeLo))
        }
        guard let root = dir.first, root.type == 5 else { throw ExtractError("cfb: no root entry") }
        if nMiniFat > 0 {
            let mf = try chain(firstMiniFat, maxBytes: nMiniFat * sectorSize)
            mf.withUnsafeBytes { raw in
                for i in 0..<(mf.count / 4) { miniFat.append(raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian) }
            }
            miniStream = try chain(root.start, maxBytes: root.size)
        }
    }

    /// Follows a FAT chain; a loop or an out-of-range link is an error.
    private func chain(_ start: Int, maxBytes: Int) throws -> Data {
        var out = Data()
        var s = start
        var steps = 0
        while s < 0xFFFF_FFFA {
            guard s < fat.count else { throw ExtractError("cfb: chain link \(s) outside FAT") }
            steps += 1
            if steps > sectorCount + 1 { throw ExtractError("cfb: FAT chain loop") }
            out.append(try sector(s))
            if out.count >= maxBytes { break }
            s = Int(fat[s])
        }
        return maxBytes == Int.max ? out : out.prefix(maxBytes)
    }

    private func miniChain(_ start: Int, size: Int) throws -> Data {
        var out = Data()
        var s = start
        var steps = 0
        let total = miniStream.count / miniSectorSize
        while s < 0xFFFF_FFFA, out.count < size {
            guard s < miniFat.count, (s + 1) * miniSectorSize <= miniStream.count else {
                throw ExtractError("cfb: mini chain link \(s) out of range")
            }
            steps += 1
            if steps > total + 1 { throw ExtractError("cfb: mini FAT chain loop") }
            let o = miniStream.startIndex + s * miniSectorSize
            out.append(miniStream[o..<(o + miniSectorSize)])
            s = Int(miniFat[s])
        }
        return out.prefix(size)
    }

    /// Names of the root storage's direct children (walks the sibling tree).
    public func topLevelNames() -> [String] {
        topLevel().map { dir[$0].name }
    }

    private func topLevel() -> [Int] {
        guard let root = dir.first else { return [] }
        var out: [Int] = []
        var stack = [root.child]
        var seen = Set<Int>()
        while let i = stack.popLast() {
            guard i < dir.count, !seen.contains(i) else { continue }
            seen.insert(i)
            out.append(i)
            stack.append(dir[i].left)
            stack.append(dir[i].right)
        }
        return out
    }

    /// A top-level stream by name (case-insensitive, as CFB compares).
    public func stream(_ name: String) throws -> Data? {
        guard let i = topLevel().first(where: { dir[$0].name.caseInsensitiveCompare(name) == .orderedSame && dir[$0].type == 2 }) else {
            return nil
        }
        let e = dir[i]
        if e.size < miniCutoff { return try miniChain(e.start, size: e.size) }
        return try chain(e.start, maxBytes: e.size)
    }
}
