import XCTest
@testable import LLMTrayCore

final class KaggleTests: XCTestCase {
    func testHandleParsing() {
        let h = Kaggle.Handle("romanromenskyi/frognano-4b-2609-ipsupport/other/mlx-gptq-jang")
        XCTAssertEqual(h?.variation, "mlx-gptq-jang")
        XCTAssertEqual(Kaggle.Handle("a/b/other/c/3")?.path, "a/b/other/c")
        XCTAssertNil(Kaggle.Handle("a/b/other"))
        XCTAssertNil(Kaggle.Handle("a/b/other/c/x"))
        XCTAssertNil(Kaggle.Handle("a/../other/c"))
        XCTAssertNil(Kaggle.Handle("a/b c/other/c"))
        XCTAssertNil(Kaggle.Handle("a//other/c"))
    }

    func testFolderOfMirrorAndOthers() {
        let mirrored = Kaggle.Handle(owner: "romanromenskyi", model: "gemma-4-e4b-it-ipsupport", framework: "other", variation: "mlx-qat")
        XCTAssertEqual(mirrored.folderID, "roman220220/gemma-4-E4B-it-qat-mlx")
        let other = Kaggle.Handle(owner: "someone", model: "llama-mlx", framework: "transformers", variation: "4bit")
        XCTAssertEqual(other.folderID, "someone/llama-mlx-4bit")
        // Same slugs under another framework aren't our copy.
        XCTAssertNil(Kaggle.Mirror.hubRepo(for: Kaggle.Handle(owner: "romanromenskyi", model: "gemma-4-e4b-it-ipsupport", framework: "gguf", variation: "mlx-qat")))
    }

    func testMirrorLookup() {
        XCTAssertEqual(Kaggle.Mirror.handle(forHubRepo: "ROMAN220220/flux2-klein-4b-mlx-mixed")?.path,
                       "romanromenskyi/flux-2-klein-4b-ipsupport/other/mlx-gptq-mixed")
        XCTAssertNil(Kaggle.Mirror.handle(forHubRepo: "mlx-community/Qwen3-4B-4bit"))
        // Every row round-trips, and no repo or variation appears twice.
        for row in Kaggle.Mirror.table {
            let handle = Kaggle.Mirror.handle(forHubRepo: row.hub)
            XCTAssertEqual(handle.flatMap(Kaggle.Mirror.hubRepo(for:)), row.hub)
        }
        XCTAssertEqual(Set(Kaggle.Mirror.table.map { $0.hub.lowercased() }).count, Kaggle.Mirror.table.count)
        XCTAssertEqual(Set(Kaggle.Mirror.table.map { $0.model + "/" + $0.variation }).count, Kaggle.Mirror.table.count)
    }

    func testURLs() {
        let h = Kaggle.Handle(owner: "o", model: "m", framework: "other", variation: "v")
        XCTAssertEqual(Kaggle.instanceURL(h)?.absoluteString, "https://www.kaggle.com/api/v1/models/o/m/other/v/get")
        XCTAssertEqual(Kaggle.fileURL(h, version: 2, path: "lm/model 1.safetensors")?.absoluteString,
                       "https://www.kaggle.com/api/v1/models/o/m/other/v/2/download/lm/model%201.safetensors")
        XCTAssertEqual(Kaggle.fileURL(h, version: 1, path: "a?b#c")?.absoluteString,
                       "https://www.kaggle.com/api/v1/models/o/m/other/v/1/download/a%3Fb%23c")
        let files = Kaggle.filesURL(h, version: 1, pageToken: "x+y")
        XCTAssertEqual(URLComponents(url: files!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageToken" }?.value, "x+y")
        let search = URLComponents(url: Kaggle.searchURL("gemma mlx", sort: .downloadCount)!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(search?.queryItems?.first { $0.name == "search" }?.value, "gemma mlx")
        XCTAssertEqual(search?.queryItems?.first { $0.name == "sortBy" }?.value, "downloadCount")
    }

    func testMLXResults() throws {
        let json = """
        {"models":[
          {"ref":"someone/qwen-mlx","title":"Qwen MLX","instances":[
            {"slug":"4bit","framework":"other","versionNumber":2,"totalUncompressedBytes":2000,"licenseName":"Apache 2.0","overview":"# hi"},
            {"slug":"q4","framework":"gguf","versionNumber":1}]},
          {"ref":"google/gemma-3","title":"Gemma 3","instances":[
            {"slug":"gemma-3-1b-it","framework":"pyTorch"},
            {"slug":"gemma-3-1b-it","framework":"transformers"}]},
          {"ref":"romanromenskyi/gemma-4-e2b-it-ipsupport","title":"Gemma 4 E2B","instances":[
            {"slug":"mlx-qat","framework":"other","versionNumber":1},
            {"slug":"qat-phone","framework":"gguf","versionNumber":1}]},
          {"ref":"bad/../x","instances":[{"slug":"mlx","framework":"other"}]}
        ],"nextPageToken":""}
        """
        let page = try JSONDecoder().decode(Kaggle.ModelPage.self, from: Data(json.utf8))
        let results = Kaggle.mlxResults(page)
        XCTAssertEqual(results.map(\.handle.path), ["someone/qwen-mlx/other/4bit", "romanromenskyi/gemma-4-e2b-it-ipsupport/other/mlx-qat"])
        XCTAssertEqual(results.first?.version, 2)
        XCTAssertEqual(results.first?.bytes, 2000)
        XCTAssertEqual(results.first?.license, "Apache 2.0")
        XCTAssertEqual(results.last?.handle.folderID, "roman220220/gemma-4-E2B-it-qat-mlx")
    }

    func testFilePageAndErrorDecoding() throws {
        let page = try JSONDecoder().decode(Kaggle.FilePage.self, from: Data(#"{"files":[{"name":"config.json","size":74829,"creationDate":"x"}],"nextPageToken":"T"}"#.utf8))
        XCTAssertEqual(page.files, [Kaggle.File(name: "config.json", size: 74829)])
        XCTAssertEqual(page.nextPageToken, "T")
        let error = try JSONDecoder().decode(Kaggle.APIError.self, from: Data(#"{"code":403,"message":"User has not consented to terms of use."}"#.utf8))
        XCTAssertEqual(error.code, 403)
    }

    func testPatternSelection() {
        let files = ["config.json", "lm/config.json", "lm/sub/w.safetensors", "dit/w.safetensors"].map { Kaggle.File(name: $0, size: 1) }
        XCTAssertEqual(Kaggle.select(files, patterns: nil).count, 4)
        XCTAssertEqual(Kaggle.select(files, patterns: ["lm/*"]).map(\.name), ["lm/config.json", "lm/sub/w.safetensors"])
        XCTAssertEqual(Kaggle.select(files, patterns: ["*.safetensors", "config.json"]).map(\.name),
                       ["config.json", "lm/sub/w.safetensors", "dit/w.safetensors"])
    }

    func testDownloadSourceChoice() async {
        let ours = "roman220220/gemma-4-E4B-it-qat-mlx"
        var asked = 0
        let reachable: () async -> Bool = { asked += 1; return true }
        let unreachable: () async -> Bool = { asked += 1; return false }
        let viaAutoReachable = await ModelDownloadSource.automatic.kaggleCopy(of: ours, hubReachable: reachable)
        XCTAssertNil(viaAutoReachable)
        let viaAutoBlocked = await ModelDownloadSource.automatic.kaggleCopy(of: ours, hubReachable: unreachable)
        XCTAssertEqual(viaAutoBlocked?.variation, "mlx-qat")
        XCTAssertEqual(asked, 2)
        // Kaggle first, or a repo with no copy: the network isn't asked.
        let viaKaggle = await ModelDownloadSource.kaggle.kaggleCopy(of: ours, hubReachable: unreachable)
        XCTAssertNotNil(viaKaggle)
        let noCopy = await ModelDownloadSource.kaggle.kaggleCopy(of: "mlx-community/x", hubReachable: unreachable)
        XCTAssertNil(noCopy)
        XCTAssertEqual(asked, 2)
    }
}
