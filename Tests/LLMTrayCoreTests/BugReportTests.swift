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

    func testServerLogLosesChatContent() {
        let log = """
            2026-09-24 03:12:44,100 - INFO - Starting httpd at 127.0.0.1 on port 8765...
            2026-09-24 03:12:44,101 - DEBUG - Incoming Request Body: {"messages": [{"content": "my secret question"}]}
            127.0.0.1 - - [24/Sep/2026 03:12:44] "POST /v1/chat/completions HTTP/1.1" 200 -
            2026-09-24 03:12:45,101 - DEBUG - Incoming Request Body: {
            \t"messages": [
            \t\t{"role": "user", "content": "another secret"}
            \t]
            }
            2026-09-24 03:12:46,000 - INFO - Prompt processing progress: 10/10
            stray {"prompt": "leak"}
            """
        let clean = BugReport.withoutChatContent(log)
        XCTAssertFalse(clean.contains("secret"))
        XCTAssertFalse(clean.contains("leak"))
        XCTAssertTrue(clean.contains("[verbose log record removed]"))
        XCTAssertTrue(clean.contains("Starting httpd"))
        XCTAssertTrue(clean.contains("\"POST /v1/chat/completions HTTP/1.1\" 200"), "the access line after a body stays")
        XCTAssertTrue(clean.contains("Prompt processing progress: 10/10"))
    }

    func testVerboseRecordsDroppedWhole() {
        let log = """
            2026-09-24 03:12:45,000 - DEBUG - my answer starts
            and the generated text goes on
            ---
            Error: still the answer
            over lines
            2026-09-24 03:12:46,000 - DEBUG - Outgoing Response: {"choices": [1]}
            127.0.0.1 - - [24/Sep/2026 03:12:46] "POST /v1/chat/completions HTTP/1.1" 200 -
            2026-09-24 03:12:47,000 - INFO - done
            """
        let clean = BugReport.withoutChatContent(log)
        XCTAssertFalse(clean.contains("answer"))
        XCTAssertFalse(clean.contains("generated text"))
        XCTAssertFalse(clean.contains("still the answer"), "a markdown rule or 'Error:' in the answer doesn't end the record")
        XCTAssertFalse(clean.contains("choices"))
        XCTAssertTrue(clean.contains("[verbose log record removed]"))
        XCTAssertTrue(clean.contains("\"POST /v1/chat/completions HTTP/1.1\" 200"))
        XCTAssertTrue(clean.contains("INFO - done"))
    }

    func testRedactOnAPathBoundary() {
        XCTAssertEqual(BugReport.redact("/Users/alice/x /Users/alice2/y /Users/alice", home: "/Users/alice", user: "alice"), "~/x /Users/alice2/y ~")
        XCTAssertEqual(BugReport.redact("/Volumes/Models/alice/org/model", home: "/Users/alice", user: "alice"), "/Volumes/Models/USER/org/model")
        XCTAssertEqual(BugReport.redact(#"{"path":"/Volumes/Models/alice"}"#, home: "/Users/alice", user: "alice"), #"{"path":"/Volumes/Models/USER"}"#)
        XCTAssertEqual(BugReport.redact("/Volumes/a/model", home: "/Users/a", user: "a"), "/Volumes/USER/model")
        XCTAssertTrue(BugReport.hasVerboseRecords("x\n2026-09-24 03:12:45,000 - DEBUG - y"))
        XCTAssertFalse(BugReport.hasVerboseRecords("2026-09-24 03:12:45,000 - INFO - y"))
    }

    func testCutLogAndLookalikeLinesDontLeak() {
        // The log cut mid DEBUG record: its continuation comes first.
        let cut = """
            the tail of a private answer
            2026-09-24 03:12:46 my private answer, with a date
            ---
            2026-09-24 03:12:47,000 - INFO - done
            Traceback (most recent call last):
              File "server.py", line 1
            2026-09-24 03:12:48,000 - DEBUG - more private text
            2026-09-24 03:12:46 still private
            2026-09-24 03:12:49,000 - ERROR - boom
            """
        let clean = BugReport.withoutChatContent(cut)
        XCTAssertFalse(clean.contains("private"))
        XCTAssertTrue(clean.contains("INFO - done"))
        XCTAssertTrue(clean.contains("Traceback (most recent call last):"), "a kept record's traceback stays")
        XCTAssertTrue(clean.contains("ERROR - boom"))
    }

    func testCrashReportRedaction() {
        let ips = #"{"crashReporterKey" : "ABC-123", "sleepWakeUUID":"X-Y", "path":"\/Users\/alice\/Library\/x.so", "userID" : 501}"#
        let clean = BugReport.redactCrashReport(ips, home: "/Users/alice")
        XCTAssertFalse(clean.contains("ABC-123"))
        XCTAssertFalse(clean.contains("X-Y"))
        XCTAssertFalse(clean.contains("alice"))
        XCTAssertTrue(clean.contains(#""crashReporterKey":"removed""#))
    }

    func testSecretsLeaveTheArguments() {
        XCTAssertEqual(
            BugReport.withoutSecrets(["-m", "mlx_lm.server", "--api-key", "abc", "--hf-token=hf_x", "--port", "8766", "sk-abcdefghijklmn"]),
            ["-m", "mlx_lm.server", "--api-key", "[removed]", "--hf-token=[removed]", "--port", "8766", "[removed]"]
        )
    }

    func testUserNameAsAWord() {
        XCTAssertEqual(BugReport.withoutUserName("Profile  alice\n--- profile: alice ---\nalicex", user: "alice"),
                       "Profile  USER\n--- profile: USER ---\nalicex")
    }

    func testTailCutsAtALineStart() {
        let log = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let tail = BugReport.tail(log, maxBytes: 40)
        XCTAssertTrue(tail.hasPrefix("[… earlier output cut …]\nline "))
        XCTAssertTrue(tail.hasSuffix("line 100"))
        XCTAssertEqual(BugReport.tail("short", maxBytes: 40), "short")
    }
}
