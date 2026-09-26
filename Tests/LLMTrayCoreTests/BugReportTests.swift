import XCTest
@testable import LLMTrayCore

final class BugReportTests: XCTestCase {
    func testTextHasSubjectDescriptionSectionsAndNoHome() {
        let report = BugReport(
            product: "LLMTray", version: "0.7.1-beta.12", description: "  Server died after an image.  ",
            sections: [
                .init("System", [("macOS", "27.2"), ("Memory", "26 GB")]),
                .init("Model", [("Path", "/Users/alice/Models/gemma")]),
            ],
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let text = report.text(home: "/Users/alice")
        XCTAssertEqual(report.subject, "LLMTray 0.7.1-beta.12 — bug report")
        XCTAssertTrue(text.hasPrefix("LLMTray 0.7.1-beta.12 — bug report\n1970-01-01T00:00:00Z"))
        XCTAssertTrue(text.contains("What happened\n-------------\nServer died after an image.\n"))
        XCTAssertTrue(text.contains("macOS   27.2\nMemory  26 GB"))
        XCTAssertTrue(text.contains("Path  ~/Models/gemma"))
        XCTAssertFalse(text.contains("alice"))
    }

    func testEmptyDescription() {
        let text = BugReport(product: "LLMTray", version: "1", description: " \n", sections: []).text(home: "/Users/x")
        XCTAssertTrue(text.contains("(not described)"))
    }

    func testTailCutsAtALineStart() {
        let log = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let tail = BugReport.tail(log, maxBytes: 40)
        XCTAssertTrue(tail.hasPrefix("[… earlier output cut …]\nline "))
        XCTAssertTrue(tail.hasSuffix("line 100"))
        XCTAssertEqual(BugReport.tail("short", maxBytes: 40), "short")
    }
}
