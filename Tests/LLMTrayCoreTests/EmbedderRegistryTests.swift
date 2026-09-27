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

    /// A damaged file under a good stamp isn't trusted: install hashes
    /// every file and fetches only the bad one again; verify (a load
    /// failure) takes the stamp away so the entry isn't ready.
    func testInstallRepairsADamagedFileAndVerifyUnstamps() async throws {
        let data = Data("weights".utf8)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let entry = try XCTUnwrap(try registry([entryJSON(sha: sha, fileSHA: sha)]).entry("e"))
        let folder = indexTempDir().appendingPathComponent("e")
        var fetched: [[String]] = []
        func fetch(_ files: [String], _ into: URL) throws {
            fetched.append(files)
            for name in files { try data.write(to: into.appendingPathComponent(name)) }
        }
        let first = try await EmbedderInstall.install(entry, at: folder, fetch: fetch)
        XCTAssertEqual(first, ["config.json", "model.safetensors", "tokenizer.json"])
        XCTAssertTrue(EmbedderInstall.isStamped(entry, at: folder))
        let again = try await EmbedderInstall.install(entry, at: folder, fetch: fetch)
        XCTAssertEqual(again, [], "all good: nothing fetched")
        XCTAssertEqual(fetched.count, 1)

        try Data("weigh".utf8).write(to: folder.appendingPathComponent("model.safetensors"))   // torn
        XCTAssertTrue(EmbedderInstall.isStamped(entry, at: folder), "the stamp alone doesn't see it")
        let repaired = try await EmbedderInstall.install(entry, at: folder, fetch: fetch)
        XCTAssertEqual(repaired, ["model.safetensors"])
        XCTAssertEqual(fetched.last, ["model.safetensors"], "only the damaged file again")
        XCTAssertEqual(EmbedderFiles.mismatches(in: folder, for: entry), [])
        XCTAssertTrue(EmbedderInstall.isStamped(entry, at: folder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path), ["e"], "no temp left")

        try Data("x".utf8).write(to: folder.appendingPathComponent("tokenizer.json"))
        let damaged = try await EmbedderInstall.verify(entry, at: folder)
        XCTAssertEqual(damaged, ["tokenizer.json"])
        XCTAssertFalse(EmbedderInstall.isStamped(entry, at: folder), "not ready until repaired")

        // A fetch that brings bad bytes leaves the folder as it was.
        let before = try Data(contentsOf: folder.appendingPathComponent("tokenizer.json"))
        do {
            try await EmbedderInstall.install(entry, at: folder) { files, into in
                for name in files { try Data("bad".utf8).write(to: into.appendingPathComponent(name)) }
            }
            XCTFail("checksum")
        } catch let e as EmbedderInstall.ChecksumMismatch {
            XCTAssertEqual(e.files, ["tokenizer.json"])
        }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("tokenizer.json")), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path), ["e"])
    }

    /// Every caller gets the entry's one live runner, so stopping it (before
    /// the weights go) leaves none running.
    @MainActor
    func testTheRunnerPoolSharesOneRunnerPerEntry() async throws {
        let pool = EmbedRunnerPool()
        var made = 0
        func make() -> EmbedRunner {
            made += 1
            var c = EmbedRunner.Configuration(executable: "/bin/sleep", arguments: ["30"])
            c.grace = 0.2
            return EmbedRunner(configuration: c)
        }
        let a = pool.runner(for: "e", make: make)
        let b = pool.runner(for: "e", make: make)
        XCTAssertTrue(a === b)
        XCTAssertEqual(made, 1)
        XCTAssertFalse(pool.runner(for: "other", make: make) === a)
        let starting = Task { try await b.start() }
        for _ in 0..<100 where a.pid == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let pid = try XCTUnwrap(a.pid, "started through one caller")
        // Nobody waiting for it to start (a waiter would get a replacement).
        starting.cancel()
        _ = try? await starting.value
        await pool.stop("e")
        XCTAssertNil(a.pid, "stopped through the pool")
        XCTAssertNotEqual(kill(pid, 0), 0, "exited")
    }
}
