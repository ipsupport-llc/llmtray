import Foundation
import Accelerate

/// Brute-force dense index held in memory: N×dim f16 as stored, optionally
/// widened to f32 for cblas_sgemv.
public final class DenseIndex {
    public let dim: Int
    public private(set) var ids: [Int64] = []
    public private(set) var docs: [Int64] = []
    public private(set) var f16: [Float16] = []
    public private(set) var f32: [Float] = []
    public var count: Int { ids.count }

    public init(dim: Int) { self.dim = dim }

    /// Load the active set's blocks of searchable/embedded documents.
    public static func load(db: Database, setID: Int64, dim: Int, widen: Bool) throws -> DenseIndex {
        let d = DenseIndex(dim: dim)
        let st = try db.prepare("""
            SELECT b.doc, b.n, b.chunk_ids, b.v FROM vec_blocks b
            JOIN documents d ON d.doc = b.doc AND d.rev = b.rev
            WHERE b.set_id = ? AND d.status IN ('searchable','embedded')
            """)
        try st.bind([.int(setID)])
        while try st.step() {
            let doc = st.int(0), n = Int(st.int(1))
            let idb = st.blob(2), vb = st.blob(3)
            precondition(idb.count == n * 8 && vb.count == n * dim * 2, "bad block")
            d.ids.append(contentsOf: idb.bindMemory(to: Int64.self))
            d.docs.append(contentsOf: repeatElement(doc, count: n))
            d.f16.append(contentsOf: vb.bindMemory(to: Float16.self))
        }
        if widen { d.widen() }
        return d
    }

    public func append(ids newIDs: [Int64], doc: Int64, vectors: [Float16]) {
        ids += newIDs; docs += repeatElement(doc, count: newIDs.count); f16 += vectors
    }

    /// f16 → f32 with vImage.
    public func widen() {
        f32 = [Float](repeating: 0, count: f16.count)
        f16.withUnsafeMutableBufferPointer { src in
            f32.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: src.baseAddress, height: 1, width: vImagePixelCount(src.count), rowBytes: src.count * 2)
                var d = vImage_Buffer(data: dst.baseAddress, height: 1, width: vImagePixelCount(dst.count), rowBytes: dst.count * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&s, &d, vImage_Flags(kvImageNoFlags))
            }
        }
    }

    public func dropF32() { f32 = [] }

    // MARK: scoring kernels (scores = M · q)

    /// Single cblas_sgemv over the whole f32 matrix.
    public func scoresSgemv(_ q: [Float]) -> [Float] {
        precondition(!f32.isEmpty)
        var y = [Float](repeating: 0, count: count)
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(count), Int32(dim), 1, f32, Int32(dim), q, 1, 0, &y, 1)
        return y
    }

    /// cblas_sgemv per row block, blocks spread over cores.
    public func scoresSgemvParallel(_ q: [Float], blocks: Int = 8) -> [Float] {
        precondition(!f32.isEmpty)
        var y = [Float](repeating: 0, count: count)
        let n = count, dim = self.dim
        let per = (n + blocks - 1) / blocks
        f32.withUnsafeBufferPointer { a in
            y.withUnsafeMutableBufferPointer { yb in
                let yp = yb.baseAddress!
                DispatchQueue.concurrentPerform(iterations: blocks) { b in
                    let lo = b * per, hi = min(n, lo + per)
                    guard lo < hi else { return }
                    cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(hi - lo), Int32(dim), 1,
                                a.baseAddress! + lo * dim, Int32(dim), q, 1, 0, yp + lo, 1)
                }
            }
        }
        return y
    }

    /// Multi-core f16 kernel: rows as stored (half the memory traffic), f32 accumulation.
    public func scoresF16(_ q: [Float], blocks: Int = 8) -> [Float] {
        precondition(dim % 32 == 0)
        var y = [Float](repeating: 0, count: count)
        let n = count, dim = self.dim
        let per = (n + blocks - 1) / blocks
        f16.withUnsafeBufferPointer { a in
            q.withUnsafeBufferPointer { qb in
                y.withUnsafeMutableBufferPointer { yb in
                    let ap = UnsafeRawPointer(a.baseAddress!), qp = UnsafeRawPointer(qb.baseAddress!)
                    let yp = yb.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: blocks) { b in
                        let lo = b * per, hi = min(n, lo + per)
                        var r = lo
                        while r < hi {
                            let row = ap + r * dim * 2
                            var acc0 = SIMD16<Float>(), acc1 = SIMD16<Float>()
                            var k = 0
                            while k < dim {
                                let h0 = row.loadUnaligned(fromByteOffset: k * 2, as: SIMD16<Float16>.self)
                                let h1 = row.loadUnaligned(fromByteOffset: (k + 16) * 2, as: SIMD16<Float16>.self)
                                let q0 = qp.loadUnaligned(fromByteOffset: k * 4, as: SIMD16<Float>.self)
                                let q1 = qp.loadUnaligned(fromByteOffset: (k + 16) * 4, as: SIMD16<Float>.self)
                                acc0 = acc0.addingProduct(SIMD16<Float>(h0), q0)
                                acc1 = acc1.addingProduct(SIMD16<Float>(h1), q1)
                                k += 32
                            }
                            yp[r] = (acc0 + acc1).sum()
                            r += 1
                        }
                    }
                }
            }
        }
        return y
    }

    /// f16 kept in RAM; each core widens a tile of rows into an L2-sized f32
    /// buffer (vImage) and runs cblas_sgemv on it.
    public func scoresF16Tiled(_ q: [Float], blocks: Int = 8, tileRows: Int = 128) -> [Float] {
        var y = [Float](repeating: 0, count: count)
        let n = count, dim = self.dim
        let per = (n + blocks - 1) / blocks
        f16.withUnsafeBufferPointer { a in
            y.withUnsafeMutableBufferPointer { yb in
                let yp = yb.baseAddress!
                let ap = UnsafeMutableRawPointer(mutating: a.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: blocks) { b in
                    let lo = b * per, hi = min(n, lo + per)
                    guard lo < hi else { return }
                    let tile = UnsafeMutablePointer<Float>.allocate(capacity: tileRows * dim)
                    defer { tile.deallocate() }
                    var r = lo
                    while r < hi {
                        let rows = min(tileRows, hi - r)
                        var s = vImage_Buffer(data: ap + r * dim * 2, height: 1, width: vImagePixelCount(rows * dim), rowBytes: rows * dim * 2)
                        var d = vImage_Buffer(data: tile, height: 1, width: vImagePixelCount(rows * dim), rowBytes: rows * dim * 4)
                        _ = vImageConvert_Planar16FtoPlanarF(&s, &d, vImage_Flags(kvImageDoNotTile))
                        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(rows), Int32(dim), 1, tile, Int32(dim), q, 1, 0, yp + r, 1)
                        r += rows
                    }
                }
            }
        }
        return y
    }

    /// Top-k indices by score, restricted to rows whose doc passes `allowed`.
    public func topK(_ scores: [Float], k: Int, allowed: ((Int64) -> Bool)? = nil) -> [(id: Int64, score: Float)] {
        var heap: [(Float, Int)] = []   // min-heap on score, size ≤ k
        heap.reserveCapacity(k + 1)
        func siftUp(_ i0: Int) { var i = i0; while i > 0 { let p = (i - 1) / 2; if heap[p].0 <= heap[i].0 { break }; heap.swapAt(p, i); i = p } }
        func siftDown(_ i0: Int) {
            var i = i0
            while true {
                let l = 2 * i + 1, r = l + 1; var m = i
                if l < heap.count, heap[l].0 < heap[m].0 { m = l }
                if r < heap.count, heap[r].0 < heap[m].0 { m = r }
                if m == i { return }
                heap.swapAt(i, m); i = m
            }
        }
        for (i, s) in scores.enumerated() {
            if heap.count == k, s <= heap[0].0 { continue }
            if let allowed, !allowed(docs[i]) { continue }
            if heap.count < k { heap.append((s, i)); siftUp(heap.count - 1) }
            else { heap[0] = (s, i); siftDown(0) }
        }
        return heap.sorted { $0.0 > $1.0 }.map { (ids[$0.1], $0.0) }
    }
}
