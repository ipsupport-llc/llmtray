import Foundation

/// A fix applied to a tool call before it runs: the call was understood,
/// but not as sent. Counted per tool (ToolCallStats); the raw values are
/// the stats file's keys, so they don't change.
public enum ToolRepair: String, CaseIterable, Codable, Sendable {
    /// Wrapped in a ``` fence.
    case fenced
    /// Prose before or after the JSON object.
    case surroundingText
    /// 'single quoted' strings.
    case singleQuotes
    /// `{"a": 1,}`.
    case trailingComma
    /// Python's True / False / None.
    case pythonLiteral
    /// `{query: "x"}`.
    case unquotedKey
    /// A raw newline or tab inside a string.
    case rawControlCharacter
    /// The object sent as a JSON string.
    case doubleEncoded
    /// `{"name": ..., "arguments": {...}}` or `{"arguments": {...}}`.
    case nestedArguments
    /// A declared alias (q -> query) or another spelling of the name
    /// (Query, countryCode -> country_code).
    case fieldAlias
    /// "5" for an integer, "2.5" for a number, "true" for a boolean,
    /// 3.0 for an integer, 5 for a string.
    case typeCoerced
    /// "Hourly" -> hourly, "fahrenheit" -> imperial.
    case enumValue
    /// Leading or trailing whitespace in a string.
    case whitespace
    /// `"field": null` -- taken as not given.
    case nullDropped
    /// A field the tool doesn't have -- ignored.
    case unknownField
    /// The tool's name in another case or with a prefix ("functions.x").
    case toolName
    /// A former tool's name, now a mode of another tool.
    case formerToolName
}

/// Tool-call arguments as small local models write them: JSON, or nearly
/// JSON. Only what reads one way is fixed (a fence, prose around the
/// object, single quotes, trailing commas, Python literals, bare keys, a
/// double-encoded object); anything else is left unparsed.
public enum LenientJSON {
    public struct Failure: Error, Equatable {
        public let reason: String
    }

    /// The value and the fixes it took. Empty input is `{}`.
    public static func parse(_ text: String) -> Result<(value: Any, repairs: [ToolRepair]), Failure> {
        var repairs: [ToolRepair] = []
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty || body == "null" { return .success(([String: Any](), [])) }
        if let strict = strictObject(body) { return .success((strict, [])) }
        if let unfenced = stripFence(body) {
            body = unfenced
            repairs.append(.fenced)
            if body.isEmpty { return .success(([String: Any](), repairs)) }
        }
        // Prose around the object: from the first brace (a lone value like
        // "5" isn't an object either way).
        if !body.hasPrefix("{") && !body.hasPrefix("\""), let brace = body.firstIndex(of: "{") {
            body = String(body[brace...])
            repairs.append(.surroundingText)
        }
        var parser = Parser(Array(body.unicodeScalars))
        do {
            var value = try parser.value()
            parser.skipWhitespace()
            if !parser.atEnd {
                // Text after a complete object.
                guard value is [String: Any] else { throw Failure(reason: "unexpected text after the value") }
                // A second object: which one was meant isn't ours to pick.
                guard !parser.s[parser.i...].contains("{") else { throw Failure(reason: "more than one object") }
                if !repairs.contains(.surroundingText) { repairs.append(.surroundingText) }
            }
            repairs += parser.repairs
            // The object as a JSON string.
            if let string = value as? String {
                guard case .success(let inner) = parse(string), inner.value is [String: Any] else {
                    throw Failure(reason: "expected a JSON object, got a string")
                }
                value = inner.value
                repairs.append(.doubleEncoded)
                repairs += inner.repairs
            }
            return .success((value, dedupe(repairs)))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(Failure(reason: "not JSON"))
        }
    }

    private static func dedupe(_ repairs: [ToolRepair]) -> [ToolRepair] {
        var seen = Set<ToolRepair>()
        return repairs.filter { seen.insert($0).inserted }
    }

    private static func strictObject(_ text: String) -> Any? {
        guard text.hasPrefix("{"), let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// The inside of a ``` / ```json fence, if the text is one (or has one).
    static func stripFence(_ text: String) -> String? {
        guard let open = text.range(of: "```") else { return nil }
        var inner = text[open.upperBound...]
        // The fence's language tag.
        if let newline = inner.firstIndex(where: \.isNewline) {
            let tag = inner[..<newline].trimmingCharacters(in: .whitespaces)
            if tag.isEmpty || tag.allSatisfy({ $0.isLetter }) { inner = inner[inner.index(after: newline)...] }
        } else if inner.hasPrefix("json") {
            inner = inner.dropFirst(4)
        }
        if let close = inner.range(of: "```") { inner = inner[..<close.lowerBound] }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// JSON plus the unambiguous slips. Numbers without a fraction or
    /// exponent are Int, others Double; booleans are Bool.
    struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        var repairs: [ToolRepair] = []
        var depth = 0

        init(_ s: [Unicode.Scalar]) { self.s = s }

        var atEnd: Bool { i >= s.count }
        var peek: Unicode.Scalar? { i < s.count ? s[i] : nil }

        mutating func skipWhitespace() {
            while let c = peek, c == " " || c == "\n" || c == "\r" || c == "\t" { i += 1 }
        }

        mutating func value() throws -> Any {
            skipWhitespace()
            guard let c = peek else { throw Failure(reason: "unexpected end") }
            switch c {
            case "{": return try object()
            case "[": return try array()
            case "\"", "'": return try string()
            case "-", "0"..."9": return try number()
            default:
                let word = identifier()
                switch word {
                case "true": return true
                case "false": return false
                case "null": return NSNull()
                case "True": repairs.append(.pythonLiteral); return true
                case "False": repairs.append(.pythonLiteral); return false
                case "None": repairs.append(.pythonLiteral); return NSNull()
                default: throw Failure(reason: word.isEmpty ? "unexpected character \(c)" : "unexpected word \(word)")
                }
            }
        }

        mutating func identifier() -> String {
            var out = ""
            while let c = peek, c == "_" || c == "$" || CharacterSet.alphanumerics.contains(c) {
                out.unicodeScalars.append(c)
                i += 1
            }
            return out
        }

        mutating func object() throws -> [String: Any] {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { throw Failure(reason: "nested too deep") }
            i += 1   // {
            var out: [String: Any] = [:]
            while true {
                skipWhitespace()
                guard let c = peek else { throw Failure(reason: "unclosed object") }
                if c == "}" { i += 1; return out }
                let key: String
                if c == "\"" || c == "'" {
                    key = try string()
                } else {
                    key = identifier()
                    guard !key.isEmpty else { throw Failure(reason: "expected a field name") }
                    repairs.append(.unquotedKey)
                }
                skipWhitespace()
                guard peek == ":" else { throw Failure(reason: "expected : after \"\(key)\"") }
                i += 1
                out[key] = try value()
                skipWhitespace()
                if peek == "," {
                    i += 1
                    skipWhitespace()
                    if peek == "}" { repairs.append(.trailingComma) }
                } else if peek != "}" {
                    throw Failure(reason: "expected , or } after \"\(key)\"")
                }
            }
        }

        mutating func array() throws -> [Any] {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { throw Failure(reason: "nested too deep") }
            i += 1   // [
            var out: [Any] = []
            while true {
                skipWhitespace()
                guard let c = peek else { throw Failure(reason: "unclosed array") }
                if c == "]" { i += 1; return out }
                out.append(try value())
                skipWhitespace()
                if peek == "," {
                    i += 1
                    skipWhitespace()
                    if peek == "]" { repairs.append(.trailingComma) }
                } else if peek != "]" {
                    throw Failure(reason: "expected , or ]")
                }
            }
        }

        mutating func string() throws -> String {
            let quote = s[i]
            if quote == "'" { repairs.append(.singleQuotes) }
            i += 1
            var out = String.UnicodeScalarView()
            while let c = peek {
                i += 1
                if c == quote { return String(out) }
                if c == "\\" {
                    guard let e = peek else { break }
                    i += 1
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "u":
                        guard let unit = hex4() else { throw Failure(reason: "bad \\u escape") }
                        // A surrogate pair.
                        if (0xD800...0xDBFF).contains(unit), peek == "\\", i + 1 < s.count, s[i + 1] == "u" {
                            i += 2
                            guard let low = hex4(), (0xDC00...0xDFFF).contains(low),
                                  let scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) else {
                                throw Failure(reason: "bad surrogate pair")
                            }
                            out.append(scalar)
                        } else {
                            guard let scalar = Unicode.Scalar(unit) else { throw Failure(reason: "bad \\u escape") }
                            out.append(scalar)
                        }
                    default: out.append(e)   // \" \\ \/ \'
                    }
                } else {
                    if c.value < 0x20 {
                        if !repairs.contains(.rawControlCharacter) { repairs.append(.rawControlCharacter) }
                    }
                    out.append(c)
                }
            }
            throw Failure(reason: "unclosed string")
        }

        mutating func hex4() -> UInt32? {
            guard i + 4 <= s.count else { return nil }
            let text = String(String.UnicodeScalarView(s[i..<i + 4]))
            guard let v = UInt32(text, radix: 16) else { return nil }
            i += 4
            return v
        }

        mutating func number() throws -> Any {
            let start = i
            if peek == "-" { i += 1 }
            var fractional = false
            while let c = peek, ("0"..."9").contains(c) || c == "." || c == "e" || c == "E" || c == "+" || c == "-" {
                if c == "." || c == "e" || c == "E" { fractional = true }
                i += 1
            }
            let text = String(String.UnicodeScalarView(s[start..<i]))
            if !fractional, let int = Int(text) { return int }
            guard let d = Double(text), d.isFinite else { throw Failure(reason: "bad number \(text)") }
            return d
        }
    }
}
