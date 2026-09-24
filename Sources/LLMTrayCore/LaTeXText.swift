import Foundation

/// Turns the LaTeX math that models write (`\sqrt{144} \times (25/5)`,
/// `x^2 + y_n`, `\frac{a}{b}`, Greek letters, relations) into plain Unicode
/// text (`√144 × (25/5)`, `x² + yₙ`, `a/b`) -- readable in the chat without a
/// math-rendering engine or web view. Unknown commands degrade to their
/// name; nothing is dropped silently.
public enum LaTeXText {
    public static func toUnicode(_ latex: String) -> String {
        var parser = Parser(Array(latex))
        return parser.parse(until: nil)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Tables

    static let symbols: [String: String] = [
        // Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // operators and relations
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆", "circ": "∘",
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠", "approx": "≈", "equiv": "≡",
        "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫",
        "infty": "∞", "partial": "∂", "nabla": "∇", "forall": "∀", "exists": "∃", "nexists": "∄",
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "emptyset": "∅", "varnothing": "∅", "setminus": "∖",
        "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨", "neg": "¬", "lnot": "¬", "oplus": "⊕", "otimes": "⊗",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "leftrightarrow": "↔", "Rightarrow": "⇒",
        "Leftarrow": "⇐", "Leftrightarrow": "⇔", "implies": "⇒", "iff": "⇔", "mapsto": "↦", "uparrow": "↑",
        "downarrow": "↓", "longrightarrow": "⟶",
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        "angle": "∠", "degree": "°", "perp": "⊥", "parallel": "∥", "mid": "∣", "prime": "′",
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "therefore": "∴", "because": "∵",
        "checkmark": "✓", "triangle": "△", "square": "□", "bullet": "•",
        // spacing and escapes
        ",": " ", ";": " ", ":": " ", "!": "", " ": " ", "quad": "  ", "qquad": "   ",
        "{": "{", "}": "}", "%": "%", "$": "$", "&": "&", "#": "#", "_": "_", "\\": "\n",
        // named functions keep their names
        "sin": "sin", "cos": "cos", "tan": "tan", "cot": "cot", "sec": "sec", "csc": "csc",
        "arcsin": "arcsin", "arccos": "arccos", "arctan": "arctan", "sinh": "sinh", "cosh": "cosh", "tanh": "tanh",
        "log": "log", "ln": "ln", "lg": "lg", "exp": "exp", "lim": "lim", "max": "max", "min": "min",
        "sup": "sup", "inf": "inf", "det": "det", "gcd": "gcd", "deg": "deg", "arg": "arg", "mod": "mod",
        "bmod": "mod",
    ]

    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "k": "ᵏ", "m": "ᵐ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ",
        "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "T": "ᵀ", "′": "′", "∗": "*", "*": "*", "°": "°",
    ]

    static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ",
        "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ",
        "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]

    /// `2` -> `²`, `n+1` -> `ⁿ⁺¹`; nil when some character has no small form.
    static func script(_ text: String, _ table: [Character: Character]) -> String? {
        let trimmed = text.replacingOccurrences(of: " ", with: "")
        guard !trimmed.isEmpty else { return "" }
        var out = ""
        for c in trimmed {
            guard let small = table[c] else { return nil }
            out.append(small)
        }
        return out
    }

    // MARK: - Parser

    struct Parser {
        let chars: [Character]
        var i = 0
        var depth = 0

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { i >= chars.count }

        /// Converts until `terminator` (consumed) or the end.
        mutating func parse(until terminator: Character?) -> String {
            depth += 1
            defer { depth -= 1 }
            var out = ""
            while !atEnd {
                let c = chars[i]
                if let terminator, c == terminator { i += 1; return out }
                // Nesting beyond any real formula: braces dropped, text kept.
                guard depth < 64 else {
                    if c != "{" && c != "}" { out.append(c) }
                    i += 1
                    continue
                }
                switch c {
                case "\\":
                    out += command()
                case "{":
                    i += 1
                    out += parse(until: "}")
                case "^", "_":
                    i += 1
                    let argument = group()
                    let table = c == "^" ? LaTeXText.superscripts : LaTeXText.subscripts
                    if let small = LaTeXText.script(argument, table) {
                        out += small
                    } else {
                        out += String(c) + (argument.count == 1 ? argument : "(\(argument))")
                    }
                case "&":
                    out += " "   // alignment in environments
                    i += 1
                case "~":
                    out += " "
                    i += 1
                default:
                    out.append(c)
                    i += 1
                }
            }
            return out
        }

        /// One argument: `{...}`, a command, or a single character.
        mutating func group() -> String {
            while !atEnd, chars[i] == " " { i += 1 }
            guard !atEnd else { return "" }
            if chars[i] == "{" {
                i += 1
                return parse(until: "}")
            }
            if chars[i] == "\\" { return command() }
            defer { i += 1 }
            return String(chars[i])
        }

        /// `[...]`, if present (e.g. the root in \sqrt[3]{x}).
        mutating func optionalArgument() -> String? {
            guard !atEnd, chars[i] == "[" else { return nil }
            i += 1
            var inner: [Character] = []
            while !atEnd, chars[i] != "]" { inner.append(chars[i]); i += 1 }
            if !atEnd { i += 1 }
            var nested = Parser(inner)
            nested.depth = depth   // nested \sqrt[ ... counts toward the same limit
            return nested.parse(until: nil)
        }

        mutating func command() -> String {
            depth += 1
            defer { depth -= 1 }
            i += 1   // backslash
            // \sqrt\sqrt\sqrt... recurses via group(): the same budget.
            guard depth < 64 else {
                while !atEnd, chars[i].isLetter { i += 1 }
                return ""
            }
            guard !atEnd else { return "\\" }
            var name = ""
            if chars[i].isLetter {
                while !atEnd, chars[i].isLetter { name.append(chars[i]); i += 1 }
            } else {
                name = String(chars[i])
                i += 1
            }
            switch name {
            case "frac", "dfrac", "tfrac":
                let a = group(), b = group()
                if !a.isEmpty, !b.isEmpty, a.allSatisfy(\.isNumber), b.allSatisfy(\.isNumber),
                   let top = LaTeXText.script(a, LaTeXText.superscripts), let bottom = LaTeXText.script(b, LaTeXText.subscripts) {
                    return top + "⁄" + bottom
                }
                return Self.wrap(a) + "/" + Self.wrap(b)
            case "sqrt":
                let root = optionalArgument()
                let body = group()
                let radical = root.flatMap { LaTeXText.script($0, LaTeXText.superscripts) }.map { $0 + "√" } ?? (root.map { "\($0)√" } ?? "√")
                return radical + Self.wrap(body)
            case "text", "textrm", "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "operatorname", "textbf",
                 "textit", "boldsymbol", "mathbb", "mathcal", "mathfrak", "bm", "mbox":
                let body = group()
                if name == "mathbb", let bb = Self.doubleStruck[body] { return bb }
                return body
            case "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "displaystyle", "limits", "nolimits":
                // Sizing only; \left. / \right. are invisible delimiters.
                if !atEnd, chars[i] == "." { i += 1 }
                return ""
            case "overline", "bar":
                return Self.combine(group(), "\u{0305}")
            case "hat", "widehat":
                return Self.combine(group(), "\u{0302}")
            case "vec":
                return Self.combine(group(), "\u{20D7}")
            case "dot":
                return Self.combine(group(), "\u{0307}")
            case "tilde", "widetilde":
                return Self.combine(group(), "\u{0303}")
            case "begin", "end":
                _ = group()   // environment name (matrix, cases, aligned...)
                return name == "begin" ? "" : " "
            default:
                if let symbol = LaTeXText.symbols[name] {
                    // Named functions need a gap before their argument.
                    return symbol.count > 1 && symbol.first!.isLetter ? symbol + " " : symbol
                }
                return name
            }
        }

        static let doubleStruck: [String: String] = ["R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ"]

        /// Parentheses around anything longer than one simple token.
        static func wrap(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.count <= 1 || t.allSatisfy({ $0.isNumber || $0 == "." }) || t.allSatisfy(\.isLetter) { return t }
            if t.hasPrefix("("), t.hasSuffix(")") { return t }
            return "(\(t))"
        }

        static func combine(_ s: String, _ mark: String) -> String {
            s.count == 1 ? s + mark : s
        }
    }
}

/// Finds the math in a line of chat text: `$...$`, `\(...\)` inline and
/// `$$...$$`, `\[...\]` display. A `$` counts as math only when the text
/// between looks like math, so "$5 and $10" stays money.
public enum MathSpans {
    public enum Piece: Equatable {
        case text(String)
        case math(String, display: Bool)
    }

    public static func split(_ text: String) -> [Piece] {
        let pattern = #"\$\$(.+?)\$\$|\\\[(.+?)\\\]|\\\((.+?)\\\)|(?<![\\$\w])\$(?=\S)([^$\n]+?)(?<=\S)\$(?![\w$])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [.text(text)] }
        let ns = text as NSString
        var pieces: [Piece] = []
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var body: String?
            var display = false
            for (group, isDisplay) in [(1, true), (2, true), (3, false), (4, false)] {
                let r = match.range(at: group)
                if r.location != NSNotFound { body = ns.substring(with: r); display = isDisplay; break }
            }
            guard let math = body else { continue }
            // Single-dollar and \[ spans only if they read as math -- not
            // prices ("$5 and $10") or markdown-escaped brackets ("\[1\]").
            // \( \) is explicit LaTeX and always math.
            let ambiguous = match.range(at: 2).location != NSNotFound || match.range(at: 4).location != NSNotFound
            if ambiguous, !looksLikeMath(math) { continue }
            if match.range.location > last {
                pieces.append(.text(ns.substring(with: NSRange(location: last, length: match.range.location - last))))
            }
            pieces.append(.math(math, display: display))
            last = match.range.location + match.range.length
        }
        if last < ns.length { pieces.append(.text(ns.substring(from: last))) }
        return pieces.isEmpty ? [.text(text)] : pieces
    }

    static func looksLikeMath(_ s: String) -> Bool {
        if s.contains("\\") || s.contains("^") || s.contains("_") || s.contains("=") { return true }
        // A lone variable or a tiny expression: $x$, $n+1$, $a \cdot b$
        return s.count <= 12 && s.contains { $0.isLetter } && !s.contains(" ")
    }
}
