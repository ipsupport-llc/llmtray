import Foundation

/// One extracted "page": a PDF page, a sheet, a slide, or the whole of a
/// flowing document (docx/rtf/html have no stable pages).
public struct PageOut: Encodable {
    public var page: Int
    public var text: String
    public var tier: Int = 1
    public var junk_score: Double = 0
    public var error: String?
    /// Sheet or slide name, when the format has one.
    public var name: String?
    public var truncated: Bool?

    public init(page: Int, text: String, name: String? = nil, error: String? = nil) {
        self.page = page
        self.text = text
        self.name = name
        self.error = error
    }
}

public struct ExtractError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Caps applied inside the child. The parent enforces its own (time, memory,
/// bytes read from the pipe) on top -- these just make failure polite.
public struct Limits {
    public var maxFileBytes = 512 * 1024 * 1024
    public var maxPages = 5_000
    public var maxTextBytes = 32 * 1024 * 1024        // per document
    public var maxZipEntryBytes = 256 * 1024 * 1024   // inflated, per member
    public var maxZipTotalBytes = 512 * 1024 * 1024   // inflated, all members read
    public var maxZipRatio = 200.0                    // inflated / compressed, per member
    public var maxZipEntries = 20_000
    public var maxXMLDepth = 256
    public var maxSheetRows = 1_000_000
    public var rowsPerBlock = 40                      // xlsx/xls: header repeated per block
    public var skipZipPrecheck = false                // for the measurement only
    public init() {}
}

/// Emits pages as JSON lines and keeps the per-document text cap.
public final class Emitter {
    let limits: Limits
    var textBytes = 0
    public private(set) var count = 0
    public var capped = false
    private let out = FileHandle.standardOutput
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public init(limits: Limits) { self.limits = limits }

    /// Returns false once the document's text cap is reached (stop extracting).
    @discardableResult
    public func emit(_ p: PageOut) -> Bool {
        if capped { return false }
        var p = p
        let bytes = p.text.utf8.count
        if textBytes + bytes > limits.maxTextBytes {
            let room = max(0, limits.maxTextBytes - textBytes)
            p.text = String(decoding: Array(p.text.utf8.prefix(room)), as: UTF8.self)
            p.truncated = true
            capped = true
        }
        textBytes += p.text.utf8.count
        p.junk_score = p.error == nil ? Junk.score(p.text) : 1
        if var data = try? encoder.encode(p) {
            data.append(0x0A)
            out.write(data)
        }
        count += 1
        return !capped
    }
}
