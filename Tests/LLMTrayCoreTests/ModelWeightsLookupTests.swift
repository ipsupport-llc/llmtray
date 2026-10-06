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
