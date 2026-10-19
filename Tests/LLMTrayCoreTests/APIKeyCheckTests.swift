import XCTest
@testable import LLMTrayCore

final class APIKeyCheckTests: XCTestCase {
    func testPresentedKey() {
        XCTAssertEqual(APIKeyCheck.presented(["authorization": "Bearer abc"]), "abc")
        XCTAssertEqual(APIKeyCheck.presented(["authorization": "bearer  abc "]), "abc")
        XCTAssertEqual(APIKeyCheck.presented(["x-api-key": "k"]), "k")
        XCTAssertNil(APIKeyCheck.presented(["authorization": "Basic Zm9v"]))
        XCTAssertNil(APIKeyCheck.presented([:]))
    }

    func testWhoGetsIn() {
        let key = "llmtray-secret"
        func allows(_ headers: [String: String], required: Bool = true, networkOnly: Bool = true,
                    loopback: Bool = false, app: Bool = false, key: String? = key) -> Bool {
            APIKeyCheck.allows(headers: headers, key: key, required: required, networkOnly: networkOnly,
                               fromLoopback: loopback, fromApp: app)
        }
        XCTAssertTrue(allows([:], required: false))
        XCTAssertFalse(allows([:]))
        XCTAssertFalse(allows(["authorization": "Bearer wrong"]))
        XCTAssertFalse(allows(["authorization": "Bearer llmtray-secre"]))
        XCTAssertTrue(allows(["authorization": "Bearer llmtray-secret"]))
        XCTAssertTrue(allows(["x-api-key": "llmtray-secret"]))
        // This Mac: free with networkOnly, not without.
        XCTAssertTrue(allows([:], loopback: true))
        XCTAssertFalse(allows([:], networkOnly: false, loopback: true))
        // The app's own requests always.
        XCTAssertTrue(allows([:], networkOnly: false, app: true))
        // Required but unreadable: closed, never open.
        XCTAssertFalse(allows(["authorization": "Bearer "], key: nil))
        XCTAssertFalse(allows(["authorization": "Bearer "], key: ""))
    }

    func testGeneratedKeys() {
        let a = APIKeyCheck.generate(), b = APIKeyCheck.generate()
        XCTAssertTrue(a.hasPrefix("llmtray-"))
        XCTAssertEqual(a.count, 40)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.dropFirst(8).allSatisfy { $0.isLetter || $0.isNumber })
    }

    func testRefusalShapes() {
        let anthropic = APIKeyCheck.unauthorizedBody(route: "/v1/messages")
        XCTAssertEqual(anthropic["type"] as? String, "error")
        XCTAssertEqual((anthropic["error"] as? [String: Any])?["type"] as? String, "authentication_error")
        let openai = APIKeyCheck.unauthorizedBody(route: "/v1/chat/completions")
        XCTAssertEqual((openai["error"] as? [String: Any])?["code"] as? String, "invalid_api_key")
    }

    func testCLIHint() {
        var status = ControlStatus(state: ControlStatus.running, port: 8765, idleUnloaded: false, appVersion: "1",
                                   baseURL: ControlStatus.baseURL(port: 8765), appTokenHeader: "h", appToken: "t")
        XCTAssertTrue(CommandLineOutput.api(status, exampleModel: "m").contains("OPENAI_API_KEY=local"))
        status.apiKeyForLocal = true
        let text = CommandLineOutput.api(status, exampleModel: "m")
        XCTAssertTrue(text.contains("OPENAI_API_KEY=<key>"))
        XCTAssertTrue(text.contains("-H 'Authorization: Bearer <key>'"))
    }
}
