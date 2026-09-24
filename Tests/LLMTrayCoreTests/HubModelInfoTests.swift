import XCTest
@testable import LLMTrayCore

final class HubModelInfoTests: XCTestCase {
    private func info(_ json: String) -> HubModelInfo? { HubModelInfo.parse(Data(json.utf8)) }

    func testParse() {
        // Shapes of real responses (2026-09), trimmed.
        let llama = info(#"{"id":"meta-llama/Llama-3.2-1B-Instruct","gated":"manual","usedStorage":4945498882,"tags":["license:llama3.2"],"cardData":{"license":"llama3.2"}}"#)
        XCTAssertEqual(llama, HubModelInfo(sizeBytes: 4945498882, license: "llama3.2", access: .gated(manualApproval: true)))
        let flux = info(#"{"id":"black-forest-labs/FLUX.1-dev","gated":"auto","cardData":{"license":"other","license_name":"flux-1-dev-non-commercial-license","license_link":"LICENSE.md"}}"#)
        XCTAssertEqual(flux?.license, "flux-1-dev-non-commercial-license")
        XCTAssertEqual(flux?.licenseLink, "LICENSE.md")
        XCTAssertEqual(flux?.access, .gated(manualApproval: false))
        XCTAssertEqual(flux?.isNonCommercial, true)
        let open = info(#"{"id":"mlx-community/gemma-3-4b-it-4bit","gated":false,"tags":["mlx","license:gemma"]}"#)
        XCTAssertEqual(open?.license, "gemma", "from the tag when the card has none")
        XCTAssertEqual(open?.access, .open)
        XCTAssertEqual(info(#"{"id":"x","gated":true}"#)?.access, .gated(manualApproval: false))
        XCTAssertNil(info(#"{"error":"Repository not found"}"#))
        XCTAssertNil(info("not json"))
    }

    func testNonCommercial() {
        for l in ["cc-by-nc-4.0", "cc-by-nc-sa-4.0", "flux-1-dev-non-commercial-license", "research-only", "NonCommercial", "mnpl", "apple-amlr"] {
            XCTAssertTrue(HubModelInfo(license: l).isNonCommercial, l)
        }
        for l in ["apache-2.0", "mit", "llama3.2", "gemma", "openrail", "nvidia-open-model-license", "bsd-3-clause"] {
            XCTAssertFalse(HubModelInfo(license: l).isNonCommercial, l)
        }
        XCTAssertFalse(HubModelInfo().isNonCommercial)
    }
}
