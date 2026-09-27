import Foundation

/// What the embed runner said when it came up.
public struct EmbedRunnerReady: Equatable, Sendable {
    public var entry: String
    public var dim: Int
    public var maxLength: Int
    public var loadMilliseconds: Int
    /// The lowest cosine against the entry's reference vectors (nil: not checked).
    public var verifyMinCosine: Double?
    public var pid: Int32
}

/// One embed answer: `count` vectors of `dim` f16 values, row-major.
public struct EmbedResult: Equatable, Sendable {
    public var dim: Int
    public var count: Int
    public var vectors: [Float16]
    /// Tokens per text after truncation.
    public var tokens: [Int]
    /// Indexes of texts cut at the model's max length.
    public var truncated: [Int]
    public var milliseconds: Double

    public func vector(_ i: Int) -> ArraySlice<Float16> { vectors[(i * dim)..<((i + 1) * dim)] }
    public func floats(_ i: Int) -> [Float] { vector(i).map(Float.init) }
}

/// The embed runner's JSON-lines protocol (runtime/llmtray_embed_runner.py,
/// adr/0012): parsing its lines, encoding the app's.
public enum EmbedRunnerMessage: Equatable, Sendable {
    case ready(EmbedRunnerReady)
    case fatal(code: String, message: String)
    case result(id: String, EmbedResult)
    /// A request failed (`id` nil: a line the runner couldn't attribute).
    case failure(id: String?, code: String, message: String)
    case pong(id: String?, queued: Int)

    public enum Kind: String, Sendable { case query, document }

    private struct Line: Decodable {
        struct ErrorBody: Decodable { var code: String; var message: String? }
        var event: String?
        var id: String?
        var ok: Bool?
        var error: ErrorBody?
        var entry: String?
        var dim: Int?
        var max_length: Int?
        var load_ms: Double?
        var verify_min_cos: Double?
        var pid: Int32?
        var count: Int?
        var dtype: String?
        var vectors: String?
        var tokens: [Int]?
        var truncated: [Int]?
        var ms: Double?
        var pong: Bool?
        var queue: Int?

        enum CodingKeys: String, CodingKey {
            case event, id, ok, error, entry, dim, max_length, load_ms, verify_min_cos, pid, count, dtype, vectors, tokens, truncated, ms, pong, queue
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            event = try c.decodeIfPresent(String.self, forKey: .event)
            // Ids are strings on our side; tolerate a number echoed back.
            if let s = try? c.decodeIfPresent(String.self, forKey: .id) { id = s } else if let n = try? c.decodeIfPresent(Int.self, forKey: .id) { id = String(n) }
            ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
            error = try c.decodeIfPresent(ErrorBody.self, forKey: .error)
            entry = try c.decodeIfPresent(String.self, forKey: .entry)
            dim = try c.decodeIfPresent(Int.self, forKey: .dim)
            max_length = try c.decodeIfPresent(Int.self, forKey: .max_length)
            load_ms = try c.decodeIfPresent(Double.self, forKey: .load_ms)
            verify_min_cos = try c.decodeIfPresent(Double.self, forKey: .verify_min_cos)
            pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
            count = try c.decodeIfPresent(Int.self, forKey: .count)
            dtype = try c.decodeIfPresent(String.self, forKey: .dtype)
            vectors = try c.decodeIfPresent(String.self, forKey: .vectors)
            tokens = try c.decodeIfPresent([Int].self, forKey: .tokens)
            truncated = try c.decodeIfPresent([Int].self, forKey: .truncated)
            ms = try c.decodeIfPresent(Double.self, forKey: .ms)
            pong = try c.decodeIfPresent(Bool.self, forKey: .pong)
            queue = try c.decodeIfPresent(Int.self, forKey: .queue)
        }
    }

    /// nil for anything that isn't a well-formed protocol line.
    public init?(line: Data) {
        guard let m = try? JSONDecoder().decode(Line.self, from: line) else { return nil }
        switch m.event {
        case "ready":
            guard let entry = m.entry, let dim = m.dim, dim > 0, let maxLength = m.max_length, let pid = m.pid else { return nil }
            self = .ready(EmbedRunnerReady(entry: entry, dim: dim, maxLength: maxLength, loadMilliseconds: Int(m.load_ms ?? 0),
                                           verifyMinCosine: m.verify_min_cos, pid: pid))
            return
        case "fatal":
            self = .fatal(code: m.error?.code ?? "fatal", message: m.error?.message ?? "")
            return
        case nil:
            break
        default:
            return nil
        }
        guard let ok = m.ok else { return nil }
        if !ok {
            self = .failure(id: m.id, code: m.error?.code ?? "internal", message: m.error?.message ?? "")
            return
        }
        if m.pong == true {
            self = .pong(id: m.id, queued: m.queue ?? 0)
            return
        }
        guard let id = m.id, let dim = m.dim, dim > 0, let count = m.count, count >= 0, m.dtype == "f16",
              let b64 = m.vectors, let data = Data(base64Encoded: b64), data.count == count * dim * 2 else { return nil }
        var vectors = [Float16](repeating: 0, count: count * dim)
        vectors.withUnsafeMutableBytes { dst in data.withUnsafeBytes { dst.copyMemory(from: $0) } }
        let tokens = m.tokens ?? []
        guard tokens.isEmpty || tokens.count == count else { return nil }
        self = .result(id: id, EmbedResult(dim: dim, count: count, vectors: vectors, tokens: tokens,
                                           truncated: m.truncated ?? [], milliseconds: m.ms ?? 0))
    }

    private static func encode(_ object: [String: Any]) -> Data {
        // Only strings, numbers and string arrays go in: this can't fail.
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    public static func embedRequest(id: String, kind: Kind, texts: [String], timeoutMilliseconds: Int) -> Data {
        encode(["id": id, "op": "embed", "kind": kind.rawValue, "texts": texts, "timeout_ms": timeoutMilliseconds])
    }

    public static func cancel(id: String, target: String) -> Data {
        encode(["id": id, "op": "cancel", "target": target])
    }

    public static func ping(id: String) -> Data {
        encode(["id": id, "op": "ping"])
    }

    public static var shutdown: Data { encode(["op": "shutdown"]) }
}
