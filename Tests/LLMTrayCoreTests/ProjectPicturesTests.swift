import XCTest
@testable import LLMTrayCore

final class ProjectPicturesTests: XCTestCase {
    private var project: URL!
    private var source: URL!

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory.appendingPathComponent("pics-\(UUID().uuidString)")
        source = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: project)
        try? FileManager.default.removeItem(at: source)
    }

    private func checked(_ name: String, _ bytes: String) throws -> ProjectPictures.Checked {
        let url = source.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return .init(copy: url, name: name, width: 10, height: 20, thumbnail: Data("thumb".utf8))
    }

    func testAddListRemoveWithIdsNeverReused() throws {
        guard case .added(let a) = try ProjectPictures.add(try checked("a.png", "AAA"), to: project) else { return XCTFail() }
        guard case .added(let b) = try ProjectPictures.add(try checked("b.JPG", "BBB"), to: project) else { return XCTFail() }
        XCTAssertEqual([a.id, b.id], ["p1", "p2"])
        XCTAssertTrue(b.file.hasSuffix(".jpg"))
        XCTAssertEqual(ProjectPictures.file(of: "p2", in: project)?.picture.name, "b.JPG")
        let perms = try FileManager.default.attributesOfItem(atPath: ProjectPictures.file(of: "p1", in: project)!.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
        // The same bytes under another name: already there.
        XCTAssertEqual(try ProjectPictures.add(try checked("copy.png", "AAA"), to: project), .duplicate(a))
        try ProjectPictures.remove("p1", from: project)
        XCTAssertNil(ProjectPictures.file(of: "p1", in: project))
        guard case .added(let c) = try ProjectPictures.add(try checked("c.png", "CCC"), to: project) else { return XCTFail() }
        XCTAssertEqual(c.id, "p3", "p1 is never given again")
        let listing = ProjectPictures.listing(ProjectPictures.manifest(in: project), picturesUsable: true)
        XCTAssertEqual(listing, "Pictures: use one in a document as ![caption](project:<id>)\np2. b.JPG -- 10×20\np3. c.png -- 10×20")
        XCTAssertFalse(ProjectPictures.listing(ProjectPictures.manifest(in: project), picturesUsable: false).contains("document"))
        XCTAssertEqual(ProjectPictures.usage(project), 6)
    }

    func testTooLargeIsRefused() throws {
        let url = source.appendingPathComponent("big.png")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(ProjectPictures.maxBytes + 1))
        try h.close()
        XCTAssertThrowsError(try ProjectPictures.add(.init(copy: url, name: "big.png", width: 1, height: 1, thumbnail: nil), to: project))
        XCTAssertTrue(ProjectPictures.manifest(in: project).pictures.isEmpty)
    }

    func testReconcileAfterACrashMidAdd() throws {
        _ = try ProjectPictures.add(try checked("a.png", "AAA"), to: project)
        let dir = project.appendingPathComponent("pictures")
        // A crash between the rename and the manifest: an unlisted copy;
        // one in staging; and a listed copy gone.
        try Data("x".utf8).write(to: dir.appendingPathComponent("orphan.png"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("staging"), withIntermediateDirectories: true)
        try Data("y".utf8).write(to: dir.appendingPathComponent("staging/half.png"))
        _ = try ProjectPictures.add(try checked("b.png", "BBB"), to: project)
        try FileManager.default.removeItem(at: ProjectPictures.file(of: "p2", in: project)!.url)
        let r = try ProjectPictures.reconcile(project)
        XCTAssertEqual(r.dropped, 1)
        XCTAssertGreaterThanOrEqual(r.deleted, 2, "the orphan and p2's thumbnail")
        XCTAssertEqual(ProjectPictures.manifest(in: project).pictures.map(\.id), ["p1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("staging").path))
        XCTAssertTrue(ProjectPictures.isPicture(URL(fileURLWithPath: "/x/a.HEIC")))
        XCTAssertFalse(ProjectPictures.isPicture(URL(fileURLWithPath: "/x/a.svg")))
    }
}

final class ProjectPicturesIntegrationTests: XCTestCase {
    func testSortTakesPicturesAndRefusesHugeOnes() {
        let s = ProjectFileDrop.sort([
            (url: URL(fileURLWithPath: "/a/doc.pdf"), isDirectory: false, bytes: 10),
            (url: URL(fileURLWithPath: "/a/photo.HEIC"), isDirectory: false, bytes: 10),
            (url: URL(fileURLWithPath: "/a/huge.tif"), isDirectory: false, bytes: ProjectPictures.maxBytes + 1),
            (url: URL(fileURLWithPath: "/a/vector.svg"), isDirectory: false, bytes: 10),
        ])
        XCTAssertEqual(s.accepted.map(\.lastPathComponent), ["doc.pdf"])
        XCTAssertEqual(s.pictures.map(\.lastPathComponent), ["photo.HEIC"])
        XCTAssertEqual(s.tooLarge.map(\.lastPathComponent), ["huge.tif"])
        XCTAssertEqual(s.notSupported.map(\.lastPathComponent), ["vector.svg"])
    }

    func testPicturesOnlyProjectGetsTheListing() {
        var files = ProjectIndexSummary.empty
        files.pictures = 2
        XCTAssertEqual(ProjectFilesMode(featureOn: true, project: ProjectContext(id: UUID(), name: "P", files: files)), .listing)
        XCTAssertEqual(ProjectFilesMode(featureOn: true, project: ProjectContext(id: UUID(), name: "P", files: .empty)), .none)
    }

    @MainActor func testListingShowsPicturesAfterTheFiles() {
        var m = PictureManifest()
        m.pictures = [ProjectPicture(id: "p1", file: "x.png", thumbnail: nil, name: "logo.png", width: 64, height: 32, bytes: 1, sha256: "", added: Date())]
        let tmp = FileManager.default.temporaryDirectory
        let registry = ProjectIndexRegistry(directory: { tmp.appendingPathComponent($0.uuidString) }, idleDelay: 0.05)
        let service = ProjectFilesService(environment: .init(registry: registry, queryEmbedder: { nil }, wordsOnlyReason: { nil }, embedTimeout: 1))
        let none = service.listing([], from: 0, project: UUID(), budget: 10_000, note: nil, pictures: m, picturesUsable: true)
        XCTAssertTrue(none.preamble.contains("only pictures"))
        XCTAssertTrue(none.preamble.contains("p1. logo.png -- 64×32"))
        XCTAssertTrue(none.preamble.contains("project:<id>"))
        let empty = service.listing([], from: 0, project: UUID(), budget: 10_000, note: nil)
        XCTAssertEqual(empty.preamble, "This project has no files now.")
    }

    func testDocumentJobPlacesKnownPicturesOnly() {
        let spec = DocumentSpec(title: "T", content: "![Logo](project:p1) ![x](project:p9)", style: "report", charts: [], notes: [])
        let made = DocumentJob.make(spec, pictureKeys: ["p1": "p1.png"])
        XCTAssertTrue(made.job.html.contains("<img src=\"llmtray-doc://image/p1.png\" alt=\"Logo\">"))
        XCTAssertEqual(made.job.pictures, ["p1.png": "p1.png"])
        XCTAssertEqual(made.notes, ["Picture p9 couldn't be used."])
    }
}

final class ProjectPicturesReviewTests: XCTestCase {
    func testAnUnreadableManifestStopsChangesInsteadOfWipingTheStore() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("pm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: project) }
        let dir = project.appendingPathComponent("pictures")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("keep.png"))
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("pictures.json"))
        XCTAssertThrowsError(try ProjectPictures.reconcile(project))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("keep.png").path), "nothing deleted")
        XCTAssertTrue(ProjectPictures.manifest(in: project).pictures.isEmpty, "reading shows none")
    }

    func testAPrivateCopyIsTheLinksBytesAndCapped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString)")
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.png")
        try Data("PIXELS".utf8).write(to: target)
        let link = dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let copy = try ProjectPictures.privateCopy(of: link, into: out)
        let attrs = try FileManager.default.attributesOfItem(atPath: copy.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try Data(contentsOf: copy), Data("PIXELS".utf8))
    }

    func testOnlyPlacedPicturesCount() {
        let content = "![a](project:p1) `![b](project:p2)` [link](project:p3)\n```\n![c](project:p4)\n```"
        XCTAssertEqual(DocumentJob.pictureRefs(content), ["p1"])
        let made = DocumentJob.make(DocumentSpec(title: "T", content: content, style: "report", charts: [], notes: []))
        XCTAssertEqual(made.notes, ["Picture p1 couldn't be used."])
    }

    @MainActor func testPicturesArePagedWhenTheyDontFit() {
        var m = PictureManifest()
        m.pictures = (1...40).map { ProjectPicture(id: "p\($0)", file: "f\($0).png", thumbnail: nil, name: "picture-number-\($0).png",
                                                    width: 10, height: 10, bytes: 1, sha256: "\($0)", added: Date()) }
        let tmp = FileManager.default.temporaryDirectory
        let registry = ProjectIndexRegistry(directory: { tmp.appendingPathComponent($0.uuidString) }, idleDelay: 0.05)
        let service = ProjectFilesService(environment: .init(registry: registry, queryEmbedder: { nil }, wordsOnlyReason: { nil }, embedTimeout: 1))
        let first = service.picturePage(m, from: 0, project: UUID(), budget: 600, usable: false, head: nil)
        XCTAssertTrue(first.epilogue.contains("\"cursor\":\"pictures:"), first.epilogue)
        XCTAssertEqual(ProjectFiles.request(["cursor": "pictures:12"]), .success(.pictures(from: 12)))
        let rest = service.picturePage(m, from: 39, project: UUID(), budget: 600, usable: false, head: nil)
        XCTAssertTrue(rest.preamble.contains("p40."))
        XCTAssertTrue(rest.epilogue.isEmpty)
    }
}
