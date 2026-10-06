import XCTest
@testable import LLMTrayCore

final class ModelWeightsLookupTests: XCTestCase {
    func testDeclaredLookupTables() {
        let source = """
        class Gemma4TextModel(nn.Module):
            # Only indexed by token id: can stay in its file (mapped_embedding).
            lookup_tables = ("embed_tokens_per_layer",)

        class Other(nn.Module):
            lookup_tables = ('a_table', "b_table")
        """
        XCTAssertEqual(ModelWeights.declaredLookupTables(inSource: source), ["embed_tokens_per_layer", "a_table", "b_table"])
        XCTAssertEqual(ModelWeights.declaredLookupTables(inSource: "x = 1"), [])
        XCTAssertEqual(ModelWeights.declaredLookupTables(inSource: "    # lookup_tables = (\"embed_tokens\",)\n"), [])
    }

    func testImportedModulesAndModelTypes() throws {
        let source = """
        import mlx.core as mx
        from . import gemma4_audio, gemma4_text, gemma4_vision
        from .base import BaseModelArgs
        from .cache import KVCache as Cache
        """
        XCTAssertEqual(ModelWeights.importedModules(inSource: source), ["gemma4_audio", "gemma4_text", "gemma4_vision", "base", "cache"])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"model_type": "gemma4", "text_config": {"model_type": "gemma4_text"}}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        XCTAssertEqual(ModelWeights.modelTypes(inFolder: dir.path), ["gemma4", "gemma4_text"])
        XCTAssertEqual(ModelWeights.modelTypes(inFolder: dir.appendingPathComponent("missing").path), [])
        try Data(#"{"model_type": "../../etc/x", "text_config": {"model_type": "ok_1"}}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        XCTAssertEqual(ModelWeights.modelTypes(inFolder: dir.path), ["ok_1"])
    }

    func testOffsetsOutsideTheFileCountNothing() {
        let table = "m.embed_tokens_per_layer.weight"
        XCTAssertEqual(ModelWeights.lookupTableBytes(header: [table: ["data_offsets": [0, 100]]], dataBytes: 100, tables: ["embed_tokens_per_layer"]), 100)
        XCTAssertEqual(ModelWeights.lookupTableBytes(header: [table: ["data_offsets": [0, 101]]], dataBytes: 100, tables: ["embed_tokens_per_layer"]), 0)
        XCTAssertEqual(ModelWeights.lookupTableBytes(header: [table: ["data_offsets": [50, 10]]], dataBytes: 100, tables: ["embed_tokens_per_layer"]), 0)
        XCTAssertEqual(ModelWeights.lookupTableBytes(header: [table: ["data_offsets": [-5, 10]]], dataBytes: 100, tables: ["embed_tokens_per_layer"]), 0)
        XCTAssertEqual(ModelWeights.lookupTableBytes(header: [table: ["data_offsets": [0, Int64.max]]], dataBytes: 100, tables: ["embed_tokens_per_layer"]), 0)
        // Any tensor out of range makes the whole header untrusted.
        XCTAssertEqual(ModelWeights.lookupTableBytes(header: [table: ["data_offsets": [0, 10]], "m.other.weight": ["data_offsets": [10, 500]]],
                                                     dataBytes: 100, tables: ["embed_tokens_per_layer"]), 0)
    }

    private func safetensors(_ tensors: [(String, Int)]) -> Data {
        var header: [String: Any] = ["__metadata__": ["format": "mlx"]]
        var offset = 0
        for (name, size) in tensors {
            header[name] = ["dtype": "U32", "shape": [size / 4], "data_offsets": [offset, offset + size]]
            offset += size
        }
        let json = try! JSONSerialization.data(withJSONObject: header)
        var data = Data()
        var n = UInt64(json.count).littleEndian
        withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
        data.append(json)
        data.append(Data(count: offset))
        return data
    }

    func testLookupTableBytesFromTheHeaders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try safetensors([
            ("language_model.model.embed_tokens_per_layer.weight", 4000),
            ("language_model.model.embed_tokens_per_layer.scales", 400),
            ("language_model.model.embed_tokens_per_layer.biases", 400),
            ("language_model.model.embed_tokens.weight", 8000),
            ("language_model.model.layers.0.mlp.weight", 1200),
        ]).write(to: dir.appendingPathComponent("model.safetensors"))
        try Data("not a model".utf8).write(to: dir.appendingPathComponent("broken.safetensors"))
        XCTAssertEqual(ModelWeights.lookupTableBytes(inFolder: dir.path, tables: ["embed_tokens_per_layer"]), 4800)
        XCTAssertEqual(ModelWeights.lookupTableBytes(inFolder: dir.path, tables: []), 0)
        XCTAssertEqual(ModelWeights.lookupTableBytes(inFolder: dir.path, tables: ["embeddings"]), 0)
    }
}
