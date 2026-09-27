import Foundation
import XCTest
@testable import LLMTrayCore

final class DuplicateFinderTests: FolderTestCase {
    private func bytes(_ n: Int, seed: UInt8) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31) ^ seed }) }

    private func find(_ limits: DuplicateFinder.Limits = DuplicateFinder.Limits(), recursive: Bool = true,
                      isCancelled: () -> Bool = { false }) throws -> DuplicateReport {
        try DuplicateFinder(walker: walker, limits: limits).find([], recursive: recursive, isCancelled: isCancelled)
    }

    func testIdenticalFilesInNestedFolders() throws {
        let photo = bytes(300_000, seed: 7)
        writeData("a/photo.jpg", photo)
        writeData("a/b/c/photo copy.jpg", photo)
        writeData("z.jpg", photo)
        writeData("small1.txt", Data("same".utf8))
        writeData("x/small2.txt", Data("same".utf8))
        writeData("unique.txt", Data("only".utf8))
        let r = try find()
        XCTAssertNil(r.summary.stopped)
        XCTAssertEqual(r.groups.count, 2)
        XCTAssertEqual(r.groups[0].files.map(\.path), ["a/b/c/photo copy.jpg", "a/photo.jpg", "z.jpg"])
        XCTAssertEqual(r.groups[0].reclaimableBytes, 600_000)
        XCTAssertNotNil(r.groups[0].sha256)
        XCTAssertEqual(r.groups[1].files.map(\.path), ["small1.txt", "x/small2.txt"])
        XCTAssertEqual(r.summary.duplicateFiles, 3)
        XCTAssertEqual(r.summary.reclaimableBytes, 600_004)
        XCTAssertEqual(try find(recursive: false).groups.count, 0, "top level only: one copy each")
    }

    func testSameSizeOrSameEdgesIsNotEnough() throws {
        writeData("a.bin", bytes(1000, seed: 1))
        writeData("b.bin", bytes(1000, seed: 2))
        // Same first and last 64 KB, a different middle.
        var one = bytes(400_000, seed: 3)
        var two = one
        one[200_000] = 0xAA
        two[200_000] = 0xBB
        writeData("c.bin", one)
        writeData("d.bin", two)
        let r = try find()
        XCTAssertEqual(r.groups, [])
        XCTAssertEqual(r.summary.filesScanned, 4)
        XCTAssertGreaterThan(r.summary.bytesHashed, 2 * 128 * 1024, "the middle was read to tell them apart")
    }

    func testHardLinksAreTheSameFileNotDuplicates() throws {
        let data = bytes(5000, seed: 9)
        let a = writeData("a.dat", data)
        try fm.linkItem(atPath: a, toPath: grant + "/b.dat")
        let r = try find()
        XCTAssertEqual(r.groups, [])
        XCTAssertEqual(r.sameFile.map(\.paths), [["a.dat", "b.dat"]])
        XCTAssertEqual(r.summary.hardLinkedNotRead, 2)
        XCTAssertEqual(r.summary.bytesHashed, 0, "a hard link's contents aren't read")
    }

    func testEmptyFilesAndSkippedKinds() throws {
        writeData("e1", Data())
        writeData("e2", Data())
        let data = bytes(2000, seed: 4)
        writeData("keep.bin", data)
        writeData("Tool.app/Contents/copy.bin", data)
        writeData("denied/copy.bin", data)
        writeData(".hidden/copy.bin", data)
        writeData("copy.bin", data, in: outside)
        try fm.createSymbolicLink(atPath: grant + "/out", withDestinationPath: outside)
        try fm.createSymbolicLink(atPath: grant + "/link.bin", withDestinationPath: grant + "/keep.bin")
        let r = try find()
        XCTAssertEqual(r.groups, [], "packages, denied and hidden folders, links: none looked in")
        XCTAssertEqual(r.summary.emptyFilesSkipped, 2)
        XCTAssertGreaterThanOrEqual(r.summary.skippedItems, 3)
        var limits = DuplicateFinder.Limits()
        limits.includeHidden = true
        XCTAssertEqual(try find(limits).groups.map { $0.files.map(\.path) }, [[".hidden/copy.bin", "keep.bin"]])
    }

    func testCapsAndCancellation() throws {
        for i in 0..<10 { writeData("f\(i).bin", bytes(10_000, seed: 5)) }
        var limits = DuplicateFinder.Limits()
        limits.maxFiles = 4
        let few = try find(limits)
        XCTAssertEqual(few.summary.stopped, .fileLimit)
        XCTAssertEqual(few.summary.filesScanned, 4)
        limits = DuplicateFinder.Limits()
        limits.maxBytesHashed = 25_000
        let budget = try find(limits)
        XCTAssertEqual(budget.summary.stopped, .byteLimit)
        XCTAssertLessThanOrEqual(budget.summary.bytesHashed, 25_000)
        var calls = 0
        let cancelled = try find { calls += 1; return calls > 3 }
        XCTAssertEqual(cancelled.summary.stopped, .cancelled)
        // Entries of any kind count: a folder of many names isn't read whole.
        for i in 0..<10 { mkdir("dirs/d\(i)") }
        limits = DuplicateFinder.Limits()
        limits.maxEntries = 5
        let entries = try find(limits)
        XCTAssertEqual(entries.summary.stopped, .fileLimit)
        XCTAssertLessThanOrEqual(entries.summary.filesScanned, 5)
    }

    func testPagesAreCompactAndBounded() throws {
        for g in 0..<30 {
            let d = bytes(100 + g, seed: UInt8(g))
            writeData("g\(g)/one.bin", d)
            writeData("g\(g)/two.bin", d)
        }
        let many = bytes(999, seed: 99)
        for i in 0..<15 { writeData("many/\(i).bin", many) }
        let r = try find()
        XCTAssertEqual(r.summary.groups, 31)
        let big = r.page(cursor: 0, maxGroups: 1)
        XCTAssertEqual(big.groups[0].copies, 15, "the most reclaimable first")
        XCTAssertEqual(big.groups[0].paths.count, 10)
        XCTAssertEqual(big.groups[0].morePaths, 5)
        let first = r.page(cursor: 1, maxGroups: 20, maxBytes: 100_000)
        XCTAssertEqual(first.groups.count, 20)
        XCTAssertEqual(first.nextCursor, "d21")
        XCTAssertEqual(first.groups[0].size, 129)
        let tight = r.page(cursor: 0, maxGroups: 20, maxBytes: 60)
        XCTAssertEqual(tight.groups.count, 1, "at least one group, then the byte budget")
        let short = r.page(cursor: 0, maxGroups: 1, maxPathsPerGroup: 1)
        XCTAssertEqual(short.groups[0].paths.count, 2, "at least two paths show a duplicate")
        let last = r.page(cursor: 21)
        XCTAssertEqual(last.groups.count, 10)
        XCTAssertNil(last.nextCursor)
    }
}

final class FolderFilesTests: FolderTestCase {
    private var files: FolderFiles { FolderFiles(walker: walker) }

    func testOneEntryPointForFoldersFilesAndDuplicates() throws {
        write("docs/a.pdf", "%PDF-1.4 x")
        write("docs/b.txt", "hello\nworld\n")
        write("docs/sub/c.pdf", "%PDF-1.4 x")
        write("docs/.DS_Store", "x")
        guard case .listing(let top) = try files.run(FolderQuery(components: ["docs"])) else { return XCTFail() }
        XCTAssertEqual(top.entries.map(\.path), ["docs/a.pdf", "docs/b.txt", "docs/sub"])
        XCTAssertEqual(top.entries.map(\.kind), [.file, .file, .directory])
        guard case .listing(let pdfs) = try files.run(FolderQuery(components: ["docs"], recursive: true, pattern: "*.PDF"))
        else { return XCTFail() }
        XCTAssertEqual(pdfs.entries.map(\.path), ["docs/a.pdf", "docs/sub/c.pdf"])
        guard case .listing(let hidden) = try files.run(FolderQuery(components: ["docs"], includeHidden: true))
        else { return XCTFail() }
        XCTAssertTrue(hidden.entries.map(\.path).contains("docs/.DS_Store"))
        guard case .info(let info) = try files.run(FolderQuery(components: ["docs", "b.txt"], hash: true))
        else { return XCTFail() }
        XCTAssertEqual(info.lineCount, 2)
        guard case .sha256 = info.hash else { return XCTFail("hash asked") }
        guard case .duplicates(let dups) = try files.run(FolderQuery(components: ["docs"], recursive: true, onlyDuplicates: true))
        else { return XCTFail() }
        XCTAssertEqual(dups.groups.map(\.paths), [["docs/a.pdf", "docs/sub/c.pdf"]])
        XCTAssertThrowsError(try files.run(FolderQuery(components: ["docs", "b.txt"], onlyDuplicates: true)))
        XCTAssertThrowsError(try files.run(FolderQuery(components: ["missing"])))
        XCTAssertThrowsError(try files.run(FolderQuery(components: ["denied"])), "invisible")
    }

    func testListingsArePaged() throws {
        for i in 0..<25 { write(String(format: "f%02d.txt", i), "x") }
        var f = files
        f.limits.pageEntries = 10
        guard case .listing(let p1) = try f.run(FolderQuery(components: [])) else { return XCTFail() }
        XCTAssertEqual(p1.entries.count, 10)
        XCTAssertEqual(p1.total, 25)
        XCTAssertEqual(p1.nextCursor, "l10")
        guard case .listing(let p3) = try f.run(FolderQuery(components: [], cursor: "l20")) else { return XCTFail() }
        XCTAssertEqual(p3.entries.map(\.path).first, "f20.txt")
        XCTAssertNil(p3.nextCursor)
        XCTAssertThrowsError(try f.run(FolderQuery(components: [], cursor: "d3")))
        XCTAssertThrowsError(try f.run(FolderQuery(components: [], cursor: "l-1")))
        f.limits.maxScan = 5
        guard case .listing(let capped) = try f.run(FolderQuery(components: [])) else { return XCTFail() }
        XCTAssertTrue(capped.scanTruncated)
        XCTAssertEqual(capped.total, 5)
    }
}
