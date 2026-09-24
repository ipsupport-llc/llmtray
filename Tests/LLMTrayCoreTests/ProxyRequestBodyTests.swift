import XCTest
@testable import LLMTrayCore

final class ProxyRequestBodyTests: XCTestCase {
    private func obj(_ d: Data) -> [String: Any] { (try! JSONSerialization.jsonObject(with: d)) as! [String: Any] }

    func testRequestedModel() {
        XCTAssertEqual(ProxyRequestBody.requestedModel(Data(#"{"model":"org/m"}"#.utf8)), "org/m")
        XCTAssertNil(ProxyRequestBody.requestedModel(Data(#"{"model":""}"#.utf8)))
        XCTAssertNil(ProxyRequestBody.requestedModel(Data(#"{"model":"default_model"}"#.utf8)))
        XCTAssertNil(ProxyRequestBody.requestedModel(Data(#"{"model":"default"}"#.utf8)))
        XCTAssertNil(ProxyRequestBody.requestedModel(Data(#"{"prompt":"x"}"#.utf8)))
        XCTAssertNil(ProxyRequestBody.requestedModel(Data(#"{"model":5}"#.utf8)))
        XCTAssertNil(ProxyRequestBody.requestedModel(Data("not json".utf8)))
        XCTAssertNil(ProxyRequestBody.requestedModel(Data()))
    }

    func testRewrite() {
        let body = Data(#"{"model":"google/gemma","draft_model":"evil/repo","adapters":"/tmp/x","messages":[{"role":"user","content":"a/b"}],"temperature":0.7}"#.utf8)
        let out = obj(ProxyRequestBody.rewrite(body, backendModel: "gemma-alias"))
        XCTAssertEqual(out["model"] as? String, "gemma-alias")
        XCTAssertNil(out["draft_model"])
        XCTAssertNil(out["adapters"])
        XCTAssertEqual(out["temperature"] as? Double, 0.7)
        XCTAssertEqual(((out["messages"] as? [[String: Any]])?.first?["content"]) as? String, "a/b")
        // No model at all: the backend's own model is named explicitly.
        XCTAssertEqual(obj(ProxyRequestBody.rewrite(Data(#"{"prompt":"x"}"#.utf8), backendModel: "default_model"))["model"] as? String, "default_model")
    }

    func testRewriteKeepsOtherMembersByteForByte() {
        let body = Data("""
        { "temperature": 0.0, "xtc_probability" : 1.0, "model": "x/y",
          "messages": [{"role": "user", "content": "q \\"}\\" ,{"}], "draft_model": {"a": [1, {"b": "}"}]},
          "stop": ["\\u0022", ","], "n": 1e3 }
        """.utf8)
        let out = String(decoding: ProxyRequestBody.rewrite(body, backendModel: "a\"b/c"), as: UTF8.self)
        XCTAssertEqual(out, #"{"model":"a\"b/c","temperature": 0.0,"xtc_probability" : 1.0,"messages": [{"role": "user", "content": "q \"}\" ,{"}],"stop": ["\u0022", ","],"n": 1e3}"#)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(out.utf8)))
        // Duplicate keys: every "model" goes, one is put first.
        let dup = String(decoding: ProxyRequestBody.rewrite(Data(#"{"model":"a","model":"b","x":{}}"#.utf8), backendModel: "m"), as: UTF8.self)
        XCTAssertEqual(dup, #"{"model":"m","x":{}}"#)
        XCTAssertEqual(String(decoding: ProxyRequestBody.rewrite(Data("{}".utf8), backendModel: "m"), as: UTF8.self), #"{"model":"m"}"#)
    }

    func testDuplicateModelKeys() {
        // Python's json keeps the last one; so must the check and the rewrite.
        let body = Data(#"{"model":"m","model":"evil/repo"}"#.utf8)
        XCTAssertEqual(ProxyRequestBody.requestedModel(body), "evil/repo")
        XCTAssertEqual(String(decoding: ProxyRequestBody.rewrite(body, backendModel: "m"), as: UTF8.self), #"{"model":"m"}"#)
    }

    func testBOM() {
        let body = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"draft_model":"evil/repo","temperature":0.0}"#.utf8)
        XCTAssertEqual(String(decoding: ProxyRequestBody.rewrite(body, backendModel: "m"), as: UTF8.self), #"{"model":"m","temperature":0.0}"#)
    }

    func testRewriteLeavesAlreadyRightBodiesAndNonObjectsAlone() {
        let exact = Data(#"{"model":"m",  "stream":true}"#.utf8)
        XCTAssertEqual(ProxyRequestBody.rewrite(exact, backendModel: "m"), exact, "byte for byte")
        let array = Data("[1,2]".utf8)
        XCTAssertEqual(ProxyRequestBody.rewrite(array, backendModel: "m"), array)
        XCTAssertEqual(ProxyRequestBody.rewrite(Data(), backendModel: "m"), Data())
    }
}
