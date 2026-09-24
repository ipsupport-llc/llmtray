import Foundation

/// Evaluates arithmetic for the chat's `calculate` tool with a small
/// recursive-descent parser -- no `eval`, no NSExpression (which can call
/// arbitrary selectors), nothing but numbers, operators and a fixed list of
/// math functions.
///
/// Grammar: `+ - * / // % ^ **`, unary minus, parentheses, the constants
/// `pi e tau`, and functions like `sqrt log(x[, base]) round(x[, digits])
/// min max hypot factorial gcd`.
public enum Calculator {
    public enum Failure: Error, Equatable, LocalizedError {
        case syntax(String)
        case unknown(String)
        case domain(String)

        public var errorDescription: String? {
            switch self {
            case .syntax(let s): return "syntax error: \(s)"
            case .unknown(let s): return "unknown name: \(s)"
            case .domain(let s): return "math error: \(s)"
            }
        }
    }

    public static func evaluate(_ expression: String) throws -> Double {
        var parser = Parser(tokens: try tokenize(expression))
        let value = try parser.expression()
        guard parser.atEnd else { throw Failure.syntax("unexpected '\(parser.peekText)'") }
        guard value.isFinite else { throw Failure.domain("result is not finite") }
        return value
    }

    /// The result as the tool reports it: integers without ".0", otherwise
    /// up to 12 significant digits.
    public static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.12g", value)
    }

    // MARK: - Lexer

    enum Token: Equatable {
        case number(Double)
        case name(String)
        case op(String)
        case lparen, rparen, comma
    }

    static func tokenize(_ s: String) throws -> [Token] {
        var tokens: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c.isWhitespace || c == "_" { i = s.index(after: i); continue }
            if c.isNumber || c == "." {
                var j = i
                while j < s.endIndex, s[j].isNumber || s[j] == "." || s[j] == "_" { j = s.index(after: j) }
                // exponent: 1e10, 2.5E-3
                if j < s.endIndex, s[j] == "e" || s[j] == "E" {
                    var k = s.index(after: j)
                    if k < s.endIndex, s[k] == "+" || s[k] == "-" { k = s.index(after: k) }
                    if k < s.endIndex, s[k].isNumber {
                        j = k
                        while j < s.endIndex, s[j].isNumber { j = s.index(after: j) }
                    }
                }
                let text = s[i..<j].replacingOccurrences(of: "_", with: "")
                guard let value = Double(text) else { throw Failure.syntax("bad number '\(text)'") }
                tokens.append(.number(value))
                i = j
                continue
            }
            if c.isLetter {
                var j = i
                while j < s.endIndex, s[j].isLetter || s[j].isNumber || s[j] == "_" { j = s.index(after: j) }
                let name = String(s[i..<j]).lowercased()
                // "math.sqrt(2)" -- Python-style prefix, dropped.
                if name == "math", j < s.endIndex, s[j] == "." {
                    i = s.index(after: j)
                    continue
                }
                tokens.append(.name(name))
                i = j
                continue
            }
            let two = s[i...].prefix(2)
            if two == "**" || two == "//" {
                tokens.append(.op(String(two)))
                i = s.index(i, offsetBy: 2)
                continue
            }
            switch c {
            case "+", "-", "*", "/", "%", "^": tokens.append(.op(String(c)))
            case "×": tokens.append(.op("*"))
            case "÷": tokens.append(.op("/"))
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            case ",": tokens.append(.comma)
            default: throw Failure.syntax("unexpected character '\(c)'")
            }
            i = s.index(after: i)
        }
        return tokens
    }

    // MARK: - Parser

    struct Parser {
        var tokens: [Token]
        var position = 0
        var depth = 0

        var atEnd: Bool { position >= tokens.count }
        var peekText: String { atEnd ? "end" : "\(tokens[position])" }

        mutating func next() -> Token? {
            guard !atEnd else { return nil }
            defer { position += 1 }
            return tokens[position]
        }

        func peek() -> Token? { atEnd ? nil : tokens[position] }

        // expression := term (('+' | '-') term)*
        mutating func expression() throws -> Double {
            depth += 1
            defer { depth -= 1 }
            guard depth < 200 else { throw Failure.syntax("expression nested too deeply") }
            var value = try term()
            while case .op(let op)? = peek(), op == "+" || op == "-" {
                position += 1
                let rhs = try term()
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        // term := unary (('*' | '/' | '//' | '%') unary)*
        mutating func term() throws -> Double {
            var value = try unary()
            while case .op(let op)? = peek(), ["*", "/", "//", "%"].contains(op) {
                position += 1
                let rhs = try unary()
                switch op {
                case "*": value *= rhs
                case "/":
                    guard rhs != 0 else { throw Failure.domain("division by zero") }
                    value /= rhs
                case "//":
                    guard rhs != 0 else { throw Failure.domain("division by zero") }
                    value = (value / rhs).rounded(.down)
                default:
                    guard rhs != 0 else { throw Failure.domain("modulo by zero") }
                    value = value - rhs * (value / rhs).rounded(.down)   // Python's sign convention
                }
            }
            return value
        }

        // unary := ('-' | '+') unary | power   -- so -2^2 = -4, as in Python
        mutating func unary() throws -> Double {
            depth += 1
            defer { depth -= 1 }
            guard depth < 200 else { throw Failure.syntax("expression nested too deeply") }
            if case .op(let op)? = peek(), op == "-" || op == "+" {
                position += 1
                let v = try unary()
                return op == "-" ? -v : v
            }
            return try power()
        }

        // power := primary (('^' | '**') unary)?   -- right-associative
        mutating func power() throws -> Double {
            let base = try primary()
            if case .op(let op)? = peek(), op == "^" || op == "**" {
                position += 1
                let exponent = try unary()
                let result = Foundation.pow(base, exponent)
                guard !result.isNaN else { throw Failure.domain("\(Calculator.format(base)) ^ \(Calculator.format(exponent)) is undefined") }
                return result
            }
            return base
        }

        mutating func primary() throws -> Double {
            switch next() {
            case .number(let v)?:
                return v
            case .lparen?:
                let v = try expression()
                guard case .rparen? = next() else { throw Failure.syntax("missing ')'") }
                return v
            case .name(let name)?:
                if case .lparen? = peek() {
                    position += 1
                    var args: [Double] = []
                    if case .rparen? = peek() {
                        position += 1
                    } else {
                        while true {
                            args.append(try expression())
                            switch next() {
                            case .comma?: continue
                            case .rparen?: break
                            default: throw Failure.syntax("missing ')' after arguments of \(name)")
                            }
                            break
                        }
                    }
                    return try Calculator.call(name, args)
                }
                if let constant = Calculator.constants[name] { return constant }
                throw Failure.unknown(name)
            case nil:
                throw Failure.syntax("unexpected end")
            case let token?:
                throw Failure.syntax("unexpected \(token)")
            }
        }
    }

    static let constants: [String: Double] = ["pi": .pi, "e": M_E, "tau": 2 * .pi]

    static func call(_ name: String, _ a: [Double]) throws -> Double {
        func arity(_ n: ClosedRange<Int>) throws {
            guard n.contains(a.count) else { throw Failure.syntax("\(name) takes \(n.lowerBound == n.upperBound ? "\(n.lowerBound)" : "\(n.lowerBound)-\(n.upperBound)") argument(s)") }
        }
        func domain(_ ok: Bool, _ why: String) throws { if !ok { throw Failure.domain(why) } }
        switch name {
        case "sqrt": try arity(1...1); try domain(a[0] >= 0, "sqrt of a negative number"); return a[0].squareRoot()
        case "cbrt": try arity(1...1); return Foundation.cbrt(a[0])
        case "log", "ln":
            try arity(1...2); try domain(a[0] > 0, "log of a non-positive number")
            if a.count == 2 { try domain(a[1] > 0 && a[1] != 1, "bad log base"); return Foundation.log(a[0]) / Foundation.log(a[1]) }
            return Foundation.log(a[0])
        case "log2": try arity(1...1); try domain(a[0] > 0, "log of a non-positive number"); return Foundation.log2(a[0])
        case "log10", "lg": try arity(1...1); try domain(a[0] > 0, "log of a non-positive number"); return Foundation.log10(a[0])
        case "exp": try arity(1...1); return Foundation.exp(a[0])
        case "sin": try arity(1...1); return Foundation.sin(a[0])
        case "cos": try arity(1...1); return Foundation.cos(a[0])
        case "tan": try arity(1...1); return Foundation.tan(a[0])
        case "asin": try arity(1...1); try domain(abs(a[0]) <= 1, "asin outside [-1, 1]"); return Foundation.asin(a[0])
        case "acos": try arity(1...1); try domain(abs(a[0]) <= 1, "acos outside [-1, 1]"); return Foundation.acos(a[0])
        case "atan": try arity(1...1); return Foundation.atan(a[0])
        case "atan2": try arity(2...2); return Foundation.atan2(a[0], a[1])
        case "sinh": try arity(1...1); return Foundation.sinh(a[0])
        case "cosh": try arity(1...1); return Foundation.cosh(a[0])
        case "tanh": try arity(1...1); return Foundation.tanh(a[0])
        case "floor": try arity(1...1); return a[0].rounded(.down)
        case "ceil": try arity(1...1); return a[0].rounded(.up)
        case "trunc": try arity(1...1); return a[0].rounded(.towardZero)
        case "abs", "fabs": try arity(1...1); return abs(a[0])
        case "degrees": try arity(1...1); return a[0] * 180 / .pi
        case "radians": try arity(1...1); return a[0] * .pi / 180
        case "round":
            try arity(1...2)
            let digits = a.count == 2 ? a[1] : 0
            let scale = Foundation.pow(10, digits)
            return (a[0] * scale).rounded(.toNearestOrEven) / scale
        case "min": try arity(1...64); return a.min()!
        case "max": try arity(1...64); return a.max()!
        case "sum": try arity(1...64); return a.reduce(0, +)
        case "pow": try arity(2...2); return Foundation.pow(a[0], a[1])
        case "hypot": try arity(2...2); return Foundation.hypot(a[0], a[1])
        case "factorial":
            try arity(1...1)
            try domain(a[0] >= 0 && a[0] == a[0].rounded() && a[0] <= 170, "factorial needs a whole number 0...170")
            return (0..<Int(a[0])).reduce(1.0) { $0 * Double($1 + 1) }
        case "gcd", "lcm":
            try arity(2...2)
            try domain(a.allSatisfy { $0 == $0.rounded() && abs($0) < 9e15 }, "\(name) needs whole numbers")
            var (x, y) = (Int64(abs(a[0])), Int64(abs(a[1])))
            let (ox, oy) = (x, y)
            while y != 0 { (x, y) = (y, x % y) }
            if name == "gcd" { return Double(x) }
            return x == 0 ? 0 : Double(ox / x) * Double(oy)   // no Int64 overflow
        default:
            throw Failure.unknown(name)
        }
    }
}
