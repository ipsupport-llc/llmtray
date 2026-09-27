import XCTest
@testable import LLMTrayCore

final class ReviewSubmissionTests: XCTestCase {
    private func make(rating: Int = 5, text: String = "Great app", author: String = "", version: String = "0.7.1") throws -> ReviewSubmission {
        try ReviewSubmission(rating: rating, text: text, author: author, version: version)
    }

    private func error(_ block: () throws -> Void) -> ReviewValidationError? {
        do { try block(); return nil } catch { return error as? ReviewValidationError }
    }

    func testRating() {
        XCTAssertEqual(error { _ = try make(rating: 0) }, .rating)
        XCTAssertEqual(error { _ = try make(rating: 6) }, .rating)
        for r in 1...5 { XCTAssertNil(error { _ = try make(rating: r) }) }
    }

    func testTextIsTrimmedAndLineBreaksNormalized() throws {
        let s = try make(text: " \t\n Line one\r\nLine two\rLine three\n\u{00A0}\u{3000}")
        XCTAssertEqual(s.text, "Line one\nLine two\nLine three")
        XCTAssertEqual(ReviewSubmission.normalizedText("a\r\r\nb"), "a\n\nb")
        XCTAssertEqual(ReviewSubmission.normalizedText("a\n\rb"), "a\n\nb")
    }

    func testEmptyText() {
        XCTAssertEqual(error { _ = try make(text: "") }, .emptyText)
        XCTAssertEqual(error { _ = try make(text: " \r\n\t\u{2028} ") }, .emptyText)
    }

    func testTabsInsideTextAllowedOtherControlsNot() throws {
        XCTAssertEqual(try make(text: "a\tb").text, "a\tb")
        XCTAssertEqual(error { _ = try make(text: "a\u{0}b") }, .textControlCharacter)
        XCTAssertEqual(error { _ = try make(text: "a\u{7F}b") }, .textControlCharacter)
        XCTAssertEqual(error { _ = try make(text: "a\u{85}b") }, .textControlCharacter)   // C1, not trimmed inside
        XCTAssertEqual(error { _ = try make(text: "a\u{1B}[0mb") }, .textControlCharacter)
        // Format characters (Cf) aren't controls to Go.
        XCTAssertNoThrow(try make(text: "a\u{200B}b\u{200D}"))
    }

    func testLengthCountsUnicodeScalars() throws {
        XCTAssertNoThrow(try make(text: String(repeating: "a", count: 2000)))
        XCTAssertEqual(error { _ = try make(text: String(repeating: "a", count: 2001)) }, .textTooLong(2001))
        // A family emoji is 1 Character but 7 scalars (Go runes): 286 of them are 2002.
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(family.unicodeScalars.count, 7)
        XCTAssertEqual(error { _ = try make(text: String(repeating: family, count: 286)) }, .textTooLong(2002))
        XCTAssertNoThrow(try make(text: String(repeating: family, count: 285)))
        // e + combining acute: 1 Character, 2 scalars.
        let combining = "e\u{301}"
        XCTAssertEqual(error { _ = try make(text: String(repeating: combining, count: 1001)) }, .textTooLong(2002))
        XCTAssertNoThrow(try make(text: String(repeating: combining, count: 1000)))
        // "\r\n" is one Character in Swift and becomes one "\n": counted once.
        XCTAssertEqual(ReviewSubmission.textLength("a\r\nb"), 3)
        XCTAssertEqual(ReviewSubmission.textLength("  ab  "), 2)
    }

    func testAuthor() throws {
        XCTAssertEqual(try make(author: "  Roman  ").author, "Roman")
        XCTAssertEqual(try make(author: "").author, "")
        XCTAssertNoThrow(try make(author: String(repeating: "é", count: 64)))
        XCTAssertEqual(error { _ = try make(author: String(repeating: "x", count: 65)) }, .authorTooLong)
        XCTAssertEqual(error { _ = try make(author: String(repeating: "e\u{301}", count: 33)) }, .authorTooLong)
        XCTAssertEqual(error { _ = try make(author: "Ro\nman") }, .authorControlCharacter)
        XCTAssertEqual(error { _ = try make(author: "Ro\tman") }, .authorControlCharacter)
        // Trimmed first, like the server.
        XCTAssertEqual(try make(author: "\nRoman\t").author, "Roman")
    }

    func testVersionSanitized() throws {
        XCTAssertEqual(try make(version: "0.7.1-beta.12").version, "0.7.1-beta.12")
        XCTAssertEqual(try make(version: "1.0+build.5").version, "1.0+build.5")
        XCTAssertEqual(try make(version: "1.0 (5)").version, "")
        XCTAssertEqual(try make(version: String(repeating: "1", count: 33)).version, "")
        XCTAssertEqual(try make(version: String(repeating: "1", count: 32)).version.count, 32)
        XCTAssertEqual(try make(version: "1.0é").version, "")
    }

    func testBodyHasExactlyTheFiveFields() throws {
        let body = try make(rating: 4, text: "Nice / fast\nreally", author: "A", version: "0.7.1").body()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["product", "rating", "text", "version", "author"])
        XCTAssertEqual(json["product"] as? String, "llmtray")
        XCTAssertEqual(json["rating"] as? Int, 4)
        XCTAssertEqual(json["text"] as? String, "Nice / fast\nreally")
        XCTAssertNil(json["website"])
        XCTAssertLessThanOrEqual(body.count, 16 * 1024)
    }

    func testLargestBodyFitsTheLimit() throws {
        let body = try make(text: String(repeating: "😀", count: 2000), author: String(repeating: "😀", count: 64)).body()
        XCTAssertLessThanOrEqual(body.count, ReviewSubmission.maxBodyBytes)
        let escapes = try make(text: "a" + String(repeating: "\n", count: 1998) + "b").body()
        XCTAssertLessThanOrEqual(escapes.count, ReviewSubmission.maxBodyBytes)
    }
}

final class ReviewDraftTests: XCTestCase {
    private func submission(_ text: String, rating: Int = 5, author: String = "") throws -> ReviewSubmission {
        try ReviewSubmission(rating: rating, text: text, author: author, version: "1.0")
    }

    func testSameContentKeepsTheKey() throws {
        var draft = ReviewDraft(rating: 5, text: "Good")
        let first = draft.key(for: try submission("Good"))
        XCTAssertEqual(draft.key(for: try submission("Good")), first)
        // Whitespace that normalizes away is the same body.
        XCTAssertEqual(draft.key(for: try submission("  Good\r\n")), first)
    }

    func testChangedContentGetsANewKey() throws {
        var draft = ReviewDraft()
        let first = draft.key(for: try submission("Good"))
        let text = draft.key(for: try submission("Good!"))
        XCTAssertNotEqual(text, first)
        let rating = draft.key(for: try submission("Good!", rating: 4))
        XCTAssertNotEqual(rating, text)
        let author = draft.key(for: try submission("Good!", rating: 4, author: "Me"))
        XCTAssertNotEqual(author, rating)
        // Back to an earlier content: still a new key (the server keeps the old body for the old key).
        XCTAssertNotEqual(draft.key(for: try submission("Good")), first)
    }

    func testDropKey() throws {
        var draft = ReviewDraft()
        let first = draft.key(for: try submission("Good"))
        draft.dropKey()
        XCTAssertNil(draft.idempotencyKey)
        XCTAssertNotEqual(draft.key(for: try submission("Good")), first)
    }

    func testCodableKeepsTheKey() throws {
        var draft = ReviewDraft(rating: 3, text: "Okay", author: "Z")
        let key = draft.key(for: try submission("Okay", rating: 3, author: "Z"))
        var decoded = try JSONDecoder().decode(ReviewDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(decoded, draft)
        XCTAssertEqual(decoded.key(for: try submission("Okay", rating: 3, author: "Z")), key)
        XCTAssertTrue(ReviewDraft().isEmpty)
        XCTAssertFalse(decoded.isEmpty)
    }

    func testDraftPrefRoundTrip() throws {
        let suite = "llmtray.tests.reviewDraft"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(defaults[Pref.reviewDraft])
        var draft = ReviewDraft(rating: 4, text: "Kept")
        _ = draft.key(for: try submission("Kept", rating: 4))
        defaults[Pref.reviewDraft] = try JSONEncoder().encode(draft)
        let stored = try XCTUnwrap(defaults[Pref.reviewDraft])
        XCTAssertEqual(try JSONDecoder().decode(ReviewDraft.self, from: stored), draft)
        defaults[Pref.reviewDraft] = nil
        XCTAssertNil(defaults.object(forKey: Pref.reviewDraft.name))
    }
}

final class ReviewOutcomeTests: XCTestCase {
    private func classify(_ status: Int?, _ body: String? = nil, retryAfter: String? = nil) -> ReviewOutcome {
        ReviewOutcome.classify(status: status, body: body.map { Data($0.utf8) }, retryAfter: retryAfter)
    }

    func testAccepted() {
        XCTAssertEqual(classify(202, #"{"id":"r_1","status":"pending"}"#), .accepted(id: "r_1"))
        XCTAssertEqual(classify(202, "not json"), .accepted(id: nil))
        XCTAssertFalse(classify(202).isRetryable)
    }

    func testRejectedCodes() {
        for code in ["invalid_rating", "invalid_text", "invalid_version", "invalid_author", "invalid_product",
                     "invalid_request", "invalid_idempotency_key"] {
            let outcome = classify(400, #"{"error":"\#(code)"}"#)
            XCTAssertEqual(outcome, .rejected(code: code))
            XCTAssertFalse(outcome.isRetryable)
        }
        XCTAssertEqual(classify(413, #"{"error":"payload_too_large"}"#), .rejected(code: "payload_too_large"))
        XCTAssertEqual(classify(413), .rejected(code: "payload_too_large"))
        XCTAssertEqual(classify(415, "<html>"), .rejected(code: "unsupported_media_type"))
        XCTAssertEqual(classify(404), .rejected(code: "http_404"))
        XCTAssertEqual(classify(422, #"{"error":"something_else"}"#), .rejected(code: "something_else"))
    }

    func testKeyReused() {
        XCTAssertEqual(classify(422, #"{"error":"idempotency_key_reused"}"#), .keyReused)
    }

    func testRateLimited() {
        XCTAssertEqual(classify(429, #"{"error":"rate_limited"}"#, retryAfter: "1800"), .rateLimited(seconds: 1800))
        XCTAssertEqual(classify(429, retryAfter: " 60 "), .rateLimited(seconds: 60))
        XCTAssertEqual(classify(429, retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT"), .rateLimited(seconds: nil))
        XCTAssertEqual(classify(429), .rateLimited(seconds: nil))
        XCTAssertEqual(classify(429, retryAfter: "-5"), .rateLimited(seconds: nil))
    }

    func testRetryLater() {
        XCTAssertEqual(classify(nil), .retryLater)
        XCTAssertEqual(classify(500, #"{"error":"internal"}"#), .retryLater)
        XCTAssertEqual(classify(502, "<html>Bad gateway</html>"), .retryLater)
        XCTAssertEqual(classify(503), .retryLater)
        XCTAssertEqual(classify(408), .retryLater)
        XCTAssertTrue(classify(503).isRetryable)
    }
}

final class ReviewFeedTests: XCTestCase {
    func testDecodes() throws {
        let json = #"""
            {"summary":{"count":2,"average":4.5},"reviews":[
              {"id":"b","rating":5,"text":"Great\nreally","version":"0.7.1","author":"","created_at":"2026-09-20T10:00:00Z"},
              {"id":"a","rating":4,"text":"Good","version":"","author":"Ann","created_at":"2026-09-19T10:00:00Z"}]}
            """#
        let feed = try JSONDecoder().decode(ReviewFeed.self, from: Data(json.utf8))
        XCTAssertEqual(feed.summary, .init(count: 2, average: 4.5))
        XCTAssertEqual(feed.reviews.map(\.id), ["b", "a"])
        XCTAssertEqual(feed.reviews[0].createdAt, "2026-09-20T10:00:00Z")
        XCTAssertEqual(feed.reviews[1].author, "Ann")
    }

    func testEmpty() throws {
        let feed = try JSONDecoder().decode(ReviewFeed.self, from: Data(#"{"summary":{"count":0,"average":null},"reviews":[]}"#.utf8))
        XCTAssertEqual(feed.summary.count, 0)
        XCTAssertNil(feed.summary.average)
        XCTAssertTrue(feed.reviews.isEmpty)
    }
}

final class ReviewPromptPolicyTests: XCTestCase {
    private let day = 86400.0
    private let launch = Date(timeIntervalSince1970: 1_000_000)

    private func ask(days: Double, answers: Int = 20, snoozedUntil: Date? = nil, never: Bool = false,
                     reviewed: Bool = false, firstLaunch: Date? = nil) -> Bool {
        ReviewPromptPolicy.shouldPrompt(now: launch.addingTimeInterval(days * day), firstLaunch: firstLaunch ?? launch,
                                        answers: answers, snoozedUntil: snoozedUntil, neverAsk: never, reviewed: reviewed)
    }

    func testNeedsAWeekAndTwentyAnswers() {
        XCTAssertFalse(ask(days: 6.9))
        XCTAssertFalse(ask(days: 30, answers: 19))
        XCTAssertTrue(ask(days: 7))
        XCTAssertTrue(ask(days: 7, answers: 500))
        XCTAssertFalse(ReviewPromptPolicy.shouldPrompt(now: launch, firstLaunch: nil, answers: 99, snoozedUntil: nil,
                                                       neverAsk: false, reviewed: false))
    }

    func testNeverAndReviewed() {
        XCTAssertFalse(ask(days: 30, never: true))
        XCTAssertFalse(ask(days: 30, reviewed: true))
    }

    func testLaterWaitsFourteenDays() {
        let later = ReviewPromptPolicy.snoozed(from: launch.addingTimeInterval(8 * day))
        XCTAssertEqual(later, launch.addingTimeInterval(22 * day))
        XCTAssertFalse(ask(days: 21.9, snoozedUntil: later))
        XCTAssertTrue(ask(days: 22, snoozedUntil: later))
    }
}

/// The client against a stub: nothing reaches ipsupport.us.
final class ReviewClientTests: XCTestCase {
    final class Stub: URLProtocol {
        struct Reply {
            var status: Int
            var headers: [String: String] = [:]
            var body = Data()
            var error: URLError?
        }

        static var reply = Reply(status: 202)
        static var requests: [URLRequest] = []
        static var bodies: [Data] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
            Self.bodies.append(Self.readBody(request))
            let reply = Self.reply
            if let error = reply.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// URLSession hands a protocol the body as a stream.
        static func readBody(_ request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }
    }

    private let stubEndpoint = URL(string: "http://review-stub.invalid/api/reviews")!
    private var client: ReviewClient!

    override func setUp() {
        Stub.requests = []
        Stub.bodies = []
        Stub.reply = .init(status: 202)
        client = ReviewClient(endpoint: stubEndpoint,
                              session: ReviewClient.makeSession { $0.protocolClasses = [Stub.self] },
                              userAgent: "LLMTray/0.7.1")
    }

    private func submission() throws -> ReviewSubmission {
        try ReviewSubmission(rating: 5, text: "Works\r\nwell", author: " Ann ", version: "0.7.1")
    }

    func testSendsHeadersAndExactBody() async throws {
        Stub.reply = .init(status: 202, body: Data(#"{"id":"r_9","status":"pending"}"#.utf8))
        let key = UUID()
        let outcome = await client.submit(try submission(), key: key)
        XCTAssertEqual(outcome, .accepted(id: "r_9"))
        let request = try XCTUnwrap(Stub.requests.first)
        XCTAssertEqual(request.url, stubEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), key.uuidString.lowercased())
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "LLMTray/0.7.1")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Stub.bodies[0]) as? [String: Any])
        XCTAssertEqual(json as NSDictionary, ["product": "llmtray", "rating": 5, "text": "Works\nwell",
                                              "version": "0.7.1", "author": "Ann"] as NSDictionary)
    }

    func testTimeoutIsFifteenSeconds() throws {
        XCTAssertEqual(ReviewClient.makeSession().configuration.timeoutIntervalForRequest, 15)
        XCTAssertNil(ReviewClient.makeSession().configuration.httpCookieStorage)
        XCTAssertEqual(try client.request(try submission(), key: UUID()).httpBody, try submission().body())
    }

    func testErrorsAreClassified() async throws {
        Stub.reply = .init(status: 400, body: Data(#"{"error":"invalid_text"}"#.utf8))
        var outcome = await client.submit(try submission(), key: UUID())
        XCTAssertEqual(outcome, .rejected(code: "invalid_text"))
        Stub.reply = .init(status: 429, headers: ["Retry-After": "1200"], body: Data(#"{"error":"rate_limited"}"#.utf8))
        outcome = await client.submit(try submission(), key: UUID())
        XCTAssertEqual(outcome, .rateLimited(seconds: 1200))
        Stub.reply = .init(status: 503)
        outcome = await client.submit(try submission(), key: UUID())
        XCTAssertEqual(outcome, .retryLater)
        Stub.reply = .init(status: 0, error: URLError(.notConnectedToInternet))
        outcome = await client.submit(try submission(), key: UUID())
        XCTAssertEqual(outcome, .retryLater)
        Stub.reply = .init(status: 0, error: URLError(.timedOut))
        outcome = await client.submit(try submission(), key: UUID())
        XCTAssertEqual(outcome, .retryLater)
    }

    func testFeed() async throws {
        Stub.reply = .init(status: 200, body: Data(#"{"summary":{"count":1,"average":5},"reviews":[{"id":"a","rating":5,"text":"x","version":"1","author":"","created_at":"2026-09-01T00:00:00Z"}]}"#.utf8))
        let feed = try await client.feed()
        XCTAssertEqual(feed.summary.count, 1)
        XCTAssertEqual(Stub.requests.first?.url?.absoluteString, "http://review-stub.invalid/api/reviews?product=llmtray")
        XCTAssertEqual(Stub.requests.first?.httpMethod, "GET")
    }
}
