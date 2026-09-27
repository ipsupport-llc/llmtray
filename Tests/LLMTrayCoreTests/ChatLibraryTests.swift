import XCTest
@testable import LLMTrayCore

final class ChatLibraryTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: s)!
    }

    func testAgeGroups() {
        let now = date("2026-09-25T15:00:00Z")
        XCTAssertEqual(ChatAge.of(date("2026-09-25T00:10:00Z"), now: now, calendar: calendar), .today)
        XCTAssertEqual(ChatAge.of(date("2026-09-24T23:59:00Z"), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(ChatAge.of(date("2026-09-18T12:00:00Z"), now: now, calendar: calendar), .previous7Days)
        XCTAssertEqual(ChatAge.of(date("2026-08-27T12:00:00Z"), now: now, calendar: calendar), .previous30Days)
        XCTAssertEqual(ChatAge.of(date("2026-06-01T12:00:00Z"), now: now, calendar: calendar), .older)
        // A clock that moved back: still today, not a crash or "older".
        XCTAssertEqual(ChatAge.of(date("2026-09-26T09:00:00Z"), now: now, calendar: calendar), .today)
    }

    func testGroupingOrder() {
        let now = date("2026-09-25T15:00:00Z")
        let chats = [
            ChatSummary(id: UUID(), title: "old", updatedAt: date("2026-01-01T00:00:00Z"), searchText: ""),
            ChatSummary(id: UUID(), title: "morning", updatedAt: date("2026-09-25T08:00:00Z"), searchText: ""),
            ChatSummary(id: UUID(), title: "noon", updatedAt: date("2026-09-25T12:00:00Z"), searchText: ""),
        ]
        let groups = ChatAge.group(chats, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.0), [.today, .older])
        XCTAssertEqual(groups[0].1.map(\.title), ["noon", "morning"])
    }

    func testSearchMatchesEveryWord() {
        let chat = ChatSummary(id: UUID(), title: "Apple Developer ID", updatedAt: Date(),
                               searchText: "apple developer id где взять сертификат")
        XCTAssertTrue(chat.matches("developer"))
        XCTAssertTrue(chat.matches("Сертификат  APPLE"))
        XCTAssertFalse(chat.matches("apple android"))
        XCTAssertTrue(chat.matches(""))
    }

    func testPinsAndProjects() {
        var library = ChatLibrary()
        let a = UUID(), b = UUID()
        library.setPinned(a, true)
        library.setPinned(b, true)
        XCTAssertEqual(library.pinned, [b, a], "most recently pinned first")
        library.setPinned(a, false)
        XCTAssertEqual(library.pinned, [b])

        let project = library.addProject(named: "gh-sipmesh")
        library.move(a, to: project.id)
        XCTAssertEqual(library.projectOfChat[a], project.id)
        library.renameProject(project.id, to: "sipmesh")
        XCTAssertEqual(library.projects.first?.name, "sipmesh")
        library.deleteProject(project.id)
        XCTAssertNil(library.projectOfChat[a], "its chats go back to the recents")
        XCTAssertTrue(library.projects.isEmpty)
    }

    func testForgetAndPrune() {
        var library = ChatLibrary()
        let kept = UUID(), gone = UUID()
        let project = library.addProject(named: "p")
        library.setPinned(gone, true)
        library.move(gone, to: project.id)
        library.move(kept, to: project.id)
        library.prune(existing: [kept])
        XCTAssertEqual(library.pinned, [])
        XCTAssertEqual(library.projectOfChat, [kept: project.id])
        library.forget(kept)
        XCTAssertTrue(library.projectOfChat.isEmpty)
        XCTAssertEqual(library.projects.count, 1, "an empty project stays")
    }

    func testLibraryRoundTrip() throws {
        var library = ChatLibrary()
        let chat = UUID()
        let project = library.addProject(named: "work-azure")
        library.move(chat, to: project.id)
        library.setPinned(chat, true)
        let data = try JSONEncoder().encode(library)
        XCTAssertEqual(try JSONDecoder().decode(ChatLibrary.self, from: data), library)
    }

    func testLibraryFileIsReadableAndTolerant() throws {
        var library = ChatLibrary()
        let chat = UUID()
        let project = library.addProject(named: "p")
        library.move(chat, to: project.id)
        let json = String(decoding: try JSONEncoder().encode(library), as: UTF8.self)
        XCTAssertTrue(json.contains("\"\(chat.uuidString)\":\"\(project.id.uuidString)\""), "a chat's project as a JSON object")
        // A later version's extra fields, or a missing one: still read.
        let newer = #"{"pinned":[],"projects":[],"projectOfChat":{},"folders":[1,2]}"#
        XCTAssertEqual(try JSONDecoder().decode(ChatLibrary.self, from: Data(newer.utf8)), ChatLibrary())
        let partial = #"{"pinned":["\#(chat.uuidString)"]}"#
        XCTAssertEqual(try JSONDecoder().decode(ChatLibrary.self, from: Data(partial.utf8)).pinned, [chat])
    }

    func testLibraryFileSurvivesBadEntriesAndTheOldLayout() throws {
        let chat = UUID(), project = UUID()
        let bad = #"{"pinned":["not-a-uuid","\#(chat.uuidString)"],"projects":[{"name":"no id"},{"id":"\#(project.uuidString)","name":"ok"}]}"#
        let library = try JSONDecoder().decode(ChatLibrary.self, from: Data(bad.utf8))
        XCTAssertEqual(library.pinned, [chat])
        XCTAssertEqual(library.projects.map(\.name), ["ok"])
        let flat = #"{"projectOfChat":["\#(chat.uuidString)","\#(project.uuidString)"]}"#
        XCTAssertEqual(try JSONDecoder().decode(ChatLibrary.self, from: Data(flat.utf8)).projectOfChat, [chat: project])
    }

    func testProjectInstructionsDecodeBothWays() throws {
        let project = UUID(), chat = UUID()
        // Written before instructions existed: none.
        let old = #"{"projects":[{"id":"\#(project.uuidString)","name":"p","createdAt":"2026-09-01T10:00:00Z"}],"pinned":[],"projectOfChat":{"\#(chat.uuidString)":"\#(project.uuidString)"}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fromOld = try decoder.decode(ChatLibrary.self, from: Data(old.utf8))
        XCTAssertEqual(fromOld.projects.first?.instructions, "")
        XCTAssertEqual(fromOld.projectOfChat, [chat: project])
        // A wrong type drops the instructions, not the project.
        let odd = #"{"projects":[{"id":"\#(project.uuidString)","name":"p","instructions":42}]}"#
        XCTAssertEqual(try decoder.decode(ChatLibrary.self, from: Data(odd.utf8)).projects.map(\.name), ["p"])

        // Written now: read back, and by the decoder of a build from before.
        var library = fromOld
        library.setInstructions(project, "Answer in Russian.")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(library)
        XCTAssertEqual(try decoder.decode(ChatLibrary.self, from: data).projects.first?.instructions, "Answer in Russian.")
        let older = try decoder.decode(OlderLibrary.self, from: data)
        XCTAssertEqual(older.projects.map(\.id), [project])
        XCTAssertEqual(older.projects.map(\.name), ["p"])
    }

    /// library.json as the build before instructions decoded it.
    private struct OlderLibrary: Decodable {
        struct Project: Decodable {
            var id: UUID
            var name: String
            var createdAt: Date
            private enum CodingKeys: String, CodingKey { case id, name, createdAt }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(UUID.self, forKey: .id)
                name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
                createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            }
        }
        var projects: [Project]
    }

    func testProjectContextFollowsTheLibrary() {
        var library = ChatLibrary()
        let chat = UUID(), other = UUID()
        let a = library.addProject(named: "a"), b = library.addProject(named: "b")
        library.setInstructions(a.id, "Be brief.")
        XCTAssertNil(library.projectContext(forChat: chat), "in no project")
        library.move(chat, to: a.id)
        XCTAssertEqual(library.projectContext(forChat: chat),
                       ProjectContext(id: a.id, name: "a", instructions: "Be brief.", hasSearchableFiles: false))
        library.move(chat, to: b.id)
        XCTAssertEqual(library.projectContext(forChat: chat)?.id, b.id, "moved: the other project")
        XCTAssertEqual(library.projectContext(forChat: chat)?.instructions, "")
        library.projectOfChat[other] = UUID()
        XCTAssertNil(library.projectContext(forChat: other), "a project that doesn't exist")
        library.deleteProject(b.id)
        XCTAssertNil(library.projectContext(forChat: chat), "deleted: projectless")
    }

    func testSystemPromptOrder() {
        let project = ProjectContext(id: UUID(), name: "Contracts", instructions: "  Cite the clause.\n")
        let prompt = chatSystemPrompt(profile: "You are helpful.", project: project, toolUsePolicy: "Call a tool only when needed.")
        XCTAssertEqual(prompt, "You are helpful.\n\nInstructions for this chat's project, \"Contracts\":\nCite the clause.\n\nCall a tool only when needed.")
        // No tools: no policy; no profile prompt: the instructions first.
        XCTAssertEqual(chatSystemPrompt(profile: " ", project: project, toolUsePolicy: nil),
                       "Instructions for this chat's project, \"Contracts\":\nCite the clause.")
        // No project, or one without instructions: as before.
        let bare = ProjectContext(id: UUID(), name: "Empty", instructions: " \n")
        XCTAssertEqual(chatSystemPrompt(profile: "P", project: bare, toolUsePolicy: "T"), "P\n\nT")
        XCTAssertEqual(chatSystemPrompt(profile: "P", project: nil, toolUsePolicy: nil), "P")
        XCTAssertEqual(chatSystemPrompt(profile: "", project: nil, toolUsePolicy: nil), "")
    }

    func testCleanedTitle() {
        XCTAssertEqual(cleanedChatTitle("\"Где взять Apple Developer ID.\""), "Где взять Apple Developer ID")
        XCTAssertEqual(cleanedChatTitle("Title: **License comparison**\nSome explanation"), "License comparison")
        XCTAssertEqual(cleanedChatTitle("  \n«Размерность и ритм»  "), "Размерность и ритм")
        XCTAssertNil(cleanedChatTitle("  \"\"  "))
        let long = cleanedChatTitle(String(repeating: "a", count: 100), maxLength: 20)!
        XCTAssertEqual(long.count, 20)
        XCTAssertTrue(long.hasSuffix("…"))
    }
}
