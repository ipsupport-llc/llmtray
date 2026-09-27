import XCTest
@testable import LLMTrayCore

/// The real runner (runtime/llmtray_embed_runner.py) with bge-m3, when the
/// weights and a Python with MLX are on this Mac -- never in CI:
///
///     LLMTRAY_TEST_BGE_M3_DIR=<folder with config.json, tokenizer.json,
///     model.safetensors> [LLMTRAY_TEST_EMBED_PYTHON=<python3>] swift test --filter EmbedRunnerIntegration
///
/// ~1.7 GB of GPU memory for a few seconds.
final class EmbedRunnerIntegrationTests: XCTestCase {
    var runtime: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runtime")
    }

    func setUpRunner() throws -> (EmbedRunner, EmbedderEntry) {
        let env = ProcessInfo.processInfo.environment
        guard let model = env["LLMTRAY_TEST_BGE_M3_DIR"], FileManager.default.fileExists(atPath: model + "/model.safetensors") else {
            throw XCTSkip("set LLMTRAY_TEST_BGE_M3_DIR to a bge-m3 folder to run")
        }
        let python = env["LLMTRAY_TEST_EMBED_PYTHON"]
            ?? NSHomeDirectory() + "/Library/Application Support/LLMTray/mlx_server_venv/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("no Python with MLX at \(python)") }
        let registry = try EmbedderRegistry.load(from: runtime.appendingPathComponent("embedders.json"))
        let entry = try XCTUnwrap(registry.entry(registry.defaultID))
        var c = EmbedRunner.Configuration(executable: python, arguments: [
            runtime.appendingPathComponent("llmtray_embed_runner.py").path,
            "--registry", runtime.appendingPathComponent("embedders.json").path,
            "--entry", entry.id, "--model-dir", model, "--parent", String(getpid()),
        ], environment: ["PYTHONDONTWRITEBYTECODE": "1", "TOKENIZERS_PARALLELISM": "false"])
        c.readyTimeout = 120
        return (EmbedRunner(configuration: c), entry)
    }

    func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var d: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return d / (na.squareRoot() * nb.squareRoot())
    }

    func testParityWithTheReferenceVectorsAndHybridSearch() async throws {
        let (runner, entry) = try setUpRunner()
        let ready = try await runner.start()
        XCTAssertEqual(ready.dim, 1024)
        XCTAssertGreaterThanOrEqual(ready.verifyMinCosine ?? 0, entry.reference.minCosine)
        print("bge-m3 ready in \(ready.loadMilliseconds) ms, verify min cosine \(ready.verifyMinCosine ?? .nan)")

        // Parity from the Swift side: the reference texts against their stored vectors.
        struct Ref: Decodable { struct Item: Decodable { var kind: String; var text: String; var f16_hex: String }; var items: [Item] }
        let ref = try JSONDecoder().decode(Ref.self, from: Data(contentsOf: runtime.appendingPathComponent(entry.reference.file)))
        for kind in [EmbedRunnerMessage.Kind.query, .document] {
            let items = ref.items.filter { $0.kind == kind.rawValue }
            let got = try await runner.embed(items.map(\.text), kind: kind)
            for (i, item) in items.enumerated() {
                var bytes = Data()
                var hex = Substring(item.f16_hex)
                while !hex.isEmpty { bytes.append(UInt8(hex.prefix(2), radix: 16)!); hex = hex.dropFirst(2) }
                let want = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }.map { Float($0) }
                XCTAssertGreaterThan(cosine(got.floats(i), want), 0.999, "\(kind) \(i)")
            }
        }

        // Meaning, not words: an English query for a Russian document: no shared word.
        let idx = try ProjectIndex.testIndex(chunker: IndexChunker())
        let set = try idx.vectorSet(model: entry.id, dim: entry.dim, prepVersion: entry.preprocessingVersion).id
        let docs = ["Арендатор обязан вносить плату за помещение ежемесячно до пятого числа.",
                    "func parseConfig(path: String) throws -> Config { try decoder.decode(Config.self, from: Data(contentsOf: path)) }",
                    "The cat sat on the warm windowsill and watched the birds outside."]
        var ids: [Int64] = []
        for (i, text) in docs.enumerated() {
            let doc = try idx.addText(text, name: "d\(i).txt", embed: false)
            let pending = try idx.pendingChunks(doc: doc, set: set, limit: 64)
            let e = try await runner.embed(pending.map(\.text), kind: .document)
            try idx.commitVectors(doc: doc, rev: pending[0].rev, set: set, chunks: pending.map(\.id), vectors: e.vectors)
            ids.append(doc)
        }
        let dense = DenseVectors(setID: set, dim: 1024)
        try dense.refresh(from: idx.db)
        let q = try await runner.embed(["office rent payment deadline monthly"], kind: .query)
        let r = try idx.searcher().search("office rent payment deadline monthly", queryVector: q.floats(0), dense: dense)
        XCTAssertTrue(r.usedDense)
        XCTAssertEqual(r.hits.first?.doc, ids[0])
        XCTAssertEqual(r.hits.first?.foundBy, [.dense], "found by meaning only")
        runner.stop()
    }

    /// The app dies without closing the pipe: the runner exits by itself.
    func testExitsWhenItsParentDies() async throws {
        let (runner, _) = try setUpRunner()
        var args = runner.configuration.arguments
        if let i = args.firstIndex(of: "--parent") { args.removeSubrange(i...(i + 1)) }
        // A shell in the middle: it starts the runner (its parent), prints its pid, waits.
        let command = ([runner.configuration.executable] + args).map { "'\($0)'" }.joined(separator: " ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 60 | \(command) > /dev/null 2>&1 & echo $!; wait"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(line))
        try await Task.sleep(nanoseconds: 3_000_000_000)   // loading
        XCTAssertEqual(kill(pid, 0), 0, "running")
        kill(p.processIdentifier, SIGKILL)
        let t0 = Date()
        while kill(pid, 0) == 0, Date().timeIntervalSince(t0) < 5 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotEqual(kill(pid, 0), 0)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
        print("runner exited \(Int(Date().timeIntervalSince(t0) * 1000)) ms after its parent")
    }
}
