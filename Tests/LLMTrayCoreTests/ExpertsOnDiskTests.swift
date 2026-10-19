import XCTest
@testable import LLMTrayCore

final class ExpertsOnDiskTests: XCTestCase {
    func testRoutedExpertBytesFromHeader() {
        let header: [String: Any] = [
            "model.layers.0.mlp.switch_mlp.gate_proj.weight": ["shape": [8, 64, 16], "data_offsets": [0, 1000]],
            "model.layers.0.mlp.switch_mlp.gate_proj.scales": ["shape": [8, 64, 2], "data_offsets": [1000, 1200]],
            "model.layers.0.mlp.switch_mlp.up_proj.weight": ["shape": [8, 64, 16], "data_offsets": [1200, 2200]],
            "model.layers.0.mlp.shared_expert.gate_proj.weight": ["shape": [64, 16], "data_offsets": [2200, 2300]],
            // Not quantized (no scales): loads, not counted.
            "model.layers.1.experts.switch_glu.up_proj.weight": ["shape": [8, 64, 16], "data_offsets": [2300, 3300]],
            // Nemotron-style fc1/fc2: not a SwitchGLU the runtime offloads.
            "model.layers.2.mixer.switch_mlp.fc1.weight": ["shape": [8, 64, 16], "data_offsets": [3300, 4300]],
            "model.layers.0.mlp.gate.weight": ["shape": [8, 64], "data_offsets": [4300, 4400]],
            "__metadata__": ["format": "mlx"],
        ]
        XCTAssertEqual(ModelWeights.routedExpertBytes(header: header, dataBytes: 5000, experts: 8), 2200)
        XCTAssertEqual(ModelWeights.routedExpertBytes(header: header, dataBytes: 5000, experts: 16), 0)
        // Offsets past the file: nothing trusted.
        XCTAssertEqual(ModelWeights.routedExpertBytes(header: header, dataBytes: 1500, experts: 8), 0)
    }

    func testShare() {
        let gb: Int64 = 1 << 30
        let limit = UInt64(19 * gb)
        // Fits with room: no experts on disk.
        XCTAssertNil(ServerLaunch.expertsOnDiskShare(gpuLimitBytes: limit, weightsBytes: 8 * gb, expertBytes: 6 * gb))
        // Dense: nothing to leave on disk.
        XCTAssertNil(ServerLaunch.expertsOnDiskShare(gpuLimitBytes: limit, weightsBytes: 30 * gb, expertBytes: 0))
        // 47 GB, 44 of them experts: what's left of 19 GB after 3 GB, the
        // margin and the reserve, as a share of the experts, in 5% steps.
        let share = ServerLaunch.expertsOnDiskShare(gpuLimitBytes: limit, weightsBytes: 47 * gb, expertBytes: 44 * gb)
        XCTAssertNotNil(share)
        XCTAssertGreaterThan(share ?? 0, 0.2)
        XCTAssertLessThan(share ?? 1, 0.35)
        // The rest alone doesn't fit, or not even 10% of the experts would:
        // not offered.
        XCTAssertNil(ServerLaunch.expertsOnDiskShare(gpuLimitBytes: limit, weightsBytes: 60 * gb, expertBytes: 10 * gb))
        XCTAssertNil(ServerLaunch.expertsOnDiskShare(gpuLimitBytes: limit, weightsBytes: 216 * gb, expertBytes: 200 * gb))
        // A barely fitting model keeps most, at most 90%.
        XCTAssertEqual(ServerLaunch.expertsOnDiskShare(gpuLimitBytes: limit, weightsBytes: 17 * gb, expertBytes: 16 * gb).map { $0 <= 0.9 }, true)
    }

    func testLaunchArgument() {
        var base = Profile.builtIn
        base.id = Profile.defaultID
        let p = ProfileResolver.resolve(overlay: nil, base: base)
        var c = ServerLaunch.Context(modelPath: "/m", internalPort: 1, alias: "m", disallowQuantizedKV: false, drafterRepo: nil)
        XCTAssertFalse(ServerLaunch.arguments(p, c).contains("--experts-on-disk"))
        c.expertsOnDiskShare = 0.25
        let args = ServerLaunch.arguments(p, c)
        XCTAssertEqual(args[(args.firstIndex(of: "--experts-on-disk") ?? 0) + 1], "0.25")
    }
}
