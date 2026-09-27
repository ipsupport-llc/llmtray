import Foundation

/// The limits one document's extraction runs under (adr/0012, Extraction).
/// The parent passes them to the child as `--caps <json>`; the child keeps
/// the ones it can check politely (file size, pages, text, the zip reader's),
/// the parent enforces the rest (wall clock, memory, stdout) whatever the
/// child does. A key missing from the JSON keeps its default.
public struct ExtractionCaps: Codable, Equatable, Sendable {
    public var maxFileBytes = 512 * 1024 * 1024
    public var maxPages = 5_000
    /// UTF-8 bytes of text per document.
    public var maxTextBytes = 32 * 1024 * 1024
    /// Zip containers (docx, odt): inflated bytes per part, across all parts,
    /// inflated / compressed per part, and the number of entries.
    public var maxZipPartBytes = 256 * 1024 * 1024
    public var maxZipTotalBytes = 512 * 1024 * 1024
    public var maxZipRatio = 200.0
    public var maxZipEntries = 20_000
    public var maxXMLDepth = 256
    /// Wall clock for the whole child, start to exit.
    public var timeoutSeconds = 120.0
    /// The child's own RLIMIT_CPU.
    public var cpuSeconds = 120
    /// Physical footprint: the parent's polling limit, and the kernel's
    /// (jetsam) limit when that can be set.
    public var memoryBytes = 1024 * 1024 * 1024

    public init() {}

    /// What the parent reads from the child's stdout at most: the text cap
    /// plus JSON escaping (~1.5x) and each page's framing.
    public var maxOutputBytes: Int {
        maxTextBytes + maxTextBytes / 2 + maxPages * 256 + 64 * 1024
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExtractionCaps()
        maxFileBytes = try c.decodeIfPresent(Int.self, forKey: .maxFileBytes) ?? d.maxFileBytes
        maxPages = try c.decodeIfPresent(Int.self, forKey: .maxPages) ?? d.maxPages
        maxTextBytes = try c.decodeIfPresent(Int.self, forKey: .maxTextBytes) ?? d.maxTextBytes
        maxZipPartBytes = try c.decodeIfPresent(Int.self, forKey: .maxZipPartBytes) ?? d.maxZipPartBytes
        maxZipTotalBytes = try c.decodeIfPresent(Int.self, forKey: .maxZipTotalBytes) ?? d.maxZipTotalBytes
        maxZipRatio = try c.decodeIfPresent(Double.self, forKey: .maxZipRatio) ?? d.maxZipRatio
        maxZipEntries = try c.decodeIfPresent(Int.self, forKey: .maxZipEntries) ?? d.maxZipEntries
        maxXMLDepth = try c.decodeIfPresent(Int.self, forKey: .maxXMLDepth) ?? d.maxXMLDepth
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        cpuSeconds = try c.decodeIfPresent(Int.self, forKey: .cpuSeconds) ?? d.cpuSeconds
        memoryBytes = try c.decodeIfPresent(Int.self, forKey: .memoryBytes) ?? d.memoryBytes
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Which cap a document ran into ("too large: text").
public enum ExtractionCap: String, Codable, Equatable, Sendable {
    case fileBytes = "file"
    case pages
    case text
    /// The parent's stdout cap.
    case output
    case zipEntries = "zip-entries"
    case zipPart = "zip-part"
    case zipTotal = "zip-total"
    case zipRatio = "zip-ratio"
    case xmlDepth = "xml-depth"
}

/// Why a document yielded no pages. Plain English, like ProcessRunner's
/// failures: the Files view maps these to its own statuses.
public enum ExtractionError: Error, Equatable, Sendable, CustomStringConvertible {
    case tooLarge(ExtractionCap)
    /// The wall clock or the CPU limit.
    case timeout
    case memory
    /// A format this version doesn't index (the detected type).
    case unsupported(String)
    /// Its format goes through Apple's importers, which only run in a child
    /// without network access -- and the sandbox couldn't be set up.
    case unavailableOnSystem
    case encrypted
    /// Corrupt, truncated, or refused as hostile (a DOCTYPE in an Office part).
    case unreadable(String)
    /// The child died without a summary, or broke the protocol.
    case crashed(String)
    /// A text layer, all of it failing the junk check (a scan, a broken font).
    case junk
    /// No text at all.
    case empty

    public var description: String {
        switch self {
        case .tooLarge(let cap): return "too large: \(cap.rawValue)"
        case .timeout: return "timed out"
        case .memory: return "used too much memory"
        case .unsupported(let kind): return "not supported (\(kind))"
        case .unavailableOnSystem: return "not supported on this system"
        case .encrypted: return "password-protected"
        case .unreadable(let why): return "unreadable: \(why)"
        case .crashed(let why): return "extractor crashed: \(why)"
        case .junk: return "no usable text layer"
        case .empty: return "no text"
        }
    }
}

extension ExtractionError: Codable {
    private enum CodingKeys: String, CodingKey { case code, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        switch try c.decode(String.self, forKey: .code) {
        case "too-large":
            guard let cap = ExtractionCap(rawValue: detail) else {
                throw DecodingError.dataCorruptedError(forKey: .detail, in: c, debugDescription: "unknown cap \(detail)")
            }
            self = .tooLarge(cap)
        case "timeout": self = .timeout
        case "memory": self = .memory
        case "unsupported": self = .unsupported(detail)
        case "unavailable-on-system": self = .unavailableOnSystem
        case "encrypted": self = .encrypted
        case "unreadable": self = .unreadable(detail)
        case "crashed": self = .crashed(detail)
        case "junk": self = .junk
        case "empty": self = .empty
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .code, in: c, debugDescription: "unknown code \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let (code, detail): (String, String?)
        switch self {
        case .tooLarge(let cap): (code, detail) = ("too-large", cap.rawValue)
        case .timeout: (code, detail) = ("timeout", nil)
        case .memory: (code, detail) = ("memory", nil)
        case .unsupported(let kind): (code, detail) = ("unsupported", kind)
        case .unavailableOnSystem: (code, detail) = ("unavailable-on-system", nil)
        case .encrypted: (code, detail) = ("encrypted", nil)
        case .unreadable(let why): (code, detail) = ("unreadable", why)
        case .crashed(let why): (code, detail) = ("crashed", why)
        case .junk: (code, detail) = ("junk", nil)
        case .empty: (code, detail) = ("empty", nil)
        }
        try c.encode(code, forKey: .code)
        try c.encodeIfPresent(detail, forKey: .detail)
    }
}
