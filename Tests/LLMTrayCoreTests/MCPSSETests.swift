import XCTest
@testable import LLMTrayCore

/// Server-sent events in Streamable HTTP replies (adr/0027).
final class MCPSSETests: XCTestCase {
    private func events(_ text: String, max: Int = 1 << 20) throws -> [String] {
        var parser = SSEEvents(maxEvent: max)
        var out: [String] = []
        for byte in Array(text.utf8) {
            if let d = try parser.feed(byte) { out.append(String(decoding: d, as: UTF8.self)) }
        }
        if let d = parser.finish() { out.append(String(decoding: d, as: UTF8.self)) }
        return out
    }

    func testAnEmptyLineEndsEachEvent() throws {
        XCTAssertEqual(try events("event: message\ndata: {\"a\":1}\n\nevent: message\ndata: {\"b\":2}\n\n"),
                       ["{\"a\":1}", "{\"b\":2}"])
    }

    func testLineEndingsDataLinesAndOtherFields() throws {
        // CRLF and CR endings; "data" alone is an empty data line, so that
        // event's data is empty and it is skipped.
        XCTAssertEqual(try events("data: one\r\ndata:two\r\n\r\n: comment\rid: 7\rdata\r\r"), ["one\ntwo"])
        XCTAssertEqual(try events("database: x\ndata:  two spaces\n\n"), [" two spaces"])
        XCTAssertEqual(try events("retry: 10\n\nevent: ping\n\n"), [])
    }

    func testACutOffLastEventStillCounts() throws {
        XCTAssertEqual(try events("data: a\n\ndata: b"), ["a", "b"])
    }

    func testAnEventOverTheLimitIsRefused() {
        XCTAssertThrowsError(try events("data: 0123456789\n\n", max: 8))
        XCTAssertThrowsError(try events("data: 0123\ndata: 4567\n\n", max: 8))  // 9 with the joining newline
        // The limit is on the data, not the field name around it.
        XCTAssertEqual(try events("data: 01234567\n\n", max: 8), ["01234567"])
    }

    /// A notification, then the reply, in one stream: both arrive, apart.
    func testTransportDeliversEachEventOfAStream() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SSEStub.self]
        let transport = MCPHTTPTransport(url: URL(string: "https://mcp.example/mcp")!, headers: [:],
                                         session: URLSession(configuration: config))
        let got = expectation(description: "two messages")
        got.expectedFulfillmentCount = 2
        let box = Box()
        try await transport.open(onMessage: { data in
            box.append(String(decoding: data, as: UTF8.self))
            got.fulfill()
        }, onClose: { _ in })
        try await transport.send(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}".utf8))
        await fulfillment(of: [got], timeout: 5)
        XCTAssertEqual(box.items, [
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{}}",
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
        ])
        await transport.close()
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func append(_ s: String) { lock.withLock { list.append(s) } }
    var items: [String] { lock.withLock { list } }
}

private final class SSEStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{}}\n\n"
            + "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
