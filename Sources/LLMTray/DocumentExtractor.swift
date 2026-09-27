import Foundation
import LLMTrayCore

/// Text out of a project file (adr/0012, Extraction): the app binary itself
/// runs as the extractor child (`ExtractorCLI`), supervised -- its own
/// process group, a wall-clock timeout, a memory limit, a stdout cap -- so a
/// hostile file can hang or blow up only that child. Nothing calls this
/// yet; the project index (PR 3.4) will.
enum DocumentExtractor {
    /// The document's pages, or an `ExtractionError` saying why there are none.
    static func extract(url: URL, caps: ExtractionCaps = ExtractionCaps()) async throws -> [ExtractedPage] {
        guard let executable = Bundle.main.executablePath else { throw ExtractionError.crashed("no executable path") }
        return try await DocumentExtraction.run(executable: executable, url: url, caps: caps).pages
    }
}
