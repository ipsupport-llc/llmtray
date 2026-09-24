import XCTest
@testable import LLMTrayCore

final class HTTPRequestParserTests: XCTestCase {
    private func parse(_ text: String, max: Int = 1_000) -> HTTPParseResult {
        HTTPRequestParser.parseHead(Data(text.utf8), maxBodyBytes: max)
    }

    private func status(_ r: HTTPParseResult) -> String? {
        if case .reject(let s, _) = r { return s }
        return nil
    }

    func testValidPost() {
        let head = "POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Type: application/json\r\n\r\n"
        let r = parse(head + "hello")
        guard case .request(let parsed, let offset) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/v1/chat/completions")
        XCTAssertEqual(parsed.contentLength, 5)
        XCTAssertEqual(parsed.headers["content-type"], "application/json")
        XCTAssertEqual(offset, head.utf8.count)
    }

    func testGetWithoutBody() {
        guard case .request(let head, _) = parse("GET /v1/models HTTP/1.1\r\n\r\n") else { return XCTFail() }
        XCTAssertEqual(head.contentLength, 0)
    }

    func testIncompleteHeadNeedsMore() {
        XCTAssertEqual(parse("POST /v1/chat HTTP/1.1\r\nContent-Len"), .needMoreData)
    }

    func testNegativeContentLength() {
        XCTAssertEqual(status(parse("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n")), "400 Bad Request")
    }

    func testNonNumericAndSignedContentLength() {
        XCTAssertEqual(status(parse("POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n")), "400 Bad Request")
        XCTAssertEqual(status(parse("POST / HTTP/1.1\r\nContent-Length: +5\r\n\r\n")), "400 Bad Request")
    }

    func testConflictingContentLengths() {
        XCTAssertEqual(status(parse("POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n")), "400 Bad Request")
    }

    func testBodyTooLarge() {
        XCTAssertEqual(status(parse("POST / HTTP/1.1\r\nContent-Length: 1001\r\n\r\n")), "413 Payload Too Large")
        XCTAssertEqual(status(parse("POST / HTTP/1.1\r\nContent-Length: 99999999999999999999999\r\n\r\n")), "400 Bad Request")
    }

    func testChunkedBodyRejected() {
        XCTAssertEqual(status(parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")), "411 Length Required")
    }

    func testEndlessHeadersRejected() {
        let flood = "GET / HTTP/1.1\r\n" + String(repeating: "X-A: b\r\n", count: 10_000)
        XCTAssertEqual(status(parse(flood)), "431 Request Header Fields Too Large")
    }

    func testHeadLimitIndependentOfSegmentation() {
        let line = "GET / HTTP/1.1\r\nX: "
        let head = line + String(repeating: "a", count: HTTPRequestParser.maxHeaderBytes - line.utf8.count)
        XCTAssertEqual(head.utf8.count, HTTPRequestParser.maxHeaderBytes)
        // Whole, or cut inside the terminator: accepted the same way.
        if case .reject = parse(head + "\r\n\r\n") { XCTFail("complete head at the limit rejected") }
        // Byte-level cuts ("\r\n" is one Character in Swift).
        for cut in 1...3 {
            let partial = Data(head.utf8) + Data([13, 10, 13, 10].prefix(cut))
            XCTAssertEqual(HTTPRequestParser.parseHead(partial, maxBodyBytes: 1_000), .needMoreData, "cut \(cut)")
        }
        XCTAssertEqual(status(parse(head + "a\r\n\r\n")), "431 Request Header Fields Too Large")
    }

    func testMalformedRequestLine() {
        XCTAssertEqual(status(parse("garbage\r\n\r\n")), "400 Bad Request")
        XCTAssertEqual(status(parse("GET http://evil/ HTTP/1.1\r\n\r\n")), "400 Bad Request")
    }

    func testNonUTF8Head() {
        var data = Data("GET / HTTP/1.1\r\nX: ".utf8)
        data.append(contentsOf: [0xFF, 0xFE])
        data.append(Data("\r\n\r\n".utf8))
        if case .reject(let s, _) = HTTPRequestParser.parseHead(data, maxBodyBytes: 10) {
            XCTAssertEqual(s, "400 Bad Request")
        } else {
            XCTFail()
        }
    }

    func testSlicedBufferOffsets() {
        let full = Data("xxGET / HTTP/1.1\r\n\r\nbody".utf8)
        let slice = full[full.index(full.startIndex, offsetBy: 2)...]
        guard case .request(_, let offset) = HTTPRequestParser.parseHead(Data(slice), maxBodyBytes: 10) else { return XCTFail() }
        XCTAssertEqual(offset, "GET / HTTP/1.1\r\n\r\n".utf8.count)
    }
}
