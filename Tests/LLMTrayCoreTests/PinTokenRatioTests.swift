import XCTest
@testable import LLMTrayCore

/// Pinned files sized at a model's bytes a token, learned from the server's
/// counts (PinTokenRatio).
final class PinTokenRatioTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "llmtray.tests.pinTokenRatio"
    private let model = "/models/gemma-4-26b"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testASampleIsAMeaningfulRequestWithoutImages() {
        XCTAssertEqual(PinTokenRatio.sample(.init(bytes: 43_000), promptTokens: 10_000), 4.3)
        XCTAssertEqual(PinTokenRatio.sample(.init(bytes: 8_000), promptTokens: 2_000), 4.0, "at the minimum")
        XCTAssertNil(PinTokenRatio.sample(.init(bytes: 7_996), promptTokens: 1_999), "template tokens weigh too much")
        XCTAssertNil(PinTokenRatio.sample(.init(bytes: 40_000, images: 1), promptTokens: 10_000), "an image's tokens aren't in the bytes")
        XCTAssertNil(PinTokenRatio.sample(.init(bytes: 0), promptTokens: 10_000))
    }

    func testTheLowestOfTheLastFewSamples() {
        var samples: [Double] = []
        for s in [4.3, 2.4, 4.5, 4.4, 4.2] { samples = PinTokenRatio.adding(s, to: samples) }
        XCTAssertEqual(PinTokenRatio.learned(samples), 2.4, "a denser text takes it down at once")
        samples = PinTokenRatio.adding(4.1, to: samples)
        XCTAssertEqual(samples.count, PinTokenRatio.samplesKept)
        XCTAssertEqual(PinTokenRatio.learned(samples), 2.4, "still among the last five")
        samples = PinTokenRatio.adding(4.6, to: samples)
        XCTAssertEqual(PinTokenRatio.learned(samples), 4.1, "and leaves it after a few")
        XCTAssertNil(PinTokenRatio.learned([]))
    }

    func testTheEffectiveRatioKeepsAMarginWithinItsRange() {
        XCTAssertEqual(PinTokenRatio.effective(nil), 2.0, "not counted yet: the estimator's")
        XCTAssertEqual(PinTokenRatio.effective(4.3), 4.3 * 0.9, accuracy: 1e-9)
        XCTAssertEqual(PinTokenRatio.effective(1.5), 2.0, "never below the estimator's")
        XCTAssertEqual(PinTokenRatio.effective(9), 6.0)
    }

    func testBytesBecomeTokensAtTheRatio() {
        XCTAssertEqual(PinTokenRatio.tokens(bytes: 242_712, bytesPerToken: 2), 121_356)
        XCTAssertEqual(PinTokenRatio.tokens(bytes: 7, bytesPerToken: 2), 4, "rounded up")
        XCTAssertEqual(PinTokenRatio.tokens(bytes: 10, bytesPerToken: 0), 5, "no ratio: the default")
        XCTAssertEqual(PinTokenRatio.tokens([1: 400, 2: 1_000], bytesPerToken: 4), [1: 100, 2: 250])
    }

    func testRatiosAreKeptPerModel() {
        let ratios = PinTokenRatios(defaults: defaults)
        XCTAssertEqual(ratios.bytesPerToken(model: model), 2.0)
        XCTAssertFalse(ratios.record(model: model, .init(bytes: 4_000), promptTokens: 1_000), "too small")
        XCTAssertFalse(ratios.record(model: model, .init(bytes: 40_000, images: 2), promptTokens: 10_000), "images")
        XCTAssertFalse(ratios.record(model: nil, .init(bytes: 43_000), promptTokens: 10_000), "no model")
        XCTAssertNil(ratios.learned(model: model))
        XCTAssertTrue(ratios.record(model: model, .init(bytes: 43_000), promptTokens: 10_000))
        XCTAssertEqual(PinTokenRatios(defaults: defaults).learned(model: model), 4.3, "persisted")
        XCTAssertEqual(ratios.bytesPerToken(model: model), 4.3 * 0.9, accuracy: 1e-9)
        XCTAssertEqual(ratios.bytesPerToken(model: "/models/other"), 2.0, "another model isn't")
        XCTAssertEqual(ratios.bytesPerToken(model: nil), 2.0)
    }

    /// The book: 242,712 bytes, ≈121K tokens at 2 bytes a token -- refused
    /// at an 83K limit -- and ≈62.7K at Gemma 4's 4.3 less the margin.
    func testTheBookFitsAtTheLearnedRatio() {
        let book: [Int64: Int] = [7: 242_712]
        let limit = 83_000
        let estimated = PinTokenRatio.tokens(book, bytesPerToken: PinTokenRatio.effective(nil))
        XCTAssertEqual(estimated[7], 121_356)
        XCTAssertEqual(PinnedFiles.fitting([7], tokens: estimated, limitTokens: limit).tooLong, [7])
        let docs = [IndexedDocument(doc: 7, source: 1, rev: 1, name: "book.txt", ext: "txt", sha256: "", bytes: 242_712, status: .embedded)]
        XCTAssertEqual(PinnedFiles.check(7, docs: docs, pins: [], tokens: estimated, limitTokens: limit),
                       .tooLong(tokens: 121_356, used: 0, limit: limit))
        let measured = PinTokenRatio.tokens(book, bytesPerToken: PinTokenRatio.effective(4.3))
        XCTAssertEqual(measured[7], 62_717)
        XCTAssertEqual(PinnedFiles.fitting([7], tokens: measured, limitTokens: limit).fit, [7])
        XCTAssertEqual(PinnedFiles.check(7, docs: docs, pins: [], tokens: measured, limitTokens: limit), .fits(tokens: 62_717))
    }

    /// The request's selection sizes the files at the model's ratio too.
    func testTheRequestSelectsAtTheRatio() {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 200)
        let f = PinnedFileText(doc: 1, rev: 1, name: "a.txt", pages: [.init(page: 1, text: text)])
        let limit = PinnedFiles.tokens(f, bytesPerToken: 4)
        XCTAssertEqual(PinnedFiles.select([f], limitTokens: limit).files, [], "at 2 bytes a token it doesn't fit")
        XCTAssertEqual(PinnedFiles.select([f], limitTokens: limit, bytesPerToken: 4).files, [f])
    }
}
