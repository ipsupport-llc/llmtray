import CryptoKit
import Foundation

/// The public supporters list (adr/0017): the people who chose to be named
/// after tipping, as ipsupport-api publishes them. Signed by the API
/// (Ed25519 over the exact body, `X-Signature`), so the app shows only
/// what the maintainer's server approved; `version` only goes up, so an
/// older copy can't be replayed to hide names.
public struct SupportersList: Codable, Equatable, Sendable {
    public var version: Int
    public var updated: String
    public var supporters: [Supporter]

    public init(version: Int, updated: String, supporters: [Supporter]) {
        self.version = version
        self.updated = updated
        self.supporters = supporters
    }

    public static let empty = SupportersList(version: 0, updated: "", supporters: [])

    /// Founding Supporters first, then Pro, then Coffee; each by `since`.
    public var ordered: [Supporter] {
        supporters.sorted {
            ($0.tier.rank, $0.since, $0.name.lowercased()) < ($1.tier.rank, $1.since, $1.name.lowercased())
        }
    }
}

public struct Supporter: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var tier: SupporterTier
    /// https only (anything else is dropped when the list is read).
    public var link: String?
    /// "YYYY-MM".
    public var since: String

    public var id: String { "\(tier.rawValue)|\(since)|\(name)" }

    public init(name: String, tier: SupporterTier, link: String? = nil, since: String) {
        self.name = name
        self.tier = tier
        self.link = link
        self.since = since
    }

    /// The link to open, only if it's an https URL with a host.
    public var linkURL: URL? {
        guard let link, let url = URL(string: link), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }
}

public enum SupporterTier: String, Codable, CaseIterable, Sendable {
    case founding, pro, coffee

    var rank: Int { SupporterTier.allCases.firstIndex(of: self)! }

    /// The App Store product ids (adr/0017 §2).
    public var productID: String { "us.ipsupport.llmtray.tip.\(self)" }

    public init?(productID: String) {
        guard let tier = SupporterTier.allCases.first(where: { $0.productID == productID }) else { return nil }
        self = tier
    }
}

public enum SupportersVerifier {
    /// ipsupport-api's signing key for the list (its private half lives
    /// only on the server).
    public static let publicKey = "Es2/kpr+52KPq/NqWsnlPCsmwciMWj8EluiyYsAG7/w="

    public enum Failure: Error, Equatable {
        case badSignature
        case malformed
    }

    /// The list, if `signature` (base64) signs exactly `body` with `key`
    /// and the body is a well-formed list. Names are trimmed and capped;
    /// entries without a name, and links that aren't https, are dropped.
    public static func verify(body: Data, signature: String, publicKey key: String = publicKey) throws -> SupportersList {
        guard let keyData = Data(base64Encoded: key),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespaces)),
              publicKey.isValidSignature(sig, for: body)
        else { throw Failure.badSignature }
        return try decode(body)
    }

    /// A list trusted as it is: the copy bundled in the (code-signed) app.
    public static func decode(_ body: Data) throws -> SupportersList {
        guard var list = try? JSONDecoder().decode(SupportersList.self, from: body) else { throw Failure.malformed }
        list.supporters = list.supporters.compactMap { supporter in
            var s = supporter
            s.name = String(s.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            guard !s.name.isEmpty else { return nil }
            if s.linkURL == nil { s.link = nil }
            return s
        }
        return list
    }

    /// Whether `candidate` may replace `current`: strictly newer only.
    public static func isNewer(_ candidate: SupportersList, than current: SupportersList) -> Bool {
        candidate.version > current.version
    }
}

/// What's sent to be listed (adr/0017 §4): the name the user typed, an
/// optional https link, the tier and the proof of payment -- never an Apple
/// ID, an email or a device identifier.
public struct SupporterListing: Encodable, Sendable {
    public enum Proof: Sendable {
        /// StoreKit 2's `Transaction.jwsRepresentation`.
        case appStore(jws: String)
        /// A GitHub Sponsors sponsor's (public) login.
        case github(login: String)
    }

    public var product = "llmtray"
    public var name: String
    public var link: String?
    public var tier: SupporterTier
    public var proof: Proof

    public init(name: String, link: String?, tier: SupporterTier, proof: Proof) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLink = link?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.link = (trimmedLink?.isEmpty ?? true) ? nil : trimmedLink
        self.tier = tier
        self.proof = proof
    }

    /// A name to send: 1–40 characters after trimming; a link, if any,
    /// https with a host.
    public var isValid: Bool {
        guard (1...40).contains(name.count) else { return false }
        guard let link else { return true }
        guard let url = URL(string: link), url.scheme?.lowercased() == "https", url.host != nil else { return false }
        return link.utf8.count <= 200
    }

    enum CodingKeys: String, CodingKey { case product, name, link, tier, proof }
    enum ProofKeys: String, CodingKey { case kind, jws, login }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(product, forKey: .product)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(link, forKey: .link)
        try c.encode(tier, forKey: .tier)
        var p = c.nestedContainer(keyedBy: ProofKeys.self, forKey: .proof)
        switch proof {
        case .appStore(let jws):
            try p.encode("appstore", forKey: .kind)
            try p.encode(jws, forKey: .jws)
        case .github(let login):
            try p.encode("github", forKey: .kind)
            try p.encode(login.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .login)
        }
    }
}

/// ipsupport-api's supporters endpoints (adr/0017): the signed list, a
/// listing to moderate, a removal. A session of its own, like the review
/// client's: no cookies, no cache. `LLMTRAY_SUPPORTERS_ENDPOINT` points a
/// development build at a local server -- nothing is sent to ipsupport.us
/// while developing.
public struct SupportersClient {
    public static let endpoint = URL(string: "https://ipsupport.us/api/supporters")!

    public enum SubmitResult: Equatable, Sendable {
        /// Taken: shown once a person approves it.
        case accepted
        /// The proof didn't check out (not a purchase of this app, refunded,
        /// not a sponsor), or the name was refused.
        case refused(code: String)
        case rateLimited
        case retryLater
    }

    public var endpoint: URL
    public var session: URLSession
    public var userAgent: String

    public init(endpoint: URL? = nil, session: URLSession = ReviewClient.makeSession(), userAgent: String = "LLMTray") {
        self.endpoint = endpoint
            ?? ProcessInfo.processInfo.environment["LLMTRAY_SUPPORTERS_ENDPOINT"].flatMap(URL.init(string:))
            ?? Self.endpoint
        self.session = session
        self.userAgent = userAgent
    }

    /// The published list, verified. nil offline or when it doesn't verify.
    public func fetch() async -> (list: SupportersList, body: Data, signature: String)? {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "product", value: "llmtray")]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let signature = http.value(forHTTPHeaderField: "X-Signature"),
              let list = try? SupportersVerifier.verify(body: data, signature: signature)
        else { return nil }
        return (list, data, signature)
    }

    public func submit(_ listing: SupporterListing) async -> SubmitResult {
        await post(endpoint, body: try? JSONEncoder().encode(listing))
    }

    /// Takes the name off the list (the same proof as when listed).
    public func remove(_ proof: SupporterListing.Proof) async -> SubmitResult {
        let listing = SupporterListing(name: "-", link: nil, tier: .coffee, proof: proof)
        guard var json = (try? JSONEncoder().encode(listing)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        else { return .retryLater }
        json = ["product": json["product"] ?? "llmtray", "proof": json["proof"] ?? [:]]
        return await post(endpoint.appendingPathComponent("remove"), body: try? JSONSerialization.data(withJSONObject: json))
    }

    private func post(_ url: URL, body: Data?) async -> SubmitResult {
        guard let body else { return .retryLater }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return .retryLater }
        switch http.statusCode {
        case 200...299: return .accepted
        case 429: return .rateLimited
        case 400...499:
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            return .refused(code: code ?? "refused")
        default: return .retryLater
        }
    }
}
