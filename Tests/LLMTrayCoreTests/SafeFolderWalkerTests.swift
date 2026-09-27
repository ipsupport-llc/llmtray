import Foundation
import XCTest
@testable import LLMTrayCore

final class SafeFolderWalkerTests: FolderTestCase {
    func testComponentsRefuseEscapesInsteadOfNormalizing() throws {
        XCTAssertEqual(try SafeFolderWalker.components(""), [])
        XCTAssertEqual(try SafeFolderWalker.components("."), [])
        XCTAssertEqual(try SafeFolderWalker.components("a/b c/d.txt"), ["a", "b c", "d.txt"])
        for bad in ["..", "a/../b", "../outside", "a/./b", "/etc/passwd", "a//b", "a/", "a\u{0}b",
                    String(repeating: "x", count: 256)] {
            XCTAssertThrowsError(try SafeFolderWalker.components(bad), bad)
        }
    }

    func testResolvesInsideAndRecordsTheChain() throws {
        write("a/b/file.txt", "hi")
        let item = try walker.resolve(["a", "b", "file.txt"])
        XCTAssertEqual(item.entry?.kind, .file)
        XCTAssertEqual(item.entry?.identity, identity(grant + "/a/b/file.txt"))
        XCTAssertEqual(item.parent.chain, [root.identity, identity(grant + "/a")!, identity(grant + "/a/b")!])
        XCTAssertNil(try walker.resolve(["a", "missing"]).entry)
    }

    func testAHeldFolderIsStillInsideOnlyWhileItsPathReachesIt() throws {
        mkdir("a/b")
        let held = try walker.openDirectory(["a", "b"])
        XCTAssertTrue(walker.stillInside(held))
        // Moved out while held: the descriptor follows it, the grant doesn't.
        try fm.moveItem(atPath: grant + "/a/b", toPath: outside + "/b")
        XCTAssertFalse(walker.stillInside(held))
        // Another folder under the old name isn't it.
        mkdir("a/b")
        XCTAssertFalse(walker.stillInside(held))
    }

    func testReadsThroughAHeldFolderThatLeftTheGrantAreRefused() throws {
        write("a/f.txt", "inside")
        let dir = try walker.openDirectory(["a"])
        let item = try walker.resolve(["a", "f.txt"])
        try fm.moveItem(atPath: grant + "/a", toPath: outside + "/a")
        XCTAssertThrowsError(try walker.entries(of: dir))
        XCTAssertThrowsError(try walker.openFile(item))
        // Back in its place: readable again.
        try fm.moveItem(atPath: outside + "/a", toPath: grant + "/a")
        XCTAssertEqual(try walker.entries(of: dir).map(\.name), ["f.txt"])
        XCTAssertNoThrow(try walker.openFile(item))
    }

    func testASymlinkedFolderIsNeverEntered() throws {
        write("secret.txt", "outside", in: outside)
        try fm.createSymbolicLink(atPath: grant + "/link", withDestinationPath: outside)
        XCTAssertThrowsError(try walker.resolve(["link", "secret.txt"])) {
            XCTAssertEqual($0 as? FolderAccessError, .symlink(grant + "/link"))
        }
        // Listed as a link, not followed.
        XCTAssertEqual(try walker.resolve(["link"]).entry?.kind, .symlink)
        // A symlink to a file isn't opened either.
        try fm.createSymbolicLink(atPath: grant + "/filelink", withDestinationPath: outside + "/secret.txt")
        let item = try walker.resolve(["filelink"])
        XCTAssertEqual(item.entry?.kind, .symlink)
        XCTAssertThrowsError(try walker.openFile(item))
    }

    func testAFolderSwappedForASymlinkAfterCheckingFailsClosed() throws {
        write("a/file.txt", "inside")
        let before = try walker.openDirectory(["a"])
        // The swap: "a" becomes a link to the outside folder.
        try fm.moveItem(atPath: grant + "/a", toPath: base + "/moved-a")
        try fm.createSymbolicLink(atPath: grant + "/a", withDestinationPath: outside)
        XCTAssertThrowsError(try walker.openDirectory(["a"], expected: before.chain))
        // Replaced by another real folder: the identity catches it.
        try fm.removeItem(atPath: grant + "/a")
        mkdir("a")
        XCTAssertThrowsError(try walker.openDirectory(["a"], expected: before.chain)) {
            XCTAssertEqual($0 as? FolderAccessError, .changed(grant + "/a"))
        }
    }

    func testTheGrantRootReplacedIsRefused() throws {
        try fm.moveItem(atPath: grant, toPath: base + "/old")
        try fm.createDirectory(atPath: grant, withIntermediateDirectories: false)
        XCTAssertThrowsError(try walker.openRoot()) { XCTAssertEqual($0 as? FolderAccessError, .changed(grant)) }
    }

    func testHardLinksAreFlagged() throws {
        let target = write("real.txt", "shared", in: outside)
        try fm.linkItem(atPath: target, toPath: grant + "/link.txt")
        let entry = try walker.resolve(["link.txt"]).entry
        XCTAssertEqual(entry?.kind, .file)
        XCTAssertEqual(entry?.stat.isHardLinked, true)
        write("single.txt", "one")
        XCTAssertEqual(try walker.resolve(["single.txt"]).entry?.stat.isHardLinked, false)
    }

    func testPackagesAreOneOpaqueItem() throws {
        for pkg in ["Tool.app", "Plug.bundle"] {
            write("\(pkg)/Contents/Info.plist", "<plist/>")
            XCTAssertEqual(try walker.resolve([pkg]).entry?.kind, .package, pkg)
            XCTAssertThrowsError(try walker.resolve([pkg, "Contents", "Info.plist"]), pkg) {
                XCTAssertEqual($0 as? FolderAccessError, .insidePackage(grant + "/" + pkg))
            }
        }
        XCTAssertThrowsError(try SafeFolderWalker.makeRoot(path: grant + "/Tool.app", denylist: denylist))
        XCTAssertThrowsError(try SafeFolderWalker.makeRoot(path: grant + "/Tool.app/Contents", denylist: denylist),
                             "nor a folder inside one")
    }

    func testFinderAliasesAreNotFollowed() throws {
        write("target.txt", "outside", in: outside)
        let alias = URL(fileURLWithPath: grant + "/target alias")
        let bookmark = try URL(fileURLWithPath: outside + "/target.txt").bookmarkData(
            options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        let item = try walker.resolve(["target alias"])
        XCTAssertEqual(item.entry?.kind, .alias)
        XCTAssertThrowsError(try walker.openFile(item))
    }

    func testAVolumeChangeStopsTheWalk() throws {
        // Mount points can't be made in a test: the rule on made-up stats.
        let parent = EntryStat(identity: FileIdentity(device: 1, inode: 10), mode: S_IFDIR | 0o755)
        let sameVolume = EntryStat(identity: FileIdentity(device: 1, inode: 11), mode: S_IFDIR | 0o755)
        let otherVolume = EntryStat(identity: FileIdentity(device: 2, inode: 2), mode: S_IFDIR | 0o755)
        let link = EntryStat(identity: FileIdentity(device: 1, inode: 12), mode: S_IFLNK | 0o755)
        let file = EntryStat(identity: FileIdentity(device: 1, inode: 13), mode: S_IFREG | 0o644)
        XCTAssertNoThrow(try SafeFolderWalker.checkStep(parent: parent, child: sameVolume, display: "a"))
        XCTAssertThrowsError(try SafeFolderWalker.checkStep(parent: parent, child: otherVolume, display: "Volume")) {
            XCTAssertEqual($0 as? FolderAccessError, .mountPoint("Volume"))
        }
        XCTAssertThrowsError(try SafeFolderWalker.checkStep(parent: parent, child: link, display: "l")) {
            XCTAssertEqual($0 as? FolderAccessError, .symlink("l"))
        }
        XCTAssertThrowsError(try SafeFolderWalker.checkStep(parent: parent, child: file, display: "f")) {
            XCTAssertEqual($0 as? FolderAccessError, .notADirectory("f"))
        }
    }

    func testDeniedSubtreesAreInvisibleInsideAGrant() throws {
        write(".ssh/id_rsa", "key")
        write("login.keychain", "k")
        write("visible.txt", "v")
        let names = try walker.entries(of: walker.openRoot()).map(\.name).sorted()
        XCTAssertEqual(names, ["visible.txt"])
        XCTAssertThrowsError(try walker.resolve(["denied", "secret.txt"])) {
            XCTAssertEqual($0 as? FolderAccessError, .notFound(grant + "/denied"))
        }
        XCTAssertNil(try walker.resolve(["denied"]).entry)
        XCTAssertNil(try walker.resolve([".SSH"]).entry, "names compared insensitively")
        XCTAssertThrowsError(try SafeFolderWalker.makeRoot(path: grant + "/denied", denylist: denylist))
        XCTAssertThrowsError(try SafeFolderWalker.makeRoot(path: base, denylist: denylist), "ungrantable")
        // A grant under a denied folder, reached through a symlink, is refused
        // (realpath, then the walk sees the denied identity).
        mkdir("denied/inner")
        try fm.createSymbolicLink(atPath: outside + "/sneaky", withDestinationPath: grant + "/denied/inner")
        XCTAssertThrowsError(try SafeFolderWalker.makeRoot(path: outside + "/sneaky", denylist: denylist))
    }

    func testTheStandardListRefusesSystemAndPrivatePlaces() throws {
        let home = NSHomeDirectory()
        let list = FolderDenylist.standard(home: home)
        var refused = ["/", "/System", "/Library", "/usr", "/private", "/private/tmp", "/tmp", "/var",
                       "/Users", home, home + "/Library", home + "/Library/Application Support",
                       grant!, NSTemporaryDirectory()]
        let dataView = "/System/Volumes/Data" + home
        if fm.fileExists(atPath: dataView) { refused.append(dataView) }
        for dir in ["/.ssh", "/.gnupg", "/Downloads"].map({ home + $0 }) where fm.fileExists(atPath: dir) {
            refused.append("/System/Volumes/Data" + dir)
        }
        for path in refused where fm.fileExists(atPath: path) {
            XCTAssertThrowsError(try SafeFolderWalker.makeRoot(path: path, denylist: list), path)
        }
        // Firmlinks: the Data volume's view is the same folder by identity.
        if let a = Posix.lstatPath("/Users"), let b = Posix.lstatPath("/System/Volumes/Data/Users") {
            XCTAssertEqual(a.identity, b.identity)
        }
        XCTAssertTrue(list.isDenied(name: "Keychains"))
        XCTAssertTrue(list.isDenied(name: "login.keychain-db"))
        XCTAssertFalse(list.isDenied(name: "notes.txt"))
    }

    func testEntriesAndKinds() throws {
        write("f.txt", "x")
        mkdir("d")
        try fm.createSymbolicLink(atPath: grant + "/l", withDestinationPath: "f.txt")
        XCTAssertEqual(mkfifo(grant + "/fifo", 0o600), 0)
        let kinds = Dictionary(uniqueKeysWithValues: try walker.entries(of: walker.openRoot()).map { ($0.name, $0.kind) })
        XCTAssertEqual(kinds, ["f.txt": .file, "d": .directory, "l": .symlink, "fifo": .other])
        XCTAssertThrowsError(try walker.openFile(walker.resolve(["fifo"])))
    }

    func testADeniedFolderMadeAfterTheListIsStillDenied() throws {
        let list = FolderDenylist(paths: [grant + "/later"])
        let w = SafeFolderWalker(root: root, denylist: list)
        write("later/secret.txt", "s")
        XCTAssertNil(try w.resolve(["later"]).entry)
        XCTAssertThrowsError(try w.resolve(["later", "secret.txt"]))
        XCTAssertFalse(try w.entries(of: w.openRoot()).map(\.name).contains("later"))
    }
}
