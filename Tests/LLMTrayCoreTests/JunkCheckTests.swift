import XCTest
@testable import LLMTrayCore

final class JunkCheckTests: XCTestCase {
    func testCleanTextInManyLanguagesPasses() {
        let clean = [
            "Настоящий договор заключён между сторонами в городе Москве и вступает в силу с момента подписания.",
            "This agreement is made between the parties and takes effect on the date of signing.",
            "Dieser Vertrag wird zwischen den Parteien geschlossen und tritt mit der Unterzeichnung in Kraft.",
            "Le présent contrat est conclu entre les parties et entre en vigueur à la date de sa signature.",
            "Þessi samningur er gerður milli aðila og tekur gildi við undirritun þjóðanna á Íslandi.",
            "Tato smlouva se uzavírá mezi stranami a nabývá účinnosti dnem podpisu obou smluvních stran.",
            "Цей договір укладено між сторонами, і він набуває чинності з моменту підписання їм.",
            "本合同由双方签订，自签字之日起生效。双方应当遵守合同的全部条款和条件。",
            "func add(_ a: Int, _ b: Int) -> Int {\n    return a + b\n}\nlet total = add(2, 3)",
            "2024 | 1 250,00 | 3 400,50 | 12 %\n2025 | 1 300,00 | 3 500,75 | 14 %\n2026 | 1 350,00 | 3 600,00 | 15 %",
        ]
        for text in clean {
            XCTAssertLessThan(JunkCheck.score(text), 0.2, text)
            XCTAssertFalse(JunkCheck.isJunk(text))
        }
    }

    func testBrokenTextLayersAreJunk() {
        let junk = [
            // cp1251 read as Latin-1
            "Íàñòîÿùèé äîãîâîð çàêëþ÷åí ìåæäó ñòîðîíàìè â ãîðîäå Ìîñêâå",
            // U+0138 "ĸ" for "к", Latin look-alikes in Cyrillic words
            "Настоящий ĸонтраĸт заĸлючён в ĸоличестве двух эĸземпляров стороны",
            // private use: unmapped glyph ids
            String(repeating: "\u{E001}\u{E002}\u{E003} ", count: 20),
            // replacement characters
            "Договор \u{FFFD}\u{FFFD} заключён \u{FFFD} между \u{FFFD}\u{FFFD} сторонами",
            // control characters
            "text\u{01}\u{02}\u{03}\u{04}with\u{05}\u{06}controls\u{07}\u{08}everywhere",
            // symbol soup
            "!#$%&()*+,-./:;<=>?@[]^_{|}~!#$%&()*+,-./:;<=>?@[]^_{|}~ ab",
        ]
        for text in junk {
            XCTAssertGreaterThanOrEqual(JunkCheck.score(text), JunkCheck.threshold, "\(text): \(JunkCheck.signals(text))")
        }
    }

    func testEmptyAndShortPages() {
        XCTAssertEqual(JunkCheck.score(""), 1)
        XCTAssertEqual(JunkCheck.score("  \n "), 1)
        // One stray glyph on a short page doesn't make it junk.
        XCTAssertLessThan(JunkCheck.score("Page 12 \u{FFFD}"), JunkCheck.threshold)
    }

    func testSignalsSayWhy() {
        let s = JunkCheck.signals("Íàñòîÿùèé äîãîâîð çàêëþ÷åí ìåæäó ñòîðîíàìè")
        XCTAssertGreaterThan(s.mojibake, 0.9)
        XCTAssertEqual(s.replacement, 0)
    }
}
