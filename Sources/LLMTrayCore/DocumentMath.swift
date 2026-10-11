import Foundation

/// Math in a document's text (adr/0020, "Math"): the LaTeX a model writes
/// between `$…$` / `$$…$$` (or `\(…\)` / `\[…\]`) as MathML, which WebKit
/// lays out and prints. Our own reader of the common part of LaTeX --
/// fractions, roots, scripts, sums and integrals, Greek, operators,
/// accents, matrices and cases -- no script and no package. Like the rest
/// of the converter it emits only its own tags (`tags`), every text
/// escaped; an unknown command shows as written.
public enum DocumentMath {
    /// What it can emit (part of `DocumentHTML.allowedTags`).
    public static let tags: Set<String> = [
        "math", "mrow", "mi", "mn", "mo", "mtext", "msup", "msub", "msubsup", "mfrac", "msqrt", "mroot",
        "mover", "munder", "munderover", "mtable", "mtr", "mtd",
    ]

    /// How long a formula may be, and how deep its groups nest.
    public static let maxScalars = 4_000
    static let maxDepth = 24

    /// MathML for `tex`, or nil when it can't be read (unbalanced braces,
    /// too long, too deep): the text then stays as written.
    public static func mathML(_ tex: String, display: Bool) -> String? {
        guard tex.unicodeScalars.count <= maxScalars, !tex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var reader = Reader(Array(tex.unicodeScalars))
        guard let row = try? reader.expression(until: []), reader.atEnd else { return nil }
        return (display ? "<math display=\"block\">" : "<math>") + mrow(row) + "</math>"
    }

    // MARK: - Reading

    struct Failure: Error {}

    struct Reader {
        let s: [Unicode.Scalar]
        var i = 0
        var depth = 0
        /// The atom just read was a function name (sin, log): "applied to"
        /// and a thin space go after its scripts.
        var function = false

        init(_ s: [Unicode.Scalar]) { self.s = s }

        var atEnd: Bool { i >= s.count }
        func peek(_ k: Int = 0) -> Unicode.Scalar? { i + k < s.count ? s[i + k] : nil }

        mutating func skipSpace() {
            while let c = peek(), c.properties.isWhitespace { i += 1 }
        }

        /// Atoms with their scripts until one of `stops` (a command name
        /// such as "\\end", "&", "\\\\", "}" or "\\right") or the end.
        mutating func expression(until stops: Set<String>) throws -> [String] {
            depth += 1
            defer { depth -= 1 }
            guard depth <= DocumentMath.maxDepth else { throw Failure() }
            // A group is never a function name, whatever it ends with.
            defer { function = false }
            var out: [String] = []
            while true {
                skipSpace()
                guard let c = peek() else { break }
                if c == "}" { if stops.contains("}") { break } else { throw Failure() } }
                if c == "&", stops.contains("&") { break }
                if c == "]", stops.contains("]") { break }
                if c == "\\", let name = commandName(), stops.contains("\\" + name) { break }
                if c == "^" || c == "_" {
                    // A script with nothing before it: on an empty base.
                    out.append(try scripts(on: "<mrow></mrow>", limits: false))
                    continue
                }
                function = false
                guard let atom = try atom() else { continue }
                let applied = function
                var limits = atom.limits
                skipSpace()
                // \sum\limits_…: the operator's scripts, placed as asked.
                while let name = commandName(), name == "limits" || name == "nolimits" {
                    limits = name == "limits"
                    _ = readCommand()
                    skipSpace()
                }
                if let n = peek(), n == "^" || n == "_" || n == "'" {
                    // Nothing to put them on (a space, \displaystyle): an empty base.
                    out.append(try scripts(on: atom.html.isEmpty ? "<mrow></mrow>" : atom.html, limits: limits))
                } else {
                    out.append(atom.html)
                }
                if applied {
                    skipSpace()
                    // sin x, but sin(x).
                    let paren = peek() == "(" || (peek() == "\\" && ["left", "bigl", "Bigl", "big", "Big"].contains(commandName() ?? ""))
                    out.append("<mo>\u{2061}</mo>" + (paren ? "" : "<mtext>\u{2009}</mtext>"))
                }
            }
            return out
        }

        /// The name of the command at `i` (a `\` there), not consumed.
        func commandName() -> String? {
            guard peek() == "\\", let first = peek(1) else { return nil }
            guard first.properties.isAlphabetic, first.isASCII else { return String(Character(first)) }
            var k = i + 1
            var name = ""
            while k < s.count, s[k].isASCII, s[k].properties.isAlphabetic { name.unicodeScalars.append(s[k]); k += 1 }
            return name
        }

        mutating func readCommand() -> String {
            let name = commandName() ?? ""
            i += 1 + name.unicodeScalars.count
            return name
        }

        /// `^`, `_` and primes after a base: msub, msup, msubsup, or under
        /// and over for a sum's limits.
        mutating func scripts(on base: String, limits: Bool) throws -> String {
            var sub: String?
            var sup: String?
            var primes = ""
            while true {
                skipSpace()
                guard let c = peek() else { break }
                if c == "'" { primes += "′"; i += 1; continue }
                if c == "_", sub == nil { i += 1; sub = try argument(); continue }
                if c == "^", sup == nil { i += 1; sup = try argument(); continue }
                break
            }
            if !primes.isEmpty { sup = sup.map { "<mrow><mo>\(primes)</mo>\($0)</mrow>" } ?? "<mo>\(primes)</mo>" }
            switch (sub, sup) {
            case let (b?, p?): return limits ? "<munderover>\(base)\(b)\(p)</munderover>" : "<msubsup>\(base)\(b)\(p)</msubsup>"
            case let (b?, nil): return limits ? "<munder>\(base)\(b)</munder>" : "<msub>\(base)\(b)</msub>"
            case let (nil, p?): return limits ? "<mover>\(base)\(p)</mover>" : "<msup>\(base)\(p)</msup>"
            default: return base
            }
        }

        /// A command's argument or a script: `{…}` as one row, else one
        /// atom (`x^2`, `\frac12`).
        mutating func argument() throws -> String {
            skipSpace()
            guard let c = peek() else { throw Failure() }
            if c == "{" {
                i += 1
                let row = try expression(until: ["}"])
                guard peek() == "}" else { throw Failure() }
                i += 1
                return DocumentMath.mrow(row)
            }
            if c.isASCII, c.properties.numericType != nil {
                // One digit: \frac12 is 1 over 2.
                i += 1
                return "<mn>\(Character(c))</mn>"
            }
            guard let atom = try atom() else { throw Failure() }
            return atom.html
        }

        /// The text between braces as written (\text{…}).
        mutating func rawArgument() throws -> String {
            skipSpace()
            guard peek() == "{" else {
                guard let c = peek() else { throw Failure() }
                i += 1
                return String(Character(c))
            }
            i += 1
            var level = 1
            var out = ""
            while let c = peek() {
                i += 1
                if c == "{" { level += 1 }
                if c == "}" { level -= 1; if level == 0 { return out } }
                out.unicodeScalars.append(c)
            }
            throw Failure()
        }

        /// `[…]` if there: \sqrt's index.
        mutating func optional() throws -> String? {
            skipSpace()
            guard peek() == "[" else { return nil }
            i += 1
            let row = try expression(until: ["]"])
            guard peek() == "]" else { throw Failure() }
            i += 1
            return DocumentMath.mrow(row)
        }

        /// One thing: a number, a letter, an operator, a group or a
        /// command. `limits`: its scripts go under and over (∑, lim).
        mutating func atom() throws -> (html: String, limits: Bool)? {
            // \sqrt\sqrt\sqrt… nests without braces: counted here too.
            depth += 1
            defer { depth -= 1 }
            guard depth <= DocumentMath.maxDepth * 2 else { throw Failure() }
            skipSpace()
            guard let c = peek() else { return nil }
            if c == "{" {
                return (try argument(), false)
            }
            if c == "\\" { return try command() }
            if c.properties.numericType != nil, c.isASCII {
                var number = ""
                while let d = peek(), d.isASCII, d.properties.numericType != nil || (d == "." && peek(1)?.properties.numericType != nil && peek(1)?.isASCII == true) {
                    number.unicodeScalars.append(d)
                    i += 1
                }
                return ("<mn>\(number)</mn>", false)
            }
            i += 1
            if c.properties.isAlphabetic { return ("<mi>\(DocumentHTML.escape(String(Character(c))))</mi>", false) }
            switch c {
            case "-": return ("<mo>−</mo>", false)
            case "~": return ("<mtext>\u{00A0}</mtext>", false)
            case "&": return ("<mo>&amp;</mo>", false)   // outside a table: as written
            case "*": return ("<mo>∗</mo>", false)
            case "(", ")", "[", "]", "|":
                // As written, not stretched: \left and \right stretch.
                return ("<mo stretchy=\"false\">\(Character(c))</mo>", false)
            default:
                if let big = DocumentMath.bigOperators[String(Character(c))] { return ("<mo>\(big)</mo>", true) }
                return ("<mo>\(DocumentHTML.escape(String(Character(c))))</mo>", false)
            }
        }

        mutating func command() throws -> (html: String, limits: Bool)? {
            let name = readCommand()
            if name.isEmpty { return ("<mo>\\</mo>", false) }
            if let space = DocumentMath.spaces[name] { return (space.isEmpty ? "" : "<mtext>\(space)</mtext>", false) }
            if let symbol = DocumentMath.identifiers[name] { return ("<mi>\(DocumentHTML.escape(symbol))</mi>", false) }
            if let symbol = DocumentMath.upright[name] { return ("<mi mathvariant=\"normal\">\(DocumentHTML.escape(symbol))</mi>", false) }
            if let fence = DocumentMath.fences[name] { return ("<mo stretchy=\"false\">\(DocumentHTML.escape(fence))</mo>", false) }
            if let op = DocumentMath.operators[name] { return ("<mo>\(DocumentHTML.escape(op))</mo>", false) }
            if let big = DocumentMath.bigOperators[name] { return ("<mo>\(big)</mo>", !DocumentMath.integrals.contains(name)) }
            if DocumentMath.functions.contains(name) {
                // An upright name, then an invisible "applied to".
                function = true
                return ("<mi>\(name)</mi>", DocumentMath.limitFunctions.contains(name))
            }
            if let accent = DocumentMath.accents[name] {
                return ("<mover accent=\"true\">\(try argument())<mo>\(accent)</mo></mover>", false)
            }
            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                let top = try argument()
                return ("<mfrac>\(top)\(try argument())</mfrac>", false)
            case "binom", "dbinom", "tbinom":
                let top = try argument()
                return ("<mrow><mo>(</mo><mfrac linethickness=\"0\">\(top)\(try argument())</mfrac><mo>)</mo></mrow>", false)
            case "left":
                // \left( … \right): the content between, the fences
                // stretched to it.
                let open = try delimiter(stretchy: true)
                let inner = try expression(until: ["\\right"])
                guard commandName() == "right" else { throw Failure() }
                _ = readCommand()
                return ("<mrow>\(open)\(DocumentMath.mrow(inner))\(try delimiter(stretchy: true))</mrow>", false)
            case "right", "middle":
                return (try delimiter(stretchy: true), false)
            case "bigl", "bigr", "Bigl", "Bigr", "big", "Big", "bigg", "Bigg", "biggl", "biggr", "Biggl", "Biggr":
                return (try delimiter(stretchy: false), false)
            case "sqrt":
                if let index = try optional() { return ("<mroot>\(try argument())\(index)</mroot>", false) }
                return ("<msqrt>\(try argument())</msqrt>", false)
            case "underline":
                return ("<munder>\(try argument())<mo>_</mo></munder>", false)
            case "text", "textrm", "textit", "textbf", "mbox", "textnormal":
                return ("<mtext>\(DocumentHTML.escape(DocumentMath.textEscapes(try rawArgument())))</mtext>", false)
            case "operatorname":
                // A name as written (foo-bar too), applied like \sin.
                let name = try rawArgument().filter { !$0.isWhitespace }
                function = true
                return ("<mi mathvariant=\"normal\">\(DocumentHTML.escape(DocumentMath.textEscapes(name)))</mi>", false)
            case "mathrm", "mathsf", "mathtt":
                // Read as math (m^2 is m squared), its letters upright; a
                // plain word stays one name (\mathrm{kg}).
                let start = i
                let text = try rawArgument()
                if text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " }) {
                    let name = text.filter { !$0.isWhitespace }
                    return ("<mi mathvariant=\"normal\">\(DocumentHTML.escape(name))</mi>", false)
                }
                i = start
                let row = try argument()
                return (row.replacingOccurrences(of: "<mi>", with: "<mi mathvariant=\"normal\">"), false)
            case "mathbf", "boldsymbol", "bm", "mathit", "mathcal", "mathscr", "mathfrak":
                return (try argument(), false)
            case "mathbb":
                let text = try rawArgument().filter { !$0.isWhitespace }
                return ("<mi>\(DocumentHTML.escape(String(text.map { DocumentMath.doubleStruck($0) })))</mi>", false)
            case "begin":
                return (try environment(), false)
            case "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits", "nonumber", "notag":
                return ("", false)
            default:
                // Not ours: shown as written.
                return ("<mtext>\\\(DocumentHTML.escape(name))</mtext>", false)
            }
        }

        /// The delimiter after \left, \right or \big: a character or a
        /// command (\langle, \{), `.` for none.
        mutating func delimiter(stretchy: Bool) throws -> String {
            skipSpace()
            guard let c = peek() else { throw Failure() }
            var text: String
            if c == "." {
                i += 1
                return ""
            } else if c == "\\" {
                let name = readCommand()
                guard let d = DocumentMath.fences[name] ?? DocumentMath.operators[name] else { throw Failure() }
                text = d
            } else {
                i += 1
                text = String(Character(c))
            }
            text = DocumentHTML.escape(text)
            return stretchy ? "<mo>\(text)</mo>" : "<mo stretchy=\"false\">\(text)</mo>"
        }

        /// `\begin{matrix}` … `\end{matrix}`: rows by `\\`, cells by `&`,
        /// with the environment's brackets.
        mutating func environment() throws -> String {
            let name = try rawArgument().trimmingCharacters(in: .whitespaces)
            // An array's column spec isn't drawn.
            if name == "array" { _ = try rawArgument() }
            var rows: [[String]] = [[]]
            while true {
                let cell = try expression(until: ["&", "\\\\", "\\end"])
                rows[rows.count - 1].append(DocumentMath.mrow(cell))
                guard peek() != nil else { throw Failure() }
                if peek() == "&" { i += 1; continue }
                let command = readCommand()
                if command == "\\" { rows.append([]); continue }
                guard command == "end" else { throw Failure() }
                _ = try rawArgument()
                break
            }
            // A last `\\` leaves an empty row.
            if let last = rows.last, last.count == 1, last[0] == "<mrow></mrow>", rows.count > 1 { rows.removeLast() }
            guard rows.count <= 100, rows.allSatisfy({ $0.count <= 50 }) else { throw Failure() }
            let table = "<mtable>" + rows.map { "<mtr>" + $0.map { "<mtd>\($0)</mtd>" }.joined() + "</mtr>" }.joined() + "</mtable>"
            let fences: [String: (String, String)] = [
                "pmatrix": ("(", ")"), "bmatrix": ("[", "]"), "Bmatrix": ("{", "}"),
                "vmatrix": ("|", "|"), "Vmatrix": ("‖", "‖"), "cases": ("{", ""),
            ]
            guard let (open, close) = fences[name] else { return "<mrow>\(table)</mrow>" }
            return "<mrow><mo>\(open)</mo>\(table)" + (close.isEmpty ? "" : "<mo>\(close)</mo>") + "</mrow>"
        }
    }

    static func mrow(_ parts: [String]) -> String { "<mrow>" + parts.joined() + "</mrow>" }

    /// \text{…}'s escapes as the characters they stand for (5\% is 5%).
    static func textEscapes(_ text: String) -> String {
        var out = ""
        var escaped = false
        for ch in text {
            if escaped {
                if "%$&#_{} ".contains(ch) { out.append(ch) } else { out.append("\\"); out.append(ch) }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch == "~" ? "\u{00A0}" : ch)
            }
        }
        if escaped { out.append("\\") }
        return out
    }

    // MARK: - Tables

    static let spaces: [String: String] = [
        ",": "\u{2009}", ":": "\u{205F}", ">": "\u{205F}", ";": "\u{2004}", " ": "\u{00A0}", "!": "",
        "quad": "\u{2003}", "qquad": "\u{2003}\u{2003}", "enspace": "\u{2002}", "thinspace": "\u{2009}",
    ]

    /// Letters and symbols set as identifiers (italic Greek lower case).
    static let identifiers: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "omicron": "ο", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς",
        "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "ell": "ℓ", "hbar": "ℏ", "imath": "ı", "jmath": "ȷ", "wp": "℘",
    ]

    /// Upright identifiers: capital Greek, ∞, ∂ and the like.
    static let upright: [String: String] = [
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "infty": "∞", "partial": "∂", "nabla": "∇", "emptyset": "∅", "varnothing": "∅", "aleph": "ℵ",
        "Re": "ℜ", "Im": "ℑ", "degree": "°", "angle": "∠", "triangle": "△", "top": "⊤", "bot": "⊥",
        "$": "$", "%": "%", "#": "#", "&": "&", "_": "_",
    ]

    static let operators: [String: String] = [
        "cdot": "⋅", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆", "circ": "∘",
        "bullet": "∙", "oplus": "⊕", "ominus": "⊖", "otimes": "⊗", "odot": "⊙",
        "le": "≤", "leq": "≤", "leqslant": "⩽", "ge": "≥", "geq": "≥", "geqslant": "⩾", "ne": "≠", "neq": "≠",
        "lt": "<", "gt": ">", "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝",
        "ll": "≪", "gg": "≫", "doteq": "≐", "prec": "≺", "succ": "≻", "perp": "⊥", "parallel": "∥", "mid": "∣",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "leftrightarrow": "↔", "Leftrightarrow": "⇔", "iff": "⟺", "implies": "⟹", "impliedby": "⟸",
        "mapsto": "↦", "longrightarrow": "⟶", "longleftarrow": "⟵", "Longrightarrow": "⟹", "uparrow": "↑",
        "downarrow": "↓", "nearrow": "↗", "searrow": "↘",
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
        "subsetneq": "⊊", "cup": "∪", "cap": "∩", "setminus": "∖", "wedge": "∧", "land": "∧", "vee": "∨",
        "lor": "∨", "neg": "¬", "lnot": "¬", "forall": "∀", "exists": "∃", "nexists": "∄",
        "cdots": "⋯", "ldots": "…", "dots": "…", "dotsc": "…", "dotsb": "⋯", "vdots": "⋮", "ddots": "⋱",
        "backslash": "∖", "colon": ":", "prime": "′",
        "therefore": "∴", "because": "∵", "models": "⊨", "vdash": "⊢",
    ]

    /// Brackets, as written unless \left and \right stretch them.
    static let fences: [String: String] = [
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "vert": "|", "lvert": "|", "rvert": "|", "Vert": "‖", "lVert": "‖", "rVert": "‖", "|": "‖",
        "{": "{", "}": "}", "lbrace": "{", "rbrace": "}",
    ]

    /// Operators whose scripts are limits (under and over), and integrals,
    /// whose scripts stay scripts.
    static let bigOperators: [String: String] = [
        "sum": "∑", "prod": "∏", "coprod": "∐", "bigcup": "⋃", "bigcap": "⋂", "bigoplus": "⨁", "bigotimes": "⨂",
        "bigvee": "⋁", "bigwedge": "⋀", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "∑": "∑", "∏": "∏",
    ]
    static let integrals: Set<String> = ["int", "iint", "iiint", "oint"]

    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth",
        "log", "ln", "lg", "exp", "det", "dim", "gcd", "deg", "ker", "hom", "arg", "Pr",
        "lim", "liminf", "limsup", "max", "min", "sup", "inf", "argmax", "argmin",
    ]
    static let limitFunctions: Set<String> = ["lim", "liminf", "limsup", "max", "min", "sup", "inf", "argmax", "argmin", "det", "gcd", "Pr"]

    static let accents: [String: String] = [
        "hat": "ˆ", "widehat": "ˆ", "bar": "¯", "overline": "¯", "vec": "→", "overrightarrow": "→",
        "dot": "˙", "ddot": "¨", "tilde": "˜", "widetilde": "˜", "check": "ˇ", "breve": "˘", "acute": "´", "grave": "`",
    ]

    /// ℝ for R and the like.
    static func doubleStruck(_ c: Character) -> Character {
        let special: [Character: Character] = ["C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ"]
        if let s = special[c] { return s }
        guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else { return c }
        let base: UInt32
        switch v {
        case 0x41...0x5A: base = 0x1D538 + (v - 0x41)
        case 0x61...0x7A: base = 0x1D552 + (v - 0x61)
        case 0x30...0x39: base = 0x1D7D8 + (v - 0x30)
        default: return c
        }
        return Unicode.Scalar(base).map(Character.init) ?? c
    }
}
