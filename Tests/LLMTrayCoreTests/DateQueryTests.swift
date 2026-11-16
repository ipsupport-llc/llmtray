import XCTest
@testable import LLMTrayCore

final class DateQueryTests: XCTestCase {
    private let today = DateQuery.Day(year: 2026, month: 11, day: 16)

    private func iso(_ text: String, monthFirst: Bool = false) -> String? {
        DateQuery.parse(text, today: today, monthFirst: monthFirst)?.iso
    }

    func testForms() {
        for text in ["2024-04-10", "2024-04-10T12:30:00Z", "2024/04/10", "2024.4.10",
                     "Apr 10, 2024", "April 10, 2024", "Apr. 10th, 2024", "10 April 2024", "Wednesday, April 10, 2024",
                     "10.04.2024", "10-04-2024", "10.04.24", "10 апреля 2024", "10 апреля 2024 г.", "10-го апреля 2024",
                     "10 квітня 2024", "10. April 2024", "10 avril 2024", "apr 10 2024"] {
            XCTAssertEqual(iso(text), "2024-04-10", text)
        }
        XCTAssertEqual(iso("Sept 3, 2025"), "2025-09-03")
        XCTAssertEqual(iso("March 5"), "2026-03-05", "no year: this year")
        XCTAssertEqual(iso("tomorrow"), "2026-11-17")
        XCTAssertEqual(iso("вчера"), "2026-11-15")
        XCTAssertEqual(iso("Today"), "2026-11-16")
    }

    func testSlashOrder() {
        XCTAssertEqual(iso("04/10/2024", monthFirst: true), "2024-04-10")
        XCTAssertEqual(iso("04/10/2024", monthFirst: false), "2024-10-04")
        XCTAssertEqual(DateQuery.parse("04/10/2024", today: today, monthFirst: true)?.ambiguous, true)
        XCTAssertEqual(iso("13/04/2024", monthFirst: true), "2024-04-13", "a number over 12 is the day")
        XCTAssertEqual(iso("04/13/2024", monthFirst: false), "2024-04-13")
        XCTAssertEqual(DateQuery.parse("04/13/2024", today: today, monthFirst: false)?.ambiguous, false)
    }

    func testRejects() {
        for text in ["", "next friday", "2024-02-30", "31.04.2024", "Apr 2024 10 11", "banana 10 2024", "10/04", "April May 3 2024"] {
            XCTAssertNil(iso(text), text)
        }
        XCTAssertEqual(iso("2024-02-29"), "2024-02-29", "a leap day")
    }

    func testDescribe() {
        let day = DateQuery.Day(year: 2024, month: 4, day: 10)
        let out = DateQuery.describe(day, today: today)
        XCTAssertEqual(out["date"] as? String, "2024-04-10")
        XCTAssertEqual(out["weekday"] as? String, "Wednesday")
        XCTAssertEqual(out["today"] as? String, "2026-11-16")
        XCTAssertEqual(out["days_from_today"] as? Int, -950)
        XCTAssertNil(out["note"])
        XCTAssertEqual(DateQuery.days(from: today, to: DateQuery.Day(year: 2027, month: 1, day: 1)), 46)
        let ambiguous = DateQuery.describe(DateQuery.Day(year: 2024, month: 4, day: 10, ambiguous: true), today: today)
        XCTAssertEqual(ambiguous["note"] as? String, "read as April 10; the other order would be October 4")
    }

    func testTodayInZone() {
        // 2026-11-16 23:30 UTC is already the 17th in Kyiv.
        let now = Date(timeIntervalSince1970: 1_794_871_800)
        XCTAssertEqual(DateQuery.today(in: TimeZone(identifier: "UTC")!, now: now).iso, "2026-11-16")
        XCTAssertEqual(DateQuery.today(in: TimeZone(identifier: "Europe/Kyiv")!, now: now).iso, "2026-11-17")
        XCTAssertTrue(DateQuery.isMonthFirst(Locale(identifier: "en_US")))
        XCTAssertFalse(DateQuery.isMonthFirst(Locale(identifier: "ru_RU")))
    }
}
