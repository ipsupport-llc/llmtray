import XCTest
@testable import LLMTrayCore

final class DiskUsageTests: XCTestCase {
    func testDirectorySizeCountsFilesOnceAndFollowsTopLevelLink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = root.appendingPathComponent("org/model")
        try fm.createDirectory(at: model.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(count: 100_000).write(to: model.appendingPathComponent("a.safetensors"))
        try Data(count: 50_000).write(to: model.appendingPathComponent("sub/b.json"))
        // A link inside isn't followed (no double counting)...
        try fm.createSymbolicLink(at: model.appendingPathComponent("dup"), withDestinationURL: model.appendingPathComponent("a.safetensors"))
        let size = DiskUsage.directorySize(model.path)
        XCTAssertGreaterThanOrEqual(size, 150_000)
        XCTAssertLessThan(size, 250_000)
        // ...but a symlinked model folder is measured where it points.
        let link = root.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: link, withDestinationURL: model)
        XCTAssertEqual(DiskUsage.directorySize(link.path), size)
    }

    func testFreeSpaceForMissingFolderUsesExistingParent() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())/a/b").path
        XCTAssertNotNil(DiskUsage.freeSpace(at: missing))
        XCTAssertGreaterThan(DiskUsage.freeSpace(at: missing) ?? 0, 0)
    }
}
