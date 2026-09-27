import Foundation

/// A tool's declaration as data: the OpenAI function JSON is built from it,
/// and the same fields drive the lenient reading of the model's arguments
/// (aliases, types, allowed values) and the errors that tell it how to
/// retry -- declared once, next to each other.
public struct ToolSchema: Sendable {
    public struct Param: Sendable {
        public enum Kind: Sendable, Equatable {
            case string, integer, number, boolean
            /// One of these strings.
            case oneOf([String])
        }

        public var name: String
        public var kind: Kind
        /// Only where the name doesn't say it.
        public var description: String?
        public var required: Bool
        /// Other names the model uses for it (q for query).
        public var aliases: [String]
        /// Other words for an allowed value (fahrenheit -> imperial).
        public var valueAliases: [String: String]

        public init(_ name: String, _ kind: Kind, _ description: String? = nil, required: Bool = false,
                    aliases: [String] = [], valueAliases: [String: String] = [:]) {
            self.name = name
            self.kind = kind
            self.description = description
            self.required = required
            self.aliases = aliases
            self.valueAliases = valueAliases
        }

        var typeName: String {
            switch kind {
            case .string: return "string"
            case .integer: return "integer"
            case .number: return "number"
            case .boolean: return "boolean"
            case .oneOf(let values): return values.joined(separator: "|")
            }
        }

        var jsonSchema: [String: Any] {
            var out: [String: Any]
            switch kind {
            case .string: out = ["type": "string"]
            case .integer: out = ["type": "integer"]
            case .number: out = ["type": "number"]
            case .boolean: out = ["type": "boolean"]
            case .oneOf(let values): out = ["type": "string", "enum": values]
            }
            if let description { out["description"] = description }
            return out
        }

        /// A stand-in for the value in a retry example.
        var placeholder: Any {
            switch kind {
            case .string: return "<\(name)>"
            case .integer: return "<integer>"
            case .number: return "<number>"
            case .boolean: return "<true|false>"
            case .oneOf(let values): return values.joined(separator: "|")
            }
        }
    }

    public var name: String
    public var description: String
    public var params: [Param]

    public init(_ name: String, _ description: String, _ params: [Param] = []) {
        self.name = name
        self.description = description
        self.params = params
    }

    /// The request's `tools` entry.
    public var definition: [String: Any] {
        var properties: [String: Any] = [:]
        for p in params { properties[p.name] = p.jsonSchema }
        var parameters: [String: Any] = ["type": "object", "properties": properties]
        let required = params.filter(\.required).map(\.name)
        if !required.isEmpty { parameters["required"] = required }
        return ["type": "function", "function": ["name": name, "description": description, "parameters": parameters]]
    }

    public func param(_ name: String) -> Param? { params.first { $0.name == name } }
}

/// What a call's arguments came to.
public struct ParsedToolArguments {
    public enum Problem: Equatable, Sendable {
        /// Not JSON even leniently (the parser's reason).
        case badJSON(String)
        /// A required field is missing.
        case missing(String)
        /// A value of the wrong type (field, what was sent).
        case wrongType(String, String)
        /// Not one of the allowed values (field, what was sent).
        case notAllowed(String, String)
        /// Two of its names with different values (location and place).
        case conflicting(String)

        public var statsKind: String {
            switch self {
            case .badJSON: return "bad_json"
            case .missing: return "missing_field"
            case .wrongType: return "bad_type"
            case .notAllowed, .conflicting: return "bad_value"
            }
        }
    }

    /// The fields understood, under their declared names and types
    /// (Int, Double, Bool, String); unknown fields are left out.
    public var values: [String: Any]
    public var repairs: [ToolRepair]
    public var problems: [Problem]

    public var isValid: Bool { problems.isEmpty }

    public init(values: [String: Any], repairs: [ToolRepair], problems: [Problem]) {
        self.values = values
        self.repairs = repairs
        self.problems = problems
    }
}

public enum ToolArgumentParser {
    /// Common wrappers a model puts the arguments in.
    static let wrapperKeys = ["arguments", "parameters", "args", "input", "params"]

    /// `raw`, the call's arguments text, read against `schema`; nil reads
    /// the JSON only (a tool without a schema).
    public static func parse(_ raw: String, schema: ToolSchema?) -> ParsedToolArguments {
        var repairs: [ToolRepair] = []
        let object: [String: Any]
        switch LenientJSON.parse(raw) {
        case .failure(let failure):
            return ParsedToolArguments(values: [:], repairs: [], problems: [.badJSON(failure.reason)])
        case .success(let parsed):
            repairs = parsed.repairs
            guard let dict = parsed.value as? [String: Any] else {
                return ParsedToolArguments(values: [:], repairs: repairs, problems: [.badJSON("expected a JSON object")])
            }
            switch unwrap(dict, schema: schema, repairs: &repairs) {
            case .success(let inner): object = inner
            case .failure(let failure):
                return ParsedToolArguments(values: [:], repairs: repairs, problems: [.badJSON(failure.reason)])
            }
        }
        guard let schema else { return ParsedToolArguments(values: object, repairs: repairs, problems: []) }
        return normalize(object, schema: schema, repairs: repairs)
    }

    /// `{"name": "x", "arguments": {...}}`, `{"arguments": "{...}"}`,
    /// `{"calculate": {...}}`: the inner object, when the wrapper isn't
    /// one of the tool's own fields. For a tool with a schema, two wrappers
    /// or a wrapper that isn't an object are a failure, not empty
    /// arguments; without one they may be the tool's fields, kept as sent.
    static func unwrap(_ dict: [String: Any], schema: ToolSchema?, repairs: inout [ToolRepair]) -> Result<[String: Any], LenientJSON.Failure> {
        let own = Set(schema?.params.flatMap { [$0.name] + $0.aliases }.map(normalizedKey) ?? [])
        guard !dict.keys.contains(where: { own.contains(normalizedKey($0)) }) else { return .success(dict) }
        let wrappers = dict.keys.filter { key in
            wrapperKeys.contains(key.lowercased()) || (schema.map { key == $0.name } ?? false)
        }.sorted()
        // Only wrappers, or wrappers and the tool's name / type.
        guard !wrappers.isEmpty,
              dict.keys.allSatisfy({ wrappers.contains($0) || $0.lowercased() == "name" || $0.lowercased() == "type" })
        else { return .success(dict) }
        func fail(_ reason: String) -> Result<[String: Any], LenientJSON.Failure> {
            schema == nil ? .success(dict) : .failure(.init(reason: reason))
        }
        guard wrappers.count == 1 else {
            return fail("arguments wrapped twice: " + wrappers.map { "\"\($0)\"" }.joined(separator: " and "))
        }
        let wrapper = wrappers[0]
        let inner: [String: Any]
        switch dict[wrapper] {
        case let obj as [String: Any]:
            inner = obj
        case is NSNull:
            inner = [:]
        case let text as String:
            guard case .success(let parsed) = LenientJSON.parse(text), let obj = parsed.value as? [String: Any] else {
                return fail("\"\(wrapper)\" isn't a JSON object")
            }
            inner = obj
            repairs += parsed.repairs
        default:
            return fail("\"\(wrapper)\" isn't a JSON object")
        }
        repairs.append(.nestedArguments)
        return unwrap(inner, schema: schema, repairs: &repairs)
    }

    /// "country_code", "countryCode", "Country-Code" read alike.
    static func normalizedKey(_ key: String) -> String {
        key.lowercased().filter { $0 != "_" && $0 != "-" && $0 != " " }
    }

    static func normalize(_ object: [String: Any], schema: ToolSchema, repairs start: [ToolRepair]) -> ParsedToolArguments {
        var repairs = start
        var values: [String: Any] = [:]
        var problems: [ParsedToolArguments.Problem] = []
        // Which field each sent key is, if any.
        var byParam: [String: [(key: String, value: Any, exact: Bool)]] = [:]
        for (key, value) in object {
            if schema.param(key) != nil {
                byParam[key, default: []].append((key, value, true))
                continue
            }
            let n = normalizedKey(key)
            let matches = schema.params.filter { p in normalizedKey(p.name) == n || p.aliases.contains { normalizedKey($0) == n } }
            if matches.count == 1 {
                byParam[matches[0].name, default: []].append((key, value, false))
            } else {
                repairs.append(.unknownField)
            }
        }
        for param in schema.params {
            guard var sent = byParam[param.name] else {
                if param.required { problems.append(.missing(param.name)) }
                continue
            }
            // The declared name wins over an alias sent beside it; two
            // aliases with different values are a guess.
            sent.sort { $0.exact && !$1.exact }
            if sent.count > 1, !sent[0].exact,
               sent.dropFirst().contains(where: { !LenientJSON.same($0.value, sent[0].value) }) {
                problems.append(.conflicting(param.name))
                continue
            }
            if sent.count > 1 { repairs.append(.unknownField) }
            let chosen = sent[0]
            if !chosen.exact { repairs.append(.fieldAlias) }
            if chosen.value is NSNull {
                repairs.append(.nullDropped)
                if param.required { problems.append(.missing(param.name)) }
                continue
            }
            switch coerce(chosen.value, to: param) {
            case .ok(let value, let fixes):
                values[param.name] = value
                repairs += fixes
            case .wrongType(let sentText):
                problems.append(.wrongType(param.name, sentText))
            case .notAllowed(let sentText):
                problems.append(.notAllowed(param.name, sentText))
            }
        }
        var seen = Set<ToolRepair>()
        return ParsedToolArguments(values: values, repairs: repairs.filter { seen.insert($0).inserted }, problems: problems)
    }

    enum Coerced {
        case ok(Any, [ToolRepair])
        case wrongType(String)
        case notAllowed(String)
    }

    /// Swift's Bool, or JSONSerialization's boolean NSNumber.
    static func isBool(_ value: Any) -> Bool {
        if type(of: value) == Bool.self { return true }
        if type(of: value) == Int.self || type(of: value) == Double.self { return false }
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// A number from JSONSerialization (NSNumber) or the lenient parser
    /// (Int, Double), and whether it was written as an integer. Not a
    /// boolean.
    static func number(_ value: Any) -> (value: Double, integer: Bool)? {
        if isBool(value) { return nil }
        if type(of: value) == Int.self, let i = value as? Int { return (Double(i), true) }
        if type(of: value) == Double.self, let d = value as? Double { return (d, false) }
        guard !(value is String), let n = value as? NSNumber else { return nil }
        return (n.doubleValue, !CFNumberIsFloatType(n))
    }

    static func numeric(_ value: Any) -> Double? { number(value)?.value }

    /// A number written as an integer, exactly (a Double can't tell
    /// integers above 2^53 apart).
    static func integer(_ value: Any) -> Int? {
        guard number(value)?.integer == true else { return nil }
        if type(of: value) == Int.self { return value as? Int }
        return (value as? NSNumber).flatMap { Int($0.stringValue) }
    }

    static func shortText(_ value: Any) -> String {
        let text: String
        if let s = value as? String { text = "\"\(s)\"" }
        else if isBool(value) { text = ((value as? NSNumber)?.boolValue ?? (value as? Bool) ?? false) ? "true" : "false" }
        else if let n = numeric(value) { text = n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n) }
        else if value is [Any] { text = "a list" }
        else if value is [String: Any] { text = "an object" }
        else { text = "\(value)" }
        return text.count > 40 ? String(text.prefix(39)) + "…\"" : text
    }

    static func coerce(_ value: Any, to param: ToolSchema.Param) -> Coerced {
        switch param.kind {
        case .string:
            if let s = value as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return .ok(trimmed, trimmed == s ? [] : [.whitespace])
            }
            if !isBool(value), let n = numeric(value) {
                // 5 for "5"; an integer stays one ("2024", not "2024.0").
                let text = integer(value).map(String.init) ?? (n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n))
                return .ok(text, [.typeCoerced])
            }
            return .wrongType(shortText(value))
        case .integer:
            if !isBool(value), let n = numeric(value) {
                guard n == n.rounded(), abs(n) < 1e15 else { return .wrongType(shortText(value)) }
                return .ok(Int(n), number(value)?.integer == true ? [] : [.typeCoerced])
            }
            if let s = value as? String, let n = Int(s.trimmingCharacters(in: .whitespaces)) {
                return .ok(n, [.typeCoerced])
            }
            if let s = value as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)), d == d.rounded(), abs(d) < 1e15 {
                return .ok(Int(d), [.typeCoerced])
            }
            return .wrongType(shortText(value))
        case .number:
            if !isBool(value), let n = numeric(value) {
                guard n.isFinite else { return .wrongType(shortText(value)) }
                return .ok(n, [])
            }
            // "2.5" yes; "1,5" or "1,000" could be either: no.
            if let s = value as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite {
                return .ok(d, [.typeCoerced])
            }
            return .wrongType(shortText(value))
        case .boolean:
            if isBool(value) { return .ok((value as? NSNumber)?.boolValue ?? (value as? Bool) ?? false, []) }
            if let s = value as? String {
                switch s.trimmingCharacters(in: .whitespaces).lowercased() {
                case "true": return .ok(true, [.typeCoerced])
                case "false": return .ok(false, [.typeCoerced])
                default: break
                }
            }
            return .wrongType(shortText(value))
        case .oneOf(let allowed):
            guard let s = value as? String else { return .wrongType(shortText(value)) }
            if allowed.contains(s) { return .ok(s, []) }
            let folded = s.trimmingCharacters(in: .whitespaces).lowercased()
            if let match = allowed.first(where: { $0.lowercased() == folded }) { return .ok(match, [.enumValue]) }
            if let target = param.valueAliases.first(where: { $0.key.lowercased() == folded })?.value, allowed.contains(target) {
                return .ok(target, [.enumValue])
            }
            return .notAllowed(shortText(value))
        }
    }
}

extension ParsedToolArguments {
    /// What the model reads when its call couldn't be understood: the
    /// field and what it must be, and the call to send instead -- built
    /// from what it sent, a placeholder where a value is missing or wrong.
    public func errorMessage(tool schema: ToolSchema) -> String? {
        guard !problems.isEmpty else { return nil }
        var parts: [String] = []
        for problem in problems.prefix(3) {
            switch problem {
            case .badJSON(let reason):
                parts.append("arguments aren't a JSON object (\(reason))")
            case .missing(let field):
                parts.append("\"\(field)\" is required (\(schema.param(field)?.typeName ?? "value"))")
            case .wrongType(let field, let sent):
                parts.append("\"\(field)\" must be \(article(schema.param(field)?.typeName ?? "value")), not \(sent)")
            case .notAllowed(let field, let sent):
                let allowed = schema.param(field).map { p -> String in
                    if case .oneOf(let v) = p.kind { return v.joined(separator: ", ") }
                    return p.typeName
                } ?? ""
                parts.append("\"\(field)\" must be one of \(allowed), not \(sent)")
            case .conflicting(let field):
                parts.append("\"\(field)\" was given twice under different names with different values")
            }
        }
        return "\(schema.name): " + parts.joined(separator: "; ") + ". Retry: " + retryExample(schema)
    }

    private func article(_ type: String) -> String {
        type.contains("|") ? "one of \(type.replacingOccurrences(of: "|", with: ", "))"
            : (type.first.map { "aeiou".contains($0) } == true ? "an \(type)" : "a \(type)")
    }

    /// `name({...})` with the understood values, placeholders for the
    /// fields that are missing or wrong.
    public func retryExample(_ schema: ToolSchema) -> String {
        var example: [String: Any] = [:]
        for p in schema.params {
            if let v = values[p.name] { example[p.name] = v }
        }
        for problem in problems {
            switch problem {
            case .missing(let f), .wrongType(let f, _), .notAllowed(let f, _), .conflicting(let f):
                if let p = schema.param(f) { example[p.name] = p.placeholder }
            case .badJSON:
                for p in schema.params where p.required { example[p.name] = p.placeholder }
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: example, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        var text = String(decoding: data, as: UTF8.self)
        // Integer / number stand-ins unquoted, as the value will be.
        text = text.replacingOccurrences(of: "\"<integer>\"", with: "<integer>").replacingOccurrences(of: "\"<number>\"", with: "<number>")
            .replacingOccurrences(of: "\"<true|false>\"", with: "<true|false>")
        return "\(schema.name)(\(text))"
    }
}

/// Which declared tool a call's name means: exact; another case or a
/// "functions." prefix; a former tool now folded into another (with the
/// arguments that choose its mode).
public enum ToolNameResolver {
    public struct Resolved: Equatable {
        public let name: String
        /// Arguments the former name implies; the call's own win.
        public let impliedArguments: [String: String]
        public let repair: ToolRepair?
    }

    public static func resolve(_ called: String, known: [String], former: [String: (tool: String, arguments: [String: String])]) -> Resolved? {
        if known.contains(called) { return Resolved(name: called, impliedArguments: [:], repair: nil) }
        var bare = called.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["functions.", "function.", "tools.", "tool."] where bare.lowercased().hasPrefix(prefix) {
            bare = String(bare.dropFirst(prefix.count))
        }
        // Case, underscores and dashes aside: "Calculate", "hacker_news",
        // "get-weather".
        let folded = ToolArgumentParser.normalizedKey(bare)
        let matches = known.filter { ToolArgumentParser.normalizedKey($0) == folded }
        if matches.count == 1 { return Resolved(name: matches[0], impliedArguments: [:], repair: .toolName) }
        let formerMatches = former.filter { ToolArgumentParser.normalizedKey($0.key) == folded && known.contains($0.value.tool) }
        if formerMatches.count == 1, let target = formerMatches.first?.value {
            return Resolved(name: target.tool, impliedArguments: target.arguments, repair: .formerToolName)
        }
        return nil
    }
}
