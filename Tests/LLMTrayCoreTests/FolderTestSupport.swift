import Foundation
import XCTest
@testable import LLMTrayCore

/// A temporary folder tree for the folder-tool tests: `grant` is the granted
/// folder, `outside` a sibling the grant must never reach. Removed in
/// `tearDown`. Nothing outside it is touched.
class FolderTestCase: XCTestCase {
    var base: String!
    var grant: String!
    var outside: String!
    var denylist: FolderDenylist!
    var root: FolderRoot!
    let fm = FileManager.default

    override func setUpWithError() throws {
        // Canonical (/private/var/...): grant roots are canonical paths.
        let tmp = Posix.realpath(NSTemporaryDirectory())!
        base = tmp + "/llmtray-folders-\(UUID().uuidString)"
        grant = base + "/grant"
        outside = base + "/outside"
        try fm.createDirectory(atPath: grant, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        // The standard list denies /private, where temp folders live: tests
        // use their own, with a denied folder inside the grant.
        try fm.createDirectory(atPath: grant + "/denied", withIntermediateDirectories: true)
        write("denied/secret.txt", "secret")
        denylist = FolderDenylist(paths: [grant + "/denied"], names: [".ssh"], extensions: ["keychain"],
                                  ungrantablePaths: [base])
        root = try SafeFolderWalker.makeRoot(path: grant, denylist: denylist)
    }

    override func tearDownWithError() throws {
        if let base { try? fm.removeItem(atPath: base) }
    }

    var walker: SafeFolderWalker { SafeFolderWalker(root: root, denylist: denylist) }

    @discardableResult
    func write(_ relative: String, _ text: String, in dir: String? = nil) -> String {
        writeData(relative, Data(text.utf8), in: dir)
    }

    @discardableResult
    func writeData(_ relative: String, _ data: Data, in dir: String? = nil) -> String {
        let path = (dir ?? grant) + "/" + relative
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: path, contents: data), path)
        return path
    }

    func mkdir(_ relative: String) {
        XCTAssertNoThrow(try fm.createDirectory(atPath: grant + "/" + relative, withIntermediateDirectories: true))
    }

    func exists(_ relative: String) -> Bool { Posix.lstatPath(grant + "/" + relative) != nil }

    func identity(_ path: String) -> FileIdentity? { Posix.lstatPath(path)?.identity }

    func loc(_ path: String) throws -> FolderLocation { try FolderLocation(root: root, path: path) }

    /// Whether the temp volume compares names case-insensitively (APFS's
    /// default), decided by the file system.
    var volumeIsCaseInsensitive: Bool {
        let probe = base + "/CaseProbe"
        fm.createFile(atPath: probe, contents: Data())
        defer { try? fm.removeItem(atPath: probe) }
        return fm.fileExists(atPath: base + "/caseprobe")
    }

    func names(_ relative: String = "") -> [String] {
        ((try? fm.contentsOfDirectory(atPath: relative.isEmpty ? grant : grant + "/" + relative)) ?? []).sorted()
    }
}
