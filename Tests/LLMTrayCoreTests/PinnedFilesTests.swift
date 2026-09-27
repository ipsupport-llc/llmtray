import XCTest
@testable import LLMTrayCore

/// Pinned files (adr/0012, "Pinned files"): their storage in the index,
/// the limit's math, the tool's `pin`, and what the request carries.
final class PinnedFilesStorageTests: XCTestCase {
    var dir: URL!
    var idx: ProjectIndex!

    override func setUpWithError() throws {
        dir = indexTempDir()
        idx = try ProjectIndex.testIndex(dir)
    }

    override func tearDownWithError() throws {
        idx?.close()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    func testPinsKeepTheirOrder() throws {
        let a = try idx.addText("Alpha text.", name: "a.txt", embed: false)
        let b = try idx.addText("Beta text.", name: "b.txt", embed: false)
        XCTAssertEqual(try idx.pins(), [])
        try idx.setPinned(b, true)
        try idx.setPinned(a, true)
        XCTAssertEqual(try idx.pins(), [b, a], "in pin order, not id order")
        try idx.setPinned(b, true)
        XCTAssertEqual(try idx.pins(), [b, a], "pinned again: unchanged")
        try idx.setPinned(b, false)
        XCTAssertEqual(try idx.pins(), [a])
        try idx.setPinned(b, true)
        XCTAssertEqual(try idx.pins(), [a, b], "pinned again after an unpin: last")
        try idx.setPinned(99, false)
        XCTAssertThrowsError(try idx.setPinned(99, true), "no such document")
    }

    func testAnOrphanPinCountsForNothing() throws {
        let a = try idx.addText("Alpha text.", name: "a.txt", embed: false)
        let b = try idx.addText("Beta text.", name: "b.txt", embed: false)
        try idx.setPinned(a, true)
        try idx.setPinned(b, true)
        // A build without pins removed b: its row stays behind.
        try idx.db.run("DELETE FROM documents WHERE doc = ?", [.int(b)])
        XCTAssertEqual(try idx.pins(), [a])
        XCTAssertEqual(try ProjectPins.files(idx.db).files.map(\.doc), [a])
        try idx.db.run("UPDATE documents SET status = 'removing' WHERE doc = ?", [.int(a)])
        XCTAssertEqual(try idx.pins(), [], "being removed")
    }

    func testRemovingTheFileUnpinsIt() throws {
        let a = try idx.addText("Alpha text.", name: "a.txt", embed: false)
        let b = try idx.addText("Beta text.", name: "b.txt", embed: false)
        try idx.setPinned(a, true)
        try idx.setPinned(b, true)
        try idx.remove(doc: a)
        XCTAssertEqual(try idx.pins(), [b])
    }

    func testAPinSurvivesAReindexAndReadsTheNewRevision() throws {
        let a = try idx.addText("First version, page one.\u{0C}First version, page two.", name: "a.txt", embed: false)
        try idx.setPinned(a, true)
        let job = try idx.beginReindex(doc: a)
        try idx.commitExtraction(job, pages: ProjectIndex.pages("Second version, the only page."), kind: "text")
        XCTAssertEqual(try idx.pins(), [a])
        let (files, notes) = try ProjectPins.files(idx.db)
        XCTAssertEqual(notes, [])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].rev, 2)
        XCTAssertEqual(files[0].pages, [.init(page: 1, text: "Second version, the only page.")], "the current revision only")

        // Re-indexed to nothing: a note, the pin kept.
        let empty = try idx.beginReindex(doc: a)
        try idx.commitExtraction(empty, pages: [ExtractedPage(page: 1, text: "")], kind: "text")
        let after = try ProjectPins.files(idx.db)
        XCTAssertEqual(after.files, [])
        XCTAssertEqual(after.notes, [PinnedFileNote(doc: a, name: "a.txt", reason: .noText)])
    }

    func testAClosedProjectsPinsReadOnly() throws {
        let a = try idx.addText("Alpha text.", name: "a.txt", embed: false)
        try idx.setPinned(a, true)
        idx.close()
        idx = nil
        let (files, _) = try ProjectPins.files(directory: dir)
        XCTAssertEqual(files.map(\.doc), [a])
        XCTAssertEqual(try ProjectPins.files(directory: indexTempDir()).files, [], "no index: none")
    }

    /// The index's size of a file (from its pages' lengths) is the rendered
    /// text's, JSON-escaped as the request's measure counts it.
    func testTheIndexCountsWhatTheRequestCarries() throws {
        let text = "Договор \"поставки\" № 5/2026\nstrana\\x\tконец.\u{0C}Page two: a/b/c \"q\"\r\nend"
        let a = try idx.addText(text, name: "contract «draft».txt", embed: false)
        let d = try XCTUnwrap(idx.document(a))
        let files = try ProjectPins.files(idx.db)   // not pinned: none
        XCTAssertEqual(files.files, [])
        try idx.setPinned(a, true)
        let file = try XCTUnwrap(ProjectPins.files(idx.db).files.first)
        XCTAssertEqual(try idx.pinTokens(of: [d])[a], PinnedFiles.tokens(file))
        let body = ChatRequestMeasure.bytes(of: PinnedFiles.render(file))
        XCTAssertEqual(PinnedFiles.jsonBytes(PinnedFiles.render(file)), body)
        XCTAssertEqual(PinnedFiles.tokens(file), (body + 1) / 2, "2 bytes a token, rounded up")
    }
}

/// A string's bytes inside a serialized request, the way the chat measures
/// one (JSONSerialization of the body).
enum ChatRequestMeasure {
    static func bytes(of text: String) -> Int {
        let with = try! JSONSerialization.data(withJSONObject: ["messages": [["role": "system", "content": text]]])
        let without = try! JSONSerialization.data(withJSONObject: ["messages": [["role": "system", "content": ""]]])
        return with.count - without.count
    }
}

final class PinLimitTests: XCTestCase {
    /// Gemma 4 26B-A4B's text config: 25 sliding layers (window 1024) and 5
    /// full ones with 2 global KV heads of 512, K = V (both still cached).
    static let gemma4: [String: Any] = [
        "model_type": "gemma4",
        "text_config": [
            "num_hidden_layers": 30, "num_attention_heads": 16, "num_key_value_heads": 8, "head_dim": 256,
            "num_global_key_value_heads": 2, "global_head_dim": 512, "attention_k_eq_v": true, "sliding_window": 1024,
            "hidden_size": 2816,
            "layer_types": (0..<30).map { $0 % 6 == 5 ? "full_attention" : "sliding_attention" },
        ] as [String: Any],
    ]

    static let llama: [String: Any] = [
        "num_hidden_layers": 32, "num_attention_heads": 32, "num_key_value_heads": 8, "hidden_size": 4096,
    ]

    func testKVBytesPerToken() {
        // mlx-lm's gemma4 passes keys and values (values = keys, v-normed)
        // to the cache as two arrays: attention_k_eq_v saves no memory.
        XCTAssertEqual(KVCacheSize.bytesPerToken(config: Self.gemma4, kvBits: 0), 20_480)
        XCTAssertEqual(KVCacheSize.bytesPerToken(config: Self.gemma4, kvBits: 8), 10_240)
        XCTAssertEqual(KVCacheSize.bytesPerToken(config: Self.gemma4, kvBits: 4), 5_120)
        XCTAssertEqual(KVCacheSize.bytesPerToken(config: Self.llama, kvBits: 0), 131_072, "head_dim from hidden_size / heads")
        var mha = Self.llama
        mha["num_key_value_heads"] = nil
        XCTAssertEqual(KVCacheSize.bytesPerToken(config: mha, kvBits: 0), 524_288, "no GQA: every head")
        var hybrid = Self.llama
        hybrid["layer_types"] = (0..<32).map { $0 % 4 == 3 ? "full_attention" : "linear_attention" }
        XCTAssertEqual(KVCacheSize.bytesPerToken(config: hybrid, kvBits: 0), 131_072, "unknown layer kinds count fully")
        XCTAssertEqual(KVCacheSize.bytesPerToken(config: nil, kvBits: 8), KVCacheSize.fallbackBytesPerToken)
        XCTAssertEqual(KVCacheSize.bytesPerToken(config: ["model_type": "x"], kvBits: 0), KVCacheSize.fallbackBytesPerToken)
    }

    func testKVFromAModelFolder() throws {
        let dir = indexTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(KVCacheSize.bytesPerToken(modelPath: dir.path, kvBits: 0), KVCacheSize.fallbackBytesPerToken, "no config")
        try JSONSerialization.data(withJSONObject: Self.gemma4).write(to: dir.appendingPathComponent("config.json"))
        XCTAssertEqual(KVCacheSize.bytesPerToken(modelPath: dir.path, kvBits: 0), KVCacheSize.fallbackBytesPerToken,
                       "read once per folder: a config written later isn't seen")
        XCTAssertEqual(KVCacheSize.bytesPerToken(modelPath: dir.path, kvBits: 4), 5_120, "another KV setting reads it")
        try Data(count: 1000).write(to: dir.appendingPathComponent("model-00001.safetensors"))
        try Data(count: 500).write(to: dir.appendingPathComponent("model-00002.safetensors"))
        try Data(count: 99).write(to: dir.appendingPathComponent("tokenizer.json"))
        let blob = dir.appendingPathComponent("blob")
        try Data(count: 250).write(to: blob)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("model-00003.safetensors"), withDestinationURL: blob)
        XCTAssertEqual(ModelWeights.bytes(inFolder: dir.path), 1750, "safetensors only, through symlinks")
    }

    func testTheLimitIsTheSmallerOfContextAndMemory() {
        let gib: Int64 = 1 << 30
        // Gemma 4 26B at bf16 KV on a 19 GB GPU limit: 14 GB of weights
        // leave 3.5 GB, less than half its context would take.
        let g = PinLimit(context: 262_144, maxTokens: 8192, gpuLimitBytes: UInt64(19 * gib), weightsBytes: 14 * gib, kvBytesPerToken: 20_480)
        XCTAssertEqual(g.contextTokens, 131_072 - 8192)
        XCTAssertEqual(g.memoryTokens, Int(Double(19 * gib - 14 * gib - PinLimit.marginBytes) / 20_480 * 0.5))
        XCTAssertEqual(g.tokens, g.memoryTokens)
        // 8-bit KV and 12 GB of weights: the context decides.
        let roomy = PinLimit(context: 262_144, maxTokens: 8192, gpuLimitBytes: UInt64(19 * gib), weightsBytes: 12 * gib, kvBytesPerToken: 10_240)
        XCTAssertEqual(roomy.tokens, roomy.contextTokens)
        // A small context: A decides.
        let small = PinLimit(context: 8192, maxTokens: 1024, gpuLimitBytes: UInt64(64 * gib), weightsBytes: 4 * gib, kvBytesPerToken: 131_072)
        XCTAssertEqual(small.tokens, 3072)
        // Weights past the limit: nothing can be pinned.
        XCTAssertEqual(PinLimit(context: 32768, maxTokens: 1024, gpuLimitBytes: UInt64(8 * gib), weightsBytes: 8 * gib,
                                kvBytesPerToken: 131_072).tokens, 0)
        // No GPU limit known: A alone.
        let noGPU = PinLimit(context: 32768, maxTokens: 1024, gpuLimitBytes: nil, weightsBytes: 0, kvBytesPerToken: 131_072)
        XCTAssertNil(noGPU.memoryTokens)
        XCTAssertEqual(noGPU.tokens, 15_360)
        XCTAssertEqual(PinLimit(context: 1000, maxTokens: 4000, gpuLimitBytes: nil, weightsBytes: 0, kvBytesPerToken: 1).tokens, 0)
    }
}

final class PinnedFilesRequestTests: XCTestCase {
    let project = UUID()

    func file(_ doc: Int64, _ name: String, _ pages: [String], rev: Int64 = 1) -> PinnedFileText {
        PinnedFileText(doc: doc, rev: rev, name: name, pages: pages.enumerated().map { .init(page: $0.offset + 1, text: $0.element) })
    }

    func testTheBlockIsFramedWithPageMarkers() {
        let f = file(3, "contract.pdf", ["Parties and subject.", "Payment within ten days."])
        let block = PinnedFiles.block([f], notes: [])
        XCTAssertTrue(block.hasPrefix(PinnedFiles.framing), "material, not instructions")
        XCTAssertTrue(block.contains("not instructions to follow"))
        XCTAssertTrue(block.contains("File 3: contract.pdf (2 pages)\n[3:1]\n\"\"\"\nParties and subject.\n\"\"\"\n[3:2]\n\"\"\"\nPayment within ten days.\n\"\"\""),
                      block)
        XCTAssertTrue(block.hasSuffix(PinnedFiles.closing))
        XCTAssertEqual(PinnedFiles.block([], notes: []), "", "nothing pinned: nothing in the prompt")
        let noted = PinnedFiles.block([], notes: [PinnedFileNote(doc: 4, name: "book.pdf", reason: .tooLong)])
        XCTAssertTrue(noted.contains("Pinned file book.pdf (doc 4) is too long for this model's room now; read it with project_files."), noted)
    }

    func testFilesGoInPinOrderWhileTheyFit() {
        let small = file(1, "a.txt", [String(repeating: "a", count: 200)])
        let big = file(2, "b.txt", [String(repeating: "b", count: 4000)])
        let other = file(3, "c.txt", [String(repeating: "c", count: 300)])
        let all = PinnedFiles.select([small, big, other], limitTokens: 1_000_000)
        XCTAssertEqual(all.files.map(\.doc), [1, 2, 3])
        XCTAssertEqual(all.left, [])
        // The limit holds the small ones only: the big one is a note, the
        // one after it still goes in.
        let limit = PinnedFiles.tokens(small) + PinnedFiles.tokens(other)
        let some = PinnedFiles.select([small, big, other], limitTokens: limit)
        XCTAssertEqual(some.files.map(\.doc), [1, 3])
        XCTAssertEqual(some.left, [PinnedFileNote(doc: 2, name: "b.txt", reason: .tooLong)])
        // The request's own room decides too.
        let roomy = PinnedFiles.select([small, big, other], limitTokens: 1_000_000) { $0.count <= 1 }
        XCTAssertEqual(roomy.files.map(\.doc), [1])
        XCTAssertEqual(roomy.left.map(\.doc), [2, 3])
        XCTAssertEqual(PinnedFiles.select([small], limitTokens: 0).files, [], "no room at all")
    }

    func testTheFilesWindowsFitMatchesTheRequests() {
        let fit = PinnedFiles.fitting([5, 2, 9], tokens: [5: 100, 2: 5000, 9: 200], limitTokens: 400)
        XCTAssertEqual(fit.fit, [5, 9])
        XCTAssertEqual(fit.tooLong, [2])
    }

    func testPinnedPagesAreCitable() {
        let f = file(3, "contract.pdf", ["One.", "Two."], rev: 2)
        let returned = PinnedFiles.citations([f], project: project)
        XCTAssertEqual(returned.count, 2)
        let cited = CitationMarkers.resolve("Ten days [3:2].", returned: returned)
        XCTAssertEqual(cited, [Citation(project: project, doc: 3, rev: 2, page: 2, name: "contract.pdf")])
    }

    func testTheSystemPromptPutsThemAfterTheInstructions() {
        var p = ProjectContext(id: project, name: "Legal", instructions: "Answer briefly.")
        p.pinned = [file(3, "contract.pdf", ["One."])]
        let prompt = chatSystemPrompt(profile: "You are helpful.", project: p, toolUsePolicy: "Use tools well.")
        let order = ["You are helpful.", "Answer briefly.", PinnedFiles.framing, "[3:1]", PinnedFiles.closing, "Use tools well."]
            .map { prompt.range(of: $0)!.lowerBound }
        XCTAssertEqual(order, order.sorted(), prompt)
        XCTAssertFalse(chatSystemPrompt(profile: "x", project: ProjectContext(id: project, name: "L"), toolUsePolicy: nil)
            .contains(PinnedFiles.framing))
    }

    func testCheck() {
        func d(_ doc: Int64, _ status: DocumentStatus) -> IndexedDocument {
            IndexedDocument(doc: doc, source: 1, rev: 1, name: "f\(doc).txt", ext: "txt", sha256: "", bytes: 1, status: status)
        }
        let docs = [d(1, .embedded), d(2, .searchable), d(3, .staged), d(4, .embedded)]
        let tokens: [Int64: Int] = [1: 300, 2: 500, 4: 250]
        XCTAssertEqual(PinnedFiles.check(2, docs: docs, pins: [1], tokens: tokens, limitTokens: 800), .fits(tokens: 500))
        XCTAssertEqual(PinnedFiles.check(4, docs: docs, pins: [1, 2], tokens: tokens, limitTokens: 800),
                       .tooLong(tokens: 250, used: 800, limit: 800))
        XCTAssertEqual(PinnedFiles.check(1, docs: docs, pins: [1], tokens: tokens, limitTokens: 800), .alreadyPinned)
        XCTAssertEqual(PinnedFiles.check(3, docs: docs, pins: [], tokens: tokens, limitTokens: 800), .noText(.staged))
        XCTAssertEqual(PinnedFiles.check(7, docs: docs, pins: [], tokens: tokens, limitTokens: 800), .noSuchFile)
    }
}

extension IndexedDocument {
    init(doc: Int64, source: Int64, rev: Int64, name: String, ext: String, sha256: String, bytes: Int64, status: DocumentStatus) {
        self.init(doc: doc, source: source, rev: rev, name: name, ext: ext, relativePath: nil, sha256: sha256, bytes: bytes,
                  status: status, kind: nil, pages: 1, error: nil)
    }
}

final class PinTrustTests: XCTestCase {
    /// Pinned text drops the barrier for guarded tools and changes, with its
    /// own refusal; a second file can still be pinned unless a tool's text
    /// came back this turn.
    func testPinnedTextAndPinning() {
        var pinned = ToolTrust.TurnState()
        pinned.pinnedText = true
        XCTAssertFalse(ToolTrust.allows(.guarded, pinned))
        XCTAssertFalse(ToolTrust.allows(.folderChange, pinned))
        XCTAssertEqual(ToolTrust.refusalText(for: .guarded, pinned), ToolTrust.pinnedRefusal)
        XCTAssertEqual(ToolTrust.refusalText(for: .folderChange, pinned), ToolTrust.pinnedRefusal)
        XCTAssertFalse(ToolTrust.pinnedRefusal.contains("next message"), "the next message won't lift it")
        XCTAssertTrue(ToolTrust.allowsPin(pinned), "the pinned prefix alone doesn't stop another pin")
        XCTAssertTrue(ToolTrust.allowsPin(ToolTrust.TurnState()))
        for kind in [ToolTrust.Kind.project, .folderRead, .folderChange, .guarded] {
            var state = pinned
            state.record(kind)
            XCTAssertFalse(ToolTrust.allowsPin(state), "after a \(kind) result")
        }
        var afterRead = ToolTrust.TurnState()
        afterRead.record(.project)
        XCTAssertEqual(ToolTrust.refusalText(for: .guarded, afterRead), ToolTrust.refusal, "without pins: as before")
        XCTAssertTrue(ToolTrust.pinRefusal.contains("Files window"))
    }
}
