import XCTest
@testable import LLMTrayCore

final class WhatsNewTests: XCTestCase {
    private let notes = [WhatsNew.Release(version: "0.8", items: [.init(title: "A", text: "B", symbol: "folder")])]

    private func action(_ app: String, seen: String?, fresh: Bool = false) -> WhatsNew.LaunchAction {
        WhatsNew.launchAction(appVersion: app, lastSeen: seen, freshInstall: fresh, releases: notes)
    }

    // MARK: Versions

    func testParsesMajorMinor() {
        XCTAssertEqual(WhatsNew.minorString("0.8.0"), "0.8")
        XCTAssertEqual(WhatsNew.minorString("0.8.0-beta.3"), "0.8")
        XCTAssertEqual(WhatsNew.minorString("0.10.1"), "0.10")
        XCTAssertEqual(WhatsNew.minorString("0.8"), "0.8")
        XCTAssertEqual(WhatsNew.minorVersion("0.10.1")?.minor, 10, "numbers, not text: 0.10 is after 0.9")
        XCTAssertNil(WhatsNew.minorString("dev"))
        XCTAssertNil(WhatsNew.minorString(""))
        XCTAssertNil(WhatsNew.minorString("1"))
    }

    // MARK: When it opens

    func testAFreshInstallOnlyRecordsTheVersion() {
        XCTAssertEqual(action("0.8.0", seen: nil, fresh: true), .record("0.8"), "the setup wizard runs instead")
        XCTAssertEqual(action("0.8.0-beta.2", seen: "0.8", fresh: true), .nothing, "a first run resumed after a relaunch")
    }

    func testAnUpgradeFromBeforeTheWindowShowsIt() {
        XCTAssertEqual(action("0.8.0", seen: nil), .show(notes[0]), "0.7.x stored nothing, but it's an existing install")
        XCTAssertEqual(action("0.8.0-beta.1", seen: nil), .show(notes[0]))
    }

    func testOncePerMinor() {
        XCTAssertEqual(action("0.8.0-beta.3", seen: "0.8"), .nothing, "a later beta of the minor it showed")
        XCTAssertEqual(action("0.8.1", seen: "0.8"), .nothing)
        XCTAssertEqual(action("0.8.0", seen: "0.9"), .nothing, "a downgrade doesn't show older notes")
    }

    func testANewerMinorShowsItsNotes() {
        XCTAssertEqual(action("0.8.0", seen: "0.7"), .show(notes[0]))
        let later = [WhatsNew.Release(version: "0.10", items: [])] + notes
        XCTAssertEqual(WhatsNew.launchAction(appVersion: "0.10.1", lastSeen: "0.9", freshInstall: false, releases: later),
                       .show(later[0]), "0.10 is newer than 0.9")
    }

    func testAMinorWithoutNotesIsRecordedNotShown() {
        XCTAssertEqual(action("0.9.0", seen: "0.8"), .record("0.9"), "no stale 0.8 notes on 0.9")
        XCTAssertEqual(action("dev", seen: nil), .nothing, "a dev build (no version) leaves it alone")
    }

    func testTheShippedNotes() {
        XCTAssertEqual(WhatsNew.latest.version, "0.8")
        XCTAssertEqual(WhatsNew.latest.items.map(\.title),
                       ["Project files", "Folders", "First-run setup", "Answer details", "Faster long chats", "Works offline"])
        for item in WhatsNew.latest.items {
            XCTAssertFalse(item.text.contains("!"), item.title)
        }
    }
}
