import XCTest
@testable import LLMTrayCore

final class PromptTokenEstimatorTests: XCTestCase {
    /// Samples and the most tokens any of the chat models' tokenizers gave
    /// them (tokenizers 0.x, no special tokens; 2026-09-26): Gemma 4, Qwen3,
    /// Llama 3.2, Mistral 7B v0.3, Phi-3.5, DeepSeek-Coder-V2-Lite, LFM2.5,
    /// Falcon3 -- Falcon3's Russian is the worst, 2.14 bytes a token.
    static let samples: [(name: String, text: String, maxTokens: Int)] = [
        ("russian", "Договор поставки № 17/2025. Поставщик обязуется передать в собственность Покупателя товар, а Покупатель "
            + "обязуется принять и оплатить его в порядке и сроки, установленные настоящим договором. Цена товара указывается "
            + "в спецификации, которая является неотъемлемой частью договора. Оплата производится в течение десяти банковских "
            + "дней с момента подписания товарной накладной. В случае просрочки оплаты Покупатель уплачивает неустойку в "
            + "размере 0,1% от неоплаченной суммы за каждый день просрочки. Споры разрешаются в Арбитражном суде по месту "
            + "нахождения истца.", 476),
        ("english", "This Supply Agreement No. 17/2025 sets out the terms under which the Supplier shall deliver goods to the "
            + "Buyer, and the Buyer shall accept and pay for them within the periods stated herein. The price of the goods is "
            + "given in the specification, which forms an integral part of this agreement. Payment is due within ten business "
            + "days of signing the delivery note. For late payment the Buyer pays a penalty of 0.1% of the unpaid amount for "
            + "each day of delay. Disputes are settled by the court at the claimant's place of business.", 129),
        ("code", "func compactionRange(_ messages: [ChatMessage], keepStart: Int, keepEnd: Int) -> Range<Int>? {\n"
            + "    func isTurnStart(_ i: Int) -> Bool { messages[i].role == \"user\" && !messages[i].isToolContext }\n"
            + "    guard messages.count > keepStart + keepEnd + 1 else { return nil }\n"
            + "    guard let start = (keepStart..<messages.count).first(where: { isTurnStart($0) || messages[$0].isSummary }) "
            + "else { return nil }\n"
            + "    var end = messages.count - keepEnd\n"
            + "    while end > start, end < messages.count, !isTurnStart(end) { end -= 1 }\n"
            + "    guard end > start + 1, end < messages.count else { return nil }\n"
            + "    return start..<end\n}\n", 218),
    ]

    func testSampleBytesAreTheMeasuredOnes() {
        // The token counts belong to exactly these texts.
        XCTAssertEqual(Self.samples.map { $0.text.utf8.count }, [1021, 526, 605])
    }

    func testDefaultRatioNeverUnderestimates() {
        let e = PromptTokenEstimator()
        for sample in Self.samples {
            let estimate = e.estimate(.init(bytes: sample.text.utf8.count))
            XCTAssertGreaterThanOrEqual(estimate, sample.maxTokens, sample.name)
        }
        XCTAssertEqual(e.estimate(.init(bytes: 1000)), 500)
        XCTAssertEqual(e.estimate(.init(bytes: 1001)), 501, "rounded up")
    }

    func testCountedPlusAdded() {
        var e = PromptTokenEstimator()
        XCTAssertNil(e.estimate(countedPlus: .init(bytes: 100)), "nothing counted yet")
        e.calibrate(.init(bytes: 45_000), promptTokens: 10_000)
        XCTAssertEqual(e.estimate(countedPlus: .init(bytes: 2_000)), 11_000, "the new bytes at 2")
        XCTAssertEqual(e.estimate(countedPlus: .init(bytes: 0, images: 1)), 10_000 + PromptTokenEstimator.tokensPerImage)
        // A whole request is never taken at the chat's average: dense text in
        // a request that got smaller would be undercounted.
        XCTAssertEqual(e.estimate(.init(bytes: 9_000)), 4_500)
    }

    /// Russian file text after an English chat: the growth still counts high.
    func testGrowthAfterCalibrationDoesNotUnderestimate() {
        var e = PromptTokenEstimator()
        let english = Self.samples[1]
        e.calibrate(.init(bytes: english.text.utf8.count), promptTokens: english.maxTokens)
        for added in [Self.samples[0], Self.samples[2]] {
            let estimate = e.estimate(countedPlus: .init(bytes: added.text.utf8.count)) ?? 0
            XCTAssertGreaterThanOrEqual(estimate, english.maxTokens + added.maxTokens, added.name)
        }
    }

    func testImagesCountedApartAndNotCalibrated() {
        var e = PromptTokenEstimator()
        XCTAssertEqual(e.estimate(.init(bytes: 200, images: 2)), 100 + 2 * PromptTokenEstimator.tokensPerImage)
        e.calibrate(.init(bytes: 4_000, images: 1), promptTokens: 2_000)
        XCTAssertNil(e.calibration, "an image's tokens aren't in the bytes")
        e.calibrate(.init(bytes: 4_000), promptTokens: 0)
        XCTAssertNil(e.calibration)
        e.calibrate(.init(bytes: 4_000), promptTokens: 1_000)
        XCTAssertEqual(e.calibration, .init(bytes: 4_000, tokens: 1_000))
    }
}
