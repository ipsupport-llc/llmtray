import XCTest
@testable import LLMTrayCore

final class HFHubCacheTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "hfcache-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    private func make(_ repo: String, rev: String = "abc", files: [String: String]) throws -> String {
        let p = repo.split(separator: "/")
        let root = "\(dir!)/models--\(p[0])--\(p[1])"
        let snap = "\(root)/snapshots/\(rev)"
        try FileManager.default.createDirectory(atPath: root + "/refs", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: snap, withIntermediateDirectories: true)
        try rev.write(toFile: root + "/refs/main", atomically: true, encoding: .utf8)
        for (name, text) in files { try text.write(toFile: snap + "/" + name, atomically: true, encoding: .utf8) }
        return snap
    }

    func testACompleteSnapshotIsFound() throws {
        let snap = try make("org/drafter", files: ["config.json": "{}", "model.safetensors": "x"])
        XCTAssertEqual(HFHubCache.localSnapshot(repo: "org/drafter", cacheDirectory: dir), snap)
    }

    func testMissingShardsOrConfigOrRepoAreNot() throws {
        _ = try make("org/sharded", files: ["config.json": "{}", "a.safetensors": "x",
                                            "model.safetensors.index.json": #"{"weight_map":{"w1":"a.safetensors","w2":"b.safetensors"}}"#])
        XCTAssertNil(HFHubCache.localSnapshot(repo: "org/sharded", cacheDirectory: dir))
        _ = try make("org/noconfig", files: ["model.safetensors": "x"])
        XCTAssertNil(HFHubCache.localSnapshot(repo: "org/noconfig", cacheDirectory: dir))
        XCTAssertNil(HFHubCache.localSnapshot(repo: "org/absent", cacheDirectory: dir))
        XCTAssertNil(HFHubCache.localSnapshot(repo: "notarepo", cacheDirectory: dir))
    }

    func testAPrunedBlobIsNotComplete() throws {
        // As huggingface_hub lays it out: the snapshot's file a symlink
        // into blobs/.
        let snap = try make("org/pruned", files: ["config.json": "{}"])
        let blob = snap + "/../../blobs/deadbeef"
        try FileManager.default.createDirectory(atPath: snap + "/../../blobs", withIntermediateDirectories: true)
        try "x".write(toFile: blob, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: snap + "/model.safetensors", withDestinationPath: "../../blobs/deadbeef")
        XCTAssertEqual(HFHubCache.localSnapshot(repo: "org/pruned", cacheDirectory: dir), snap)
        try FileManager.default.removeItem(atPath: blob)
        XCTAssertNil(HFHubCache.localSnapshot(repo: "org/pruned", cacheDirectory: dir))
    }

    func testTheCacheDirectoryFollowsTheEnvironment() {
        XCTAssertEqual(HFHubCache.directory(environment: ["HF_HUB_CACHE": "/h"], home: "/u"), "/h")
        XCTAssertEqual(HFHubCache.directory(environment: ["HF_HOME": "/hf"], home: "/u"), "/hf/hub")
        XCTAssertEqual(HFHubCache.directory(environment: [:], home: "/u"), "/u/.cache/huggingface/hub")
    }
}
