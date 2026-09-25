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
