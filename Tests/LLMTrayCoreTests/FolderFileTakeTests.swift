import Foundation
import XCTest
@testable import LLMTrayCore

/// `files(view)` and `files(add_to_project)` (adr/0014, "Looking at an
/// image, adding to the project"): a whole file out of a grant, read by
/// descriptor, never through a link, never past the grant.
final class FolderFileTakeTests: FolderTestCase {
    private var service: FolderToolService!
    private let chat = FolderChat(id: "chat-1", temporary: false)

    override func setUpWithError() throws {
        try super.setUpWithError()
        service = FolderToolService(grants: FolderGrants(storeURL: URL(fileURLWithPath: base + "/grants.json")),
                                    denylist: denylist, journal: ChangeJournal(directory: URL(fileURLWithPath: base + "/journal")),
                                    home: base)
        try service.grants.grant(root, level: .read, lifetime: .always, chatID: nil)
    }

    private func take(_ path: String, view: Bool = false, add: Bool = false) async -> FolderToolAnswer {
        await service.files(FolderTools.FilesRequest(path: path, view: view, addToProject: add), chat: chat, callKey: UUID().uuidString,
                            byteBudget: 16_000, ask: { _ in nil })
    }

    func testViewReadsTheWholeFile() async {
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        writeData("photo.png", bytes)
        guard case .image(let data, let path) = await take("~/grant/photo.png", view: true) else { return XCTFail("an image") }
        XCTAssertEqual(data, bytes)
        XCTAssertEqual(path, "~/grant/photo.png")
    }

    func testAddToProjectIsCheckedFirstAndCopiedOnlyAfter() async throws {
        write("notes.md", "# AI programming")
        guard case .projectCandidate(let raw, let path, let bytes, let identity) = await take("~/grant/notes.md", add: true) else {
            return XCTFail("a candidate")
        }
        XCTAssertEqual(path, "~/grant/notes.md")
        XCTAssertEqual(bytes, 16)
        // Replaced while the user was asked: not the file they said yes to.
        write("other.md", "replaced")
        try fm.removeItem(atPath: grant + "/notes.md")
        try fm.moveItem(atPath: grant + "/other.md", toPath: grant + "/notes.md")
        if case .fileForProject = await service.copyForProject(raw: raw, identity: identity, chat: chat, callKey: "k") {
            XCTFail("copied a file the user didn't say yes to")
        }
        guard case .projectCandidate(_, _, _, let current) = await take("~/grant/notes.md", add: true) else {
            return XCTFail("a candidate")
        }
        guard case .fileForProject(let url, _) = await service.copyForProject(raw: raw, identity: current, chat: chat, callKey: "k") else {
            return XCTFail("a copy")
        }
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.lastPathComponent, "notes.md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "replaced")
        XCTAssertTrue(url.path.hasPrefix(FolderToolService.takeDirectory.path), url.path)
        XCTAssertTrue(fm.fileExists(atPath: grant + "/notes.md"), "the original stays")
        // A format the project doesn't take: refused before anyone is asked.
        writeData("movie.mov", Data(count: 10))
        if case .projectCandidate = await take("~/grant/movie.mov", add: true) { XCTFail("not a project format") }
        // Outside the chat's grants: no copy, nothing asked.
        write("secret.txt", "outside", in: outside)
        if case .fileForProject = await service.copyForProject(raw: outside + "/secret.txt", identity: identity, chat: chat, callKey: "k") {
            XCTFail("copied from outside the grant")
        }
    }

    func testSecretsHardLinksArentTaken() async throws {
        write("id_ed25519", "-----BEGIN OPENSSH PRIVATE KEY-----")
        write(".env", "TOKEN=x")
        let photo = writeData("photo.png", Data(count: 64))
        try fm.linkItem(atPath: photo, toPath: outside + "/same.png")
        for answer in [await take("~/grant/id_ed25519", add: true), await take("~/grant/.env", add: true),
                       await take("~/grant/photo.png", view: true), await take("~/grant/photo.png", add: true)] {
            switch answer {
            case .image, .projectCandidate, .fileForProject: XCTFail("taken: \(answer)")
            default: break
            }
        }
        XCTAssertThrowsError(try FolderFileTake.copy(walker, ["id_ed25519"], into: FolderToolService.takeDirectory, maxBytes: 1 << 20))
    }

    func testNeverThroughALinkOrPastTheGrant() async throws {
        write("secret.txt", "outside", in: outside)
        try fm.createSymbolicLink(atPath: grant + "/link.png", withDestinationPath: outside + "/secret.txt")
        for answer in [await take("~/grant/link.png", view: true), await take("~/grant/link.png", add: true)] {
            switch answer {
            case .image, .fileForProject: XCTFail("read through a link: \(answer)")
            default: XCTAssertFalse(answer.text.contains("outside"), answer.text)
            }
        }
        // Denied inside the grant, and a folder, aren't taken either.
        for answer in [await take("~/grant/denied/secret.txt", add: true), await take("~/grant/denied", add: true)] {
            if case .fileForProject = answer { XCTFail("taken: \(answer)") }
        }
        // Outside any grant: asked for (and refused here), never read.
        if case .image = await take(outside + "/secret.txt", view: true) { XCTFail("outside the grant") }
    }

    func testTooLargeIsRefused() throws {
        let path = writeData("big.bin", Data(count: 2048))
        XCTAssertThrowsError(try FolderFileTake.read(walker, ["big.bin"], maxBytes: 1024)) { error in
            XCTAssertEqual(error as? FolderFileTake.TakeError, .tooLarge(self.walker.display(["big.bin"]), limit: 1024))
        }
        XCTAssertTrue(fm.fileExists(atPath: path))
    }

    func testDeclaredOnlyWhereTheyApply() {
        func params(_ view: Bool, _ add: Bool) -> Set<String> {
            let function = FolderTools.filesDefinition(view: view, addToProject: add)["function"] as? [String: Any]
            let properties = (function?["parameters"] as? [String: Any])?["properties"] as? [String: Any]
            return Set(properties?.keys.map { $0 } ?? [])
        }
        XCTAssertFalse(params(false, false).contains("view"))
        XCTAssertFalse(params(false, false).contains("add_to_project"))
        XCTAssertTrue(params(true, false).contains("view"))
        XCTAssertFalse(params(true, false).contains("add_to_project"))
        XCTAssertTrue(params(false, true).contains("add_to_project"))
        XCTAssertFalse(params(true, true).contains("hidden"))
        let request = FolderTools.filesRequest(ToolArgumentParser.parse(#"{"path":"~/Downloads/a.pdf","add":true}"#,
                                                                        schema: FolderTools.filesSchema).values)
        XCTAssertTrue(request.addToProject)
        XCTAssertFalse(request.view)
    }
}
