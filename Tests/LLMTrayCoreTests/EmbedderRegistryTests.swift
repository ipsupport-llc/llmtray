import CryptoKit
import XCTest
@testable import LLMTrayCore

final class EmbedderRegistryTests: XCTestCase {
    var runtime: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runtime")
    }

    func testTheShippedRegistryIsPinnedAndItsReferenceMatches() throws {
        let registry = try EmbedderRegistry.load(from: runtime.appendingPathComponent("embedders.json"))
        XCTAssertEqual(registry.defaultID, "bge-m3")
        let bge = try XCTUnwrap(registry.entry("bge-m3"))
        XCTAssertEqual(bge.source.repo, "mlx-community/bge-m3-mlx-fp16")
        XCTAssertEqual(bge.pooling, "cls", "not the model card's mean")
        XCTAssertEqual(bge.dim, 1024)
        XCTAssertEqual(Set(bge.source.files.keys), ["config.json", "tokenizer.json", "model.safetensors"])
        XCTAssertEqual(bge.vectorSetModel, "bge-m3@a37eddded9a6a1273a87fb8b0da0d1cdbd98aeec")
        let reference = runtime.appendingPathComponent(bge.reference.file)
        XCTAssertEqual(try EmbedderFiles.sha256(of: reference), bge.reference.sha256, "the sidecar the runner checks")
        let modules = ["xlm-roberta": "xlmr.py", "gemma3-bidir": "gemma3_bidir.py"]
        XCTAssertEqual(Set(modules.keys), EmbedderRegistry.families)
        for module in modules.values {
            XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.appendingPathComponent("llmtray_embed/" + module).path), module)
        }
    }

    func entryJSON(id: String = "e", repo: String = "org/model", revision: String = String(repeating: "a", count: 40),
                   sha: String = String(repeating: "b", count: 64), family: String = "xlm-roberta",
                   upstream: String = "org/original@main", extra: String = "",
                   files: [String] = ["config.json", "tokenizer.json"], fileSHA: String = String(repeating: "d", count: 64)) -> String {
        let pins = files.map { "\"\($0)\":\"\(fileSHA)\"," }.joined()
        return """
        {"id":"\(id)","display_name":"E","license":"MIT","family":"\(family)",
         "source":{"repo":"\(repo)","revision":"\(revision)","files":{\(pins)"model.safetensors":"\(sha)"},"bytes":1,
                   "upstream":"\(upstream)"},
         "pooling":"cls","dim":8,"preprocessing_version":1,\(extra)
         "reference":{"file":"r.json","sha256":"\(String(repeating: "c", count: 64))","min_cosine":0.99}}
        """
    }

    func registry(_ entries: [String], default id: String = "e") throws -> EmbedderRegistry {
        let r = try JSONDecoder().decode(EmbedderRegistry.self, from: Data(#"{"default":"\#(id)","embedders":[\#(entries.joined(separator: ","))]}"#.utf8))
        try r.validate()
        return r
    }

    func testValidation() throws {
        XCTAssertNoThrow(try registry([entryJSON()]))
        XCTAssertThrowsError(try registry([entryJSON()], default: "x")) { XCTAssertEqual($0 as? EmbedderRegistry.Invalid, .unknownDefault("x")) }
        for qwen in [entryJSON(id: "qwen3-embedding"), entryJSON(repo: "Qwen/Qwen3-Embedding-0.6B"), entryJSON(repo: "mlx-community/QWEN-embed")] {
            XCTAssertThrowsError(try registry([entryJSON(), qwen.replacingOccurrences(of: "\"id\":\"e\"", with: "\"id\":\"q\"")])) {
                guard case .forbidden? = $0 as? EmbedderRegistry.Invalid else { return XCTFail("\($0)") }
            }
        }
        XCTAssertThrowsError(try registry([entryJSON(revision: "main")]), "a branch isn't a pin")
        XCTAssertThrowsError(try registry([entryJSON(sha: "sha256:abc")]))
        XCTAssertThrowsError(try registry([entryJSON(family: "bert")]), "no module for that family")
        XCTAssertThrowsError(try registry([entryJSON(upstream: "Qwen/Qwen3-Embedding-0.6B@abc")]), "converted from a Qwen model") {
            XCTAssertEqual($0 as? EmbedderRegistry.Invalid, .forbidden("e"))
        }
        // Every file the runner reads is pinned (sha-checked after the download).
        XCTAssertThrowsError(try registry([entryJSON(files: ["config.json"])])) {
            XCTAssertEqual($0 as? EmbedderRegistry.Invalid, .unpinnedFile(entry: "e", file: "tokenizer.json"))
        }
        XCTAssertThrowsError(try registry([entryJSON(extra: #""tokenizer":{"file":"tok.json"},"#)])) {
            XCTAssertEqual($0 as? EmbedderRegistry.Invalid, .unpinnedFile(entry: "e", file: "tok.json"))
        }
        XCTAssertThrowsError(try registry([entryJSON(extra: #""dense":[{"file":"2_Dense/model.safetensors"}],"#)])) {
            XCTAssertEqual($0 as? EmbedderRegistry.Invalid, .unpinnedFile(entry: "e", file: "2_Dense/model.safetensors"))
        }
        XCTAssertNoThrow(try registry([entryJSON(extra: #""dense":[{"file":"2_Dense/model.safetensors"}],"#,
                                                 files: ["config.json", "tokenizer.json", "2_Dense/model.safetensors"])]))
    }

    func testDownloadedFilesAreCheckedAgainstTheirPins() throws {
        let dir = indexTempDir()
        let data = Data("weights".utf8)
        for name in ["model.safetensors", "config.json", "tokenizer.json"] { try data.write(to: dir.appendingPathComponent(name)) }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let good = try XCTUnwrap(try registry([entryJSON(sha: sha, fileSHA: sha)]).entry("e"))
        XCTAssertEqual(EmbedderFiles.mismatches(in: dir, for: good), [])
        let bad = try XCTUnwrap(try registry([entryJSON(sha: String(repeating: "0", count: 64), fileSHA: sha)]).entry("e"))
        XCTAssertEqual(EmbedderFiles.mismatches(in: dir, for: bad), ["model.safetensors"])
        XCTAssertEqual(EmbedderFiles.mismatches(in: indexTempDir(), for: good), ["config.json", "model.safetensors", "tokenizer.json"], "missing")
    }
}
