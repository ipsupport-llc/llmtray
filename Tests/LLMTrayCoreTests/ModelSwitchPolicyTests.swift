import XCTest
@testable import LLMTrayCore

final class ModelSwitchPolicyTests: XCTestCase {
    func testNoSwitchNeeded() {
        for policy in ModelSwitchPolicy.allCases {
            XCTAssertEqual(policy.decide(fromApp: false, loaded: "a", target: "a", refusedLately: false), .proceed)
            XCTAssertEqual(policy.decide(fromApp: false, loaded: nil, target: "b", refusedLately: false), .proceed, "nothing loaded")
            XCTAssertEqual(policy.decide(fromApp: false, loaded: "a", target: nil, refusedLately: false), .proceed, "no model named")
        }
    }

    func testAppChatAlwaysSwitches() {
        for policy in ModelSwitchPolicy.allCases {
            XCTAssertEqual(policy.decide(fromApp: true, loaded: "a", target: "b", refusedLately: true), .proceed)
        }
    }

    func testOutsideClient() {
        XCTAssertEqual(ModelSwitchPolicy.auto.decide(fromApp: false, loaded: "a", target: "b", refusedLately: false), .proceed)
        XCTAssertEqual(ModelSwitchPolicy.keep.decide(fromApp: false, loaded: "a", target: "b", refusedLately: false), .refuse)
        XCTAssertEqual(ModelSwitchPolicy.ask.decide(fromApp: false, loaded: "a", target: "b", refusedLately: false), .ask)
        XCTAssertEqual(ModelSwitchPolicy.ask.decide(fromApp: false, loaded: "a", target: "b", refusedLately: true), .refuse)
    }
}
