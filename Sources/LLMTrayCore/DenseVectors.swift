import Accelerate
import Foundation

/// One vector set of one project in memory (adr/0012, Dense retrieval):
/// f16 as stored -- ~400 MB at 200k × 1024 -- widened to f32 in L2-sized
/// tiles only while scoring, each tile through `cblas_sgemv`: f32 speed at
/// f16 memory. Brute force; no vector index at project scale (200k scored
/// in 5-8 ms). Not thread-safe: the registry's reader queue owns it.
public final class DenseVectors {
    public let setID: Int64
    public let dim: Int
    public private(set) var chunkIDs: [Int64] = []
    public private(set) var docs: [Int64] = []
    public private(set) var values: [Float16] = []
    /// What was loaded: the set's epoch (bumped whenever blocks are deleted)
    /// and the highest block id, so a refresh only appends new blocks.
    public private(set) var epoch: Int64 = -1
    public private(set) var lastBlockID: Int64 = 0

    static let loadSQL = "SELECT id, doc, n, chunk_ids, v FROM vec_blocks WHERE +set_id = ? AND id > ? ORDER BY id"

    public var count: Int { chunkIDs.count }
    public var residentBytes: Int { values.count * 2 + chunkIDs.count * 16 }

    public init(setID: Int64, dim: Int) {
        self.setID = setID
        self.dim = dim
    }

    /// Brings the vectors up to date with `db`: new blocks appended, a
    /// changed epoch (deletions) reloads. Returns false when nothing changed.
    @discardableResult
    public func refresh(from db: SQLiteConnection) throws -> Bool {
        let current = try db.scalarInt("SELECT value FROM meta WHERE key = 'vec_epoch'") ?? 0
        if current != epoch {
            chunkIDs.removeAll(keepingCapacity: true)
            docs.removeAll(keepingCapacity: true)
            values.removeAll(keepingCapacity: true)
            lastBlockID = 0
            epoch = current
        }
        // `+set_id`: a rowid range scan, already in id order. By the
        // (set_id, doc, rev) index it was a temp B-tree sort of every blob
        // (10x slower at 200k vectors, and twice the peak memory).
        let st = try db.cached(Self.loadSQL)
        defer { st.reset() }
        try st.bind([.int(setID), .int(lastBlockID)])
        var changed = false
        while try st.step() {
            let n = Int(st.int(2))
            let ids = st.blob(3), v = st.blob(4)
            lastBlockID = st.int(0)
            // A block that doesn't match its header is skipped, not trusted.
            guard n > 0, ids.count == n * 8, v.count == n * dim * 2 else { continue }
            append(ids: ids, doc: st.int(1), vectors: v, count: n)
            changed = true
        }
        return changed
    }

    private func append(ids: UnsafeRawBufferPointer, doc: Int64, vectors: UnsafeRawBufferPointer, count n: Int) {
        // Bulk copies (little-endian on disk and in memory on Apple silicon).
        let idStart = chunkIDs.count
        chunkIDs.append(contentsOf: repeatElement(0, count: n))
        chunkIDs.withUnsafeMutableBytes { dst in
            dst.baseAddress!.advanced(by: idStart * 8).copyMemory(from: ids.baseAddress!, byteCount: n * 8)
        }
        docs.append(contentsOf: repeatElement(doc, count: n))
        let start = values.count
        values.append(contentsOf: repeatElement(0, count: n * dim))
        values.withUnsafeMutableBytes { dst in
            dst.baseAddress!.advanced(by: start * 2).copyMemory(from: vectors.baseAddress!, byteCount: n * dim * 2)
        }
    }

    /// For tests and in-memory use.
    public func append(ids newIDs: [Int64], doc: Int64, vectors: [Float16]) {
        precondition(vectors.count == newIDs.count * dim)
        chunkIDs += newIDs
        docs += repeatElement(doc, count: newIDs.count)
        values += vectors
    }

    /// Scores = M · q for every row. Rows are split over the cores; each
    /// widens `tileRows` rows at a time (vImage) and runs cblas_sgemv on them.
    public func scores(_ query: [Float], tileRows: Int = 128) -> [Float] {
        precondition(query.count == dim, "query dimension")
        let n = count, dim = self.dim
        var y = [Float](repeating: 0, count: n)
        guard n > 0 else { return y }
        let parts = max(1, min(ProcessInfo.processInfo.activeProcessorCount, (n + 1023) / 1024))
        let per = (n + parts - 1) / parts
        values.withUnsafeBufferPointer { a in
            query.withUnsafeBufferPointer { q in
                y.withUnsafeMutableBufferPointer { yb in
                    let source = UnsafeMutableRawPointer(mutating: a.baseAddress!)
                    let out = yb.baseAddress!, qp = q.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: parts) { part in
                        let lo = part * per, hi = min(n, lo + per)
                        guard lo < hi else { return }
                        let tile = UnsafeMutablePointer<Float>.allocate(capacity: tileRows * dim)
                        defer { tile.deallocate() }
                        var r = lo
                        while r < hi {
                            let rows = min(tileRows, hi - r)
                            let width = vImagePixelCount(rows * dim)
                            var src = vImage_Buffer(data: source + r * dim * 2, height: 1, width: width, rowBytes: rows * dim * 2)
                            var dst = vImage_Buffer(data: tile, height: 1, width: width, rowBytes: rows * dim * 4)
                            _ = vImageConvert_Planar16FtoPlanarF(&src, &dst, vImage_Flags(kvImageDoNotTile))
                            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(rows), Int32(dim), 1, tile, Int32(dim), qp, 1, 0, out + r, 1)
                            r += rows
                        }
                    }
                }
            }
        }
        return y
    }

    /// The best `k` rows by score among those whose document `allowed`
    /// accepts, best first; ties by chunk id.
    public func top(_ scores: [Float], k: Int, allowed: (Int64) -> Bool) -> [(chunk: Int64, doc: Int64, score: Float)] {
        guard k > 0 else { return [] }
        // Min-heap of (score, row) holding the best k seen so far.
        var heap: [(Float, Int)] = []
        heap.reserveCapacity(k + 1)
        func less(_ a: (Float, Int), _ b: (Float, Int)) -> Bool {
            a.0 != b.0 ? a.0 < b.0 : chunkIDs[a.1] > chunkIDs[b.1]
        }
        func siftUp(_ start: Int) {
            var i = start
            while i > 0 {
                let p = (i - 1) / 2
                if !less(heap[i], heap[p]) { break }
                heap.swapAt(p, i)
                i = p
            }
        }
        func siftDown(_ start: Int) {
            var i = start
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < heap.count, less(heap[l], heap[m]) { m = l }
                if r < heap.count, less(heap[r], heap[m]) { m = r }
                if m == i { return }
                heap.swapAt(i, m)
                i = m
            }
        }
        for (row, s) in scores.enumerated() where s.isFinite {
            let entry = (s, row)
            if heap.count == k, !less(heap[0], entry) { continue }
            guard allowed(docs[row]) else { continue }
            if heap.count < k {
                heap.append(entry)
                siftUp(heap.count - 1)
            } else {
                heap[0] = entry
                siftDown(0)
            }
        }
        return heap.sorted { less($1, $0) }.map { (chunkIDs[$0.1], docs[$0.1], $0.0) }
    }

    // MARK: - block encoding

    public static func encode(ids: [Int64]) -> Data {
        var data = Data(capacity: ids.count * 8)
        for id in ids { withUnsafeBytes(of: id.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    public static func decodeIDs(_ p: UnsafeRawBufferPointer) -> [Int64] {
        (0..<(p.count / 8)).map { Int64(littleEndian: p.loadUnaligned(fromByteOffset: $0 * 8, as: Int64.self)) }
    }

    public static func encode(vectors: [Float16]) -> Data {
        // Float16 is little-endian on Apple silicon, the only Mac MLX (and so this app) runs on.
        vectors.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
