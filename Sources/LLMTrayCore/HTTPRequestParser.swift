import Foundation

/// The request line and headers of an HTTP/1.1 request.
public struct HTTPRequestHead: Equatable {
    public var method: String
    public var path: String
    /// Lowercased names.
    public var headers: [String: String]
    public var contentLength: Int

    public init(method: String, path: String, headers: [String: String], contentLength: Int) {
        self.method = method
        self.path = path
        self.headers = headers
        self.contentLength = contentLength
    }
}

public enum HTTPParseResult: Equatable {
    /// No complete head yet; read more.
    case needMoreData
    /// The head, and where in the buffer the body starts (an offset from
    /// the buffer's startIndex).
    case request(HTTPRequestHead, bodyOffset: Int)
    /// Answer with this status and close.
    case reject(status: String, message: String)
}

/// Parses what the proxy reads from a client connection, strictly enough
/// that a malformed or hostile request is refused instead of crashing the
/// app or buffering without bound (the proxy is reachable from the LAN
/// when that's enabled). Scoped to what OpenAI-API clients send: bodies
/// sized by Content-Length.
public enum HTTPRequestParser {
    public static let maxHeaderBytes = 64 * 1024
    private static let terminator = Data([13, 10, 13, 10]) // \r\n\r\n

    public static func parseHead(_ buffer: Data, maxBodyBytes: Int) -> HTTPParseResult {
        guard let end = buffer.range(of: terminator) else {
            return buffer.count > maxHeaderBytes
                ? .reject(status: "431 Request Header Fields Too Large", message: "request headers too large")
                : .needMoreData
        }
        guard end.lowerBound - buffer.startIndex <= maxHeaderBytes else {
            return .reject(status: "431 Request Header Fields Too Large", message: "request headers too large")
        }
        guard let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .reject(status: "400 Bad Request", message: "request head is not UTF-8")
        }
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts.count <= 3, parts[1].hasPrefix("/") else {
            return .reject(status: "400 Bad Request", message: "malformed request line")
        }

        var headers: [String: String] = [:]
        var lengths: Set<String> = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "content-length" { lengths.insert(value) }
            headers[key] = value
        }

        if let encoding = headers["transfer-encoding"], encoding.lowercased() != "identity" {
            return .reject(status: "411 Length Required", message: "chunked request bodies aren't supported; send Content-Length")
        }
        // Validated before anything slices with it: a negative value traps
        // in prefix(), a huge one buffers without bound, and conflicting
        // duplicates are a request-smuggling shape.
        var contentLength = 0
        if !lengths.isEmpty {
            guard lengths.count == 1, let raw = lengths.first, let value = Int(raw), value >= 0,
                  raw.allSatisfy(\.isNumber) else {
                return .reject(status: "400 Bad Request", message: "invalid Content-Length")
            }
            guard value <= maxBodyBytes else {
                return .reject(status: "413 Payload Too Large", message: "request body too large")
            }
            contentLength = value
        }
        let head = HTTPRequestHead(
            method: String(parts[0]), path: String(parts[1]), headers: headers, contentLength: contentLength
        )
        return .request(head, bodyOffset: end.upperBound - buffer.startIndex)
    }
}
