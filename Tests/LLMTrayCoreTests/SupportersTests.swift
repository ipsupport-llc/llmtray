import CryptoKit
import XCTest
@testable import LLMTrayCore

final class SupportersTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    private func body(_ version: Int, _ supporters: String) -> Data {
        Data(#"{"version":\#(version),"updated":"2026-10-01","supporters":[\#(supporters)]}"#.utf8)
    }

    private func sign(_ data: Data) throws -> String {
        try key.signature(for: data).base64EncodedString()
    }

    func testAGoodSignatureVerifies() throws {
        let data = body(3, #"{"name":"Ada","tier":"founding","link":"https://example.org","since":"2026-10"}"#)
        let list = try SupportersVerifier.verify(body: data, signature: try sign(data), publicKey: publicKey)
        XCTAssertEqual(list.version, 3)
        XCTAssertEqual(list.supporters.first?.name, "Ada")
        XCTAssertEqual(list.supporters.first?.linkURL?.host, "example.org")
    }

    func testABadOrMissingSignatureIsRefused() throws {
        let data = body(3, #"{"name":"Ada","tier":"pro","since":"2026-10"}"#)
        let other = try Curve25519.Signing.PrivateKey().signature(for: data).base64EncodedString()
        XCTAssertThrowsError(try SupportersVerifier.verify(body: data, signature: other, publicKey: publicKey))
        XCTAssertThrowsError(try SupportersVerifier.verify(body: data, signature: "", publicKey: publicKey))
        // One byte changed after signing.
        var tampered = data
        tampered[tampered.count - 3] = UInt8(ascii: "X")
        XCTAssertThrowsError(try SupportersVerifier.verify(body: tampered, signature: try sign(data), publicKey: publicKey))
    }

    func testAMalformedBodyIsRefused() throws {
        let data = Data("{not json".utf8)
        XCTAssertThrowsError(try SupportersVerifier.verify(body: data, signature: try sign(data), publicKey: publicKey)) {
            XCTAssertEqual($0 as? SupportersVerifier.Failure, .malformed)
        }
    }

    func testOnlyANewerVersionReplaces() {
        let current = SupportersList(version: 5, updated: "", supporters: [])
        XCTAssertTrue(SupportersVerifier.isNewer(SupportersList(version: 6, updated: "", supporters: []), than: current))
        XCTAssertFalse(SupportersVerifier.isNewer(SupportersList(version: 5, updated: "", supporters: []), than: current))
        XCTAssertFalse(SupportersVerifier.isNewer(SupportersList(version: 4, updated: "", supporters: []), than: current))
    }

    func testEntriesAreCleanedAndOrdered() throws {
        let data = body(1, """
        {"name":"  Grace  ","tier":"coffee","since":"2026-09"},
        {"name":"Ada","tier":"founding","link":"http://insecure.example","since":"2026-11"},
        {"name":"   ","tier":"pro","since":"2026-10"},
        {"name":"Linus","tier":"pro","link":"javascript:alert(1)","since":"2026-10"},
        {"name":"\(String(repeating: "x", count: 60))","tier":"coffee","since":"2026-10"}
        """)
        let list = try SupportersVerifier.decode(data)
        XCTAssertEqual(list.supporters.count, 4)  // the blank name dropped
        XCTAssertEqual(list.ordered.map(\.name).prefix(3), ["Ada", "Linus", "Grace"])
        XCTAssertNil(list.supporters.first { $0.name == "Ada" }?.link)    // http dropped
        XCTAssertNil(list.supporters.first { $0.name == "Linus" }?.link)  // javascript: dropped
        XCTAssertEqual(list.supporters.first { $0.tier == .coffee && $0.since == "2026-10" }?.name.count, 40)
    }

    func testProductIDs() {
        XCTAssertEqual(SupporterTier.founding.productID, "us.ipsupport.llmtray.tip.founding")
        XCTAssertEqual(SupporterTier(productID: "us.ipsupport.llmtray.tip.coffee"), .coffee)
        XCTAssertNil(SupporterTier(productID: "us.ipsupport.llmtray.tip.gold"))
    }

    func testAListingSendsOnlyNameLinkTierAndProof() throws {
        let listing = SupporterListing(name: "  Ada ", link: "  ", tier: .pro, proof: .appStore(jws: "eyJ.a.b"))
        XCTAssertTrue(listing.isValid)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(listing)) as? [String: Any]
        XCTAssertEqual(Set(json?.keys ?? [:].keys), ["product", "name", "tier", "proof"])
        XCTAssertEqual(json?["name"] as? String, "Ada")
        XCTAssertEqual((json?["proof"] as? [String: String])?["kind"], "appstore")
        XCTAssertFalse(SupporterListing(name: "", link: nil, tier: .coffee, proof: .github(login: "x")).isValid)
        XCTAssertFalse(SupporterListing(name: "Ada", link: "http://x.org", tier: .coffee, proof: .github(login: "x")).isValid)
        XCTAssertFalse(SupporterListing(name: String(repeating: "y", count: 41), link: nil, tier: .coffee, proof: .github(login: "x")).isValid)
    }

    func testTheShippedKeyIsAValidKey() {
        XCTAssertNotNil(Data(base64Encoded: SupportersVerifier.publicKey).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) })
    }
}
