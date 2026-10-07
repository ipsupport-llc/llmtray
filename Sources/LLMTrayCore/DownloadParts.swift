import Foundation

/// How a big file is fetched: in byte ranges over several connections at
/// once, as Hugging Face's own fast transfer does. One connection to the
/// file CDN tops out well below what the line can do, and a model's
/// weights are one or a few big files.
public enum DownloadParts {
    /// Files smaller than this come in one piece.
    public static let threshold: Int64 = 256 * 1_048_576
    public static let maxParts = 8
    public static let minPartBytes: Int64 = 64 * 1_048_576

    /// The byte ranges of a file of `size` bytes, in order and covering it
    /// exactly; nil for a file that comes in one piece.
    public static func ranges(size: Int64, threshold: Int64 = threshold, maxParts: Int = maxParts,
                              minPartBytes: Int64 = minPartBytes) -> [ClosedRange<Int64>]? {
        guard size >= threshold, size > 0 else { return nil }
        let n = Int(min(Int64(maxParts), max(1, size / max(1, minPartBytes))))
        guard n > 1 else { return nil }
        let part = (size + Int64(n) - 1) / Int64(n)
        return stride(from: Int64(0), to: size, by: Int(part)).map { start in
            start...(min(start + part, size) - 1)
        }
    }

    /// The `Range` header value of a part.
    public static func header(_ range: ClosedRange<Int64>) -> String {
        "bytes=\(range.lowerBound)-\(range.upperBound)"
    }

    /// Whether a response is (the start of) the range asked for: 206 with a
    /// Content-Range from the same first byte, not past its end, of a file
    /// of `size` bytes. A shorter range is legal: the rest is asked for
    /// again. A server that ignores Range answers 200 with the whole file.
    public static func isPart(status: Int, contentRange: String?, of range: ClosedRange<Int64>, size: Int64) -> Bool {
        guard status == 206, let contentRange, contentRange.hasPrefix("bytes ") else { return false }
        let body = contentRange.dropFirst("bytes ".count)
        let halves = body.split(separator: "/", maxSplits: 1)
        guard halves.count == 2 else { return false }
        let bounds = halves[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]) else { return false }
        if halves[1] != "*" && Int64(halves[1]) != size { return false }
        return first == range.lowerBound && last >= first && last <= range.upperBound
    }

    /// Connections per big file: 16 in all, at least 2 each (with more than
    /// 8 big files, only 16 / that many fetch at once).
    public static func connections(bigFiles: Int) -> Int {
        max(2, min(maxParts, 16 / max(1, bigFiles)))
    }
}
