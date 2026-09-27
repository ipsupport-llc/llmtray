import Foundation
import XCTest
@testable import RAGIndex

func tempDir(_ name: String = #function) -> URL {
    let safe = name.filter { $0.isLetter || $0.isNumber }
    let u = FileManager.default.temporaryDirectory
        .appendingPathComponent("rag-spike-\(safe)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

extension ProjectIndex {
    /// Add a document from an in-memory string (pages separated by \u{0C}).
    @discardableResult
    func addText(_ text: String, name: String = "doc.txt", embed: Bool = true) throws -> Int64 {
        let src = dir.appendingPathComponent("src-\(UUID().uuidString).\((name as NSString).pathExtension.isEmpty ? "txt" : (name as NSString).pathExtension)")
        try text.write(to: src, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: src) }
        return try add(file: src, embed: embed)
    }
}

/// Doc ids matched by a lexical list.
func docs(_ s: Searcher, _ ids: [Int64]) throws -> Set<Int64> {
    Set(try ids.compactMap { try s.fetch($0)?.doc })
}
