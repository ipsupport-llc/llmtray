import Foundation

/// A user review of the app, as POST https://ipsupport.us/api/reviews takes
/// it: exactly these five fields (any other is a 400). The rules mirror the
/// server's (trim, "\r\n" to "\n", counts in Unicode scalars -- Go's runes
/// -- and no control characters but "\n" and "\t" in the text), so what
/// passes here passes there.
public struct ReviewSubmission: Codable, Equatable {
    public static let product = "llmtray"
    public static let maxTextLength = 2000
    public static let maxAuthorLength = 64
    public static let maxVersionLength = 32
    public static let maxBodyBytes = 16 * 1024

    public let product: String
    public let rating: Int
    public let text: String
    public let version: String
    public let author: String

    /// Validated and normalized: what's sent is what the server stores.
    public init(rating: Int, text: String, author: String, version: String) throws {
        guard (1...5).contains(rating) else { throw ReviewValidationError.rating }
        let text = Self.normalizedText(text)
        let length = text.unicodeScalars.count
        guard length > 0 else { throw ReviewValidationError.emptyText }
        guard length <= Self.maxTextLength else { throw ReviewValidationError.textTooLong(length) }
        guard !text.unicodeScalars.contains(where: { Self.isControl($0) && $0 != "\n" && $0 != "\t" }) else {
            throw ReviewValidationError.textControlCharacter
        }
        let author = Self.trimmed(author)
        guard author.unicodeScalars.count <= Self.maxAuthorLength else { throw ReviewValidationError.authorTooLong }
        guard !author.unicodeScalars.contains(where: Self.isControl) else { throw ReviewValidationError.authorControlCharacter }
        self.product = Self.product
        self.rating = rating
        self.text = text
        self.version = Self.sanitizedVersion(version)
        self.author = author
    }

    /// The JSON body: the five fields, nothing else.
    public func body() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maxBodyBytes else { throw ReviewValidationError.tooLarge }
        return data
    }

    /// Line breaks as "\n" (a lone "\r" is a control character to the
    /// server), then trimmed as the server trims.
    public static func normalizedText(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var afterCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" {
                scalars.append("\n")
                afterCR = true
                continue
            }
            if !(afterCR && scalar == "\n") { scalars.append(scalar) }
            afterCR = false
        }
        return trimmed(String(scalars))
    }

    /// Go's strings.TrimSpace: leading and trailing White_Space scalars.
    public static func trimmed(_ string: String) -> String {
        let scalars = Array(string.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let last = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[first...last])
        return String(view)
    }

    /// The length the server counts (and the window shows): Unicode scalars
    /// of the text as it would be sent.
    public static func textLength(_ text: String) -> Int {
        normalizedText(text).unicodeScalars.count
    }

    /// The app's version as the server takes it (≤ 32 of [0-9A-Za-z.+-]),
    /// or empty -- it's optional -- when it isn't one.
    public static func sanitizedVersion(_ version: String) -> String {
        let version = trimmed(version)
        let allowed = version.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x2B || byte == 0x2D
        }
        return allowed && version.utf8.count <= maxVersionLength ? version : ""
    }

    /// Go's unicode.IsControl: general category Cc.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }
}

public enum ReviewValidationError: Error, Equatable {
    case rating
    case emptyText
    /// The length, in the server's count.
    case textTooLong(Int)
    case textControlCharacter
    case authorTooLong
    case authorControlCharacter
    case tooLarge
}

/// What the user is writing, kept until the server accepts it, with the
/// idempotency key of the submission it was last sent as: a retry of the
/// same content reuses the key (the server answers it once), anything else
/// changed gets a new one.
public struct ReviewDraft: Codable, Equatable {
    /// 0: not picked yet.
    public var rating: Int
    public var text: String
    public var author: String
    public private(set) var idempotencyKey: UUID?
    /// What idempotencyKey was issued for.
    public private(set) var keyedSubmission: ReviewSubmission?

    public init(rating: Int = 0, text: String = "", author: String = "") {
        self.rating = rating
        self.text = text
        self.author = author
    }

    public var isEmpty: Bool { rating == 0 && text.isEmpty && author.isEmpty }

    /// The key to send `submission` with: the one already issued for it,
    /// or a new one.
    public mutating func key(for submission: ReviewSubmission) -> UUID {
        if let key = idempotencyKey, keyedSubmission == submission { return key }
        let key = UUID()
        idempotencyKey = key
        keyedSubmission = submission
        return key
    }

    /// The server has seen the key with another body (422
    /// idempotency_key_reused): the next send gets a new one.
    public mutating func dropKey() {
        idempotencyKey = nil
        keyedSubmission = nil
    }
}

/// What a POST's answer means for the app.
public enum ReviewOutcome: Equatable {
    /// 202: pending moderation.
    case accepted(id: String?)
    /// A 4xx that sending again won't fix; `code` is the server's error
    /// code (invalid_text, ...), or one for the status when it gave none.
    case rejected(code: String)
    /// 429: 3 an hour, 10 a day per IP. Retry-After, when it said.
    case rateLimited(seconds: Int?)
    /// 422 idempotency_key_reused: the same key went with another body.
    case keyReused
    /// 5xx, a timeout, no network: the same key again later.
    case retryLater

    public var isRetryable: Bool {
        switch self {
        case .accepted, .rejected: return false
        case .rateLimited, .keyReused, .retryLater: return true
        }
    }

    /// `status` nil: no answer (a timeout, no network).
    public static func classify(status: Int?, body: Data?, retryAfter: String?) -> ReviewOutcome {
        guard let status else { return .retryLater }
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let code = json?["error"] as? String
        switch status {
        case 200..<300:
            return .accepted(id: json?["id"] as? String)
        case 429:
            let seconds = retryAfter.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 0 ? $0 : nil }
            return .rateLimited(seconds: seconds)
        case 422 where code == "idempotency_key_reused":
            return .keyReused
        case 408, 500...599:
            return .retryLater
        case 400..<500:
            if let code, !code.isEmpty { return .rejected(code: code) }
            switch status {
            case 413: return .rejected(code: "payload_too_large")
            case 415: return .rejected(code: "unsupported_media_type")
            default: return .rejected(code: "http_\(status)")
            }
        default:
            return .retryLater
        }
    }
}

/// GET https://ipsupport.us/api/reviews?product=llmtray: the published
/// reviews, newest first.
public struct ReviewFeed: Codable, Equatable {
    public struct Summary: Codable, Equatable {
        public var count: Int
        public var average: Double?
    }

    public struct Review: Codable, Equatable, Identifiable {
        public var id: String
        public var rating: Int
        public var text: String
        public var version: String
        public var author: String
        /// As the server sends it (RFC 3339).
        public var createdAt: String

        enum CodingKeys: String, CodingKey {
            case id, rating, text, version, author
            case createdAt = "created_at"
        }
    }

    public var summary: Summary
    public var reviews: [Review]
}

/// When the chat asks, once, for a review: after a week of use and 20
/// answers, never again once reviewed or declined, again 14 days after a
/// "Later".
public enum ReviewPromptPolicy {
    public static let minimumDays = 7.0
    public static let minimumAnswers = 20
    public static let snoozeDays = 14.0

    public static func shouldPrompt(now: Date, firstLaunch: Date?, answers: Int, snoozedUntil: Date?,
                                    neverAsk: Bool, reviewed: Bool) -> Bool {
        guard !neverAsk, !reviewed, let firstLaunch, answers >= minimumAnswers else { return false }
        guard now.timeIntervalSince(firstLaunch) >= minimumDays * 86400 else { return false }
        if let snoozedUntil, now < snoozedUntil { return false }
        return true
    }

    public static func snoozed(from now: Date) -> Date {
        now.addingTimeInterval(snoozeDays * 86400)
    }
}

/// Sends a review and reads the published ones. A session of its own: no
/// cookies, no cache, a 15 s timeout.
public struct ReviewClient {
    public static let endpoint = URL(string: "https://ipsupport.us/api/reviews")!

    public static func makeSession(_ configure: (URLSessionConfiguration) -> Void = { _ in }) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        configure(config)
        return URLSession(configuration: config)
    }

    public var endpoint: URL
    public var session: URLSession
    /// The User-Agent: the app and its version, not the system's.
    public var userAgent: String

    public init(endpoint: URL = ReviewClient.endpoint, session: URLSession = ReviewClient.makeSession(), userAgent: String = "LLMTray") {
        self.endpoint = endpoint
        self.session = session
        self.userAgent = userAgent
    }

    public func request(_ submission: ReviewSubmission, key: UUID) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try submission.body()
        return request
    }

    public func submit(_ submission: ReviewSubmission, key: UUID) async -> ReviewOutcome {
        guard let request = try? request(submission, key: key) else { return .rejected(code: "payload_too_large") }
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return ReviewOutcome.classify(status: http?.statusCode, body: data, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
        } catch {
            return .retryLater
        }
    }

    public func feed(product: String = ReviewSubmission.product) async throws -> ReviewFeed {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "product", value: product)]
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(ReviewFeed.self, from: data)
    }
}
