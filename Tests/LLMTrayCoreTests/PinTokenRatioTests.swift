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
        XCTAssertEqual(PinTokenRatios(defaults: defaults).samples.all[model], [4.3], "persisted")
        XCTAssertEqual(ratios.learned(model: model), 3.0, "no pinned text counted yet: capped")
        XCTAssertEqual(ratios.bytesPerToken(model: model), 4.3 * 0.9, accuracy: 1e-9, "but probing, uncapped")
        XCTAssertTrue(ratios.record(model: model, .init(bytes: 44_000), promptTokens: 10_000, carriedPins: true))
        XCTAssertEqual(PinTokenRatios(defaults: defaults).samples.pinned[model], [4.4])
        XCTAssertEqual(ratios.samples.all[model], [4.3, 4.4], "a pinned request is a sample of both")
        XCTAssertEqual(ratios.bytesPerToken(model: model), 4.4 * 0.9, accuracy: 1e-9)
        XCTAssertEqual(ratios.bytesPerToken(model: "/models/other"), 2.0, "another model isn't")
        XCTAssertEqual(ratios.bytesPerToken(model: nil), 2.0)
    }

    /// An English chat's ratio would undercount a pinned code or CSV file:
    /// until a request carrying pinned text is counted, at most 3.
    func testOnlyPinnedRequestsLiftTheRatioPastTheCap() {
        XCTAssertEqual(PinTokenRatio.learned([4.3], pinned: []), 3.0)
        XCTAssertEqual(PinTokenRatio.learned([2.6], pinned: []), 2.6, "lower stays")
        XCTAssertEqual(PinTokenRatio.learned([2.4, 4.3], pinned: [4.5]), 4.5, "the pinned text's own, once there")
        XCTAssertEqual(PinTokenRatio.learned([4.3], pinned: [2.8, 4.5]), 2.8)
        XCTAssertNil(PinTokenRatio.learned([], pinned: []))
    }

    /// Before any pinned text was counted, a file that fits only past the
    /// cap goes out once at the other requests' own ratio: the book, 89.9K
    /// at 3.0 × 0.9, is 62.7K at 4.3 × 0.9 and fits 83K.
    func testAProbeLetsAFileThroughOnceWithoutPinnedSamples() {
        let book: [Int64: Int] = [7: 242_712]
        let probing = PinTokenSamples(all: [model: [4.3]])
        XCTAssertFalse(probing.isMeasured(model: model))
        XCTAssertEqual(try XCTUnwrap(probing.probeBytesPerToken(model: model)), 4.3 * 0.9, accuracy: 1e-9)
        let capped = PinTokenRatio.tokens(book, bytesPerToken: PinTokenRatio.effective(probing.learned(model: model)))
        XCTAssertEqual(PinnedFiles.fitting([7], tokens: capped, limitTokens: 83_000).tooLong, [7], "at the cap it wouldn't")
        let sized = PinTokenRatio.tokens(book, bytesPerToken: probing.bytesPerToken(model: model))
        XCTAssertEqual(sized[7], 62_717)
        XCTAssertEqual(PinnedFiles.fitting([7], tokens: sized, limitTokens: 83_000).fit, [7])
        // The probe's count ends it: the pinned text's own ratio from then on.
        let counted = PinTokenSamples(all: [model: [4.3, 4.1]], pinned: [model: [4.1]])
        XCTAssertNil(counted.probeBytesPerToken(model: model))
        XCTAssertTrue(counted.isMeasured(model: model))
        XCTAssertEqual(counted.bytesPerToken(model: model), 4.1 * 0.9, accuracy: 1e-9)
    }

    func testNoProbeAfterAFailureOrWhereTheCapDoesntBind() {
        let ratios = PinTokenRatios(defaults: defaults)
        ratios.record(model: model, .init(bytes: 43_000), promptTokens: 10_000)
        XCTAssertNotNil(ratios.samples.probeBytesPerToken(model: model))
        ratios.recordFailure(model: model)   // the probe request failed
        XCTAssertNil(ratios.samples.probeBytesPerToken(model: model), "no probing again")
        XCTAssertEqual(ratios.bytesPerToken(model: model), 2.0)
        let dense = PinTokenSamples(all: [model: [2.6]])
        XCTAssertNil(dense.probeBytesPerToken(model: model), "under the cap: nothing to probe")
        XCTAssertEqual(dense.bytesPerToken(model: model), 2.6 * 0.9, accuracy: 1e-9)
        XCTAssertNil(PinTokenSamples().probeBytesPerToken(model: model), "nothing counted: the estimator's 2")
        XCTAssertEqual(PinTokenSamples().bytesPerToken(model: model), 2.0)
        XCTAssertFalse(PinTokenSamples().isMeasured(model: model))
    }

    /// A failed pinned request (no count comes back) sizes pins at 2 bytes
    /// a token until counted pinned requests replace it.
    func testAFailedPinnedRequestSizesConservatively() {
        let ratios = PinTokenRatios(defaults: defaults)
        ratios.record(model: model, .init(bytes: 43_000), promptTokens: 10_000, carriedPins: true)
        XCTAssertEqual(ratios.bytesPerToken(model: model), 4.3 * 0.9, accuracy: 1e-9)
        ratios.recordFailure(model: model)
        XCTAssertEqual(ratios.learned(model: model), 2.0)
        XCTAssertEqual(PinTokenRatios(defaults: defaults).bytesPerToken(model: model), 2.0, "persisted")
        XCTAssertEqual(ratios.samples.all[model], [4.3], "the other samples untouched")
        for _ in 1..<PinTokenRatio.samplesKept {
            ratios.record(model: model, .init(bytes: 42_000), promptTokens: 10_000, carriedPins: true)
        }
        XCTAssertEqual(ratios.learned(model: model), 2.0, "still among the last few")
        ratios.record(model: model, .init(bytes: 42_000), promptTokens: 10_000, carriedPins: true)
        XCTAssertEqual(ratios.learned(model: model), 4.2)
        ratios.recordFailure(model: nil)
        XCTAssertEqual(ratios.samples.pinned.count, 1, "no model: nothing")
    }

    /// The book: 242,712 bytes, ≈121K tokens at 2 bytes a token -- refused
    /// at an 83K limit -- and ≈62.7K at Gemma 4's 4.3 (counted with pinned
    /// text) less the margin.
    func testTheBookFitsAtTheLearnedRatio() {
        let book: [Int64: Int] = [7: 242_712]
        let limit = 83_000
        let estimated = PinTokenRatio.tokens(book, bytesPerToken: PinTokenRatio.effective(nil))
        XCTAssertEqual(estimated[7], 121_356)
        XCTAssertEqual(PinnedFiles.fitting([7], tokens: estimated, limitTokens: limit).tooLong, [7])
        let docs = [IndexedDocument(doc: 7, source: 1, rev: 1, name: "book.txt", ext: "txt", sha256: "", bytes: 242_712, status: .embedded)]
        XCTAssertEqual(PinnedFiles.check(7, docs: docs, pins: [], tokens: estimated, limitTokens: limit),
                       .tooLong(tokens: 121_356, used: 0, limit: limit))
        let learned = PinTokenSamples(all: [model: [4.3]], pinned: [model: [4.3]])
        let measured = PinTokenRatio.tokens(book, bytesPerToken: learned.bytesPerToken(model: model))
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
