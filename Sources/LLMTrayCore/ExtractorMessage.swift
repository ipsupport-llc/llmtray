import Foundation

/// One page of extracted text: a PDF page, or the whole of a flowing
/// document (docx, rtf, html have no stable pages), or a ~1 MB slice of a
/// plain-text file.
public struct ExtractedPage: Codable, Equatable, Sendable {
    /// 1-based.
    public var page: Int
    public var text: String
    /// Which extraction tier produced it (1: the text layer).
    public var tier: Int
    /// The junk check's score, where a next tier exists (PDF pages with
    /// text); nil elsewhere.
    public var junk: Double?
    /// Why this page alone failed (the rest of the document is fine).
    public var error: String?

    public init(page: Int, text: String, tier: Int = 1, junk: Double? = nil, error: String? = nil) {
        self.page = page
        self.text = text
        self.tier = tier
        self.junk = junk
        self.error = error
    }

    public var isJunk: Bool { (junk ?? 0) >= JunkCheck.threshold }
    public var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The last line of a run: what the child found, how many pages it wrote,
/// and why it stopped if it failed.
public struct ExtractionSummary: Codable, Equatable, Sendable {
    public var kind: DocumentKind
    public var pages: Int
    public var milliseconds: Int
    public var failure: ExtractionError?
    /// Whether the no-network sandbox was on (nil: an older child).
    public var networkIsolated: Bool?

    public init(kind: DocumentKind, pages: Int, milliseconds: Int, failure: ExtractionError? = nil, networkIsolated: Bool? = nil) {
        self.kind = kind
        self.pages = pages
        self.milliseconds = milliseconds
        self.failure = failure
        self.networkIsolated = networkIsolated
    }
}

/// One line of `LLMTray --extract`'s stdout protocol, JSON: a page
/// `{"page":1,"text":"…","tier":1,"junk":0.02,"error":null}`, then one
/// `{"summary":{"kind":"pdf","pages":1,"milliseconds":12,"failure":null}}`.
public enum ExtractorMessage: Equatable, Sendable {
    case page(ExtractedPage)
    case summary(ExtractionSummary)

    private struct SummaryLine: Codable { var summary: ExtractionSummary }

    public init?(line: String) {
        let data = Data(line.utf8)
        let decoder = JSONDecoder()
        if let s = try? decoder.decode(SummaryLine.self, from: data) {
            self = .summary(s.summary)
        } else if let p = try? decoder.decode(ExtractedPage.self, from: data) {
            self = .page(p)
        } else {
            return nil
        }
    }

    /// The line, without its newline.
    public var line: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data?
        switch self {
        case .page(let p): data = try? encoder.encode(p)
        case .summary(let s): data = try? encoder.encode(SummaryLine(summary: s))
        }
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
