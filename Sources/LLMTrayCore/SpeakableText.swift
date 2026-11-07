import Foundation
import NaturalLanguage

/// An answer's Markdown as it should be read aloud (adr/0016, spoken
/// answers): code blocks become a short phrase, tables their cells, links
/// their text; formatting marks, bare URLs, images, HTML tags and citation
/// markers go. Line breaks between blocks are kept, so a heading or a list
/// item ends a sentence.
public enum SpeakableText {
    public static func plain(fromMarkdown markdown: String, codeBlock: String) -> String {
        var out: [String] = []
        var inFence = false
        var fenceMarker = ""
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let marker = fence(line) {
                if !inFence {
                    inFence = true
                    fenceMarker = marker
                    out.append(codeBlock)
                } else if line.hasPrefix(fenceMarker) {
                    inFence = false
                }
                continue
            }
            if inFence { continue }
            out.append(speakableLine(line))
        }
        return out.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "```" or "~~~" (with an info string) opens or closes a fence.
    static func fence(_ line: String) -> String? {
        for marker in ["```", "~~~"] where line.hasPrefix(marker) { return marker }
        return nil
    }

    static func speakableLine(_ line: String) -> String {
        var s = line
        // A table's separator row goes; a row reads as its cells.
        if s.hasPrefix("|") || s.hasSuffix("|") {
            if s.range(of: #"^\|?[\s:\-|]+\|?$"#, options: .regularExpression) != nil { return "" }
            let cells = s.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            s = cells.joined(separator: ", ")
        }
        let rules: [(String, String)] = [
            (#"<[^>\n]+>"#, ""),                                    // HTML tags
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),                          // images
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),                       // links: their text
            (#"https?://\S+"#, ""),                                  // bare URLs
            (#"\[\^?\d+\]|【[^】]*】"#, ""),                          // citation markers
            (#"^#{1,6}\s+"#, ""),                                    // headings
            (#"^>\s?"#, ""),                                         // quotes
            (#"^(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#, ""),        // list markers, task boxes
            (#"^(?:[-*_]\s*){3,}$"#, ""),                            // rules
            (#"`([^`]*)`"#, "$1"),                                   // inline code: its text
            (#"(\*\*|__)(.+?)\1"#, "$2"),                            // bold
            (#"(?<![\w*])[*_](?!\s)(.+?)(?<!\s)[*_](?![\w*])"#, "$1"), // italic
            (#"~~(.+?)~~"#, "$1"),                                   // strikethrough
            (#"\s{2,}"#, " "),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// Cuts an answer into sentences while it streams: `feed` takes each
/// delta and returns the sentences it completed, `finish` the rest. Text
/// inside an unfinished code fence is held until the fence closes (it's
/// spoken as one phrase). A sentence longer than `maxLength` is cut at a
/// comma or a space, so one request to the voice stays short.
public struct SentenceStream: Sendable {
    public let codeBlock: String
    public let maxLength: Int
    /// Voice conversation (adr/0031): the answer's first piece goes at its
    /// first comma (after `eagerMinimum` characters), so the voice starts
    /// sooner; later ones wait for whole sentences.
    public let eagerFirst: Bool
    public static let eagerMinimum = 24
    private var pending = ""
    private var emitted = false

    public init(codeBlock: String, maxLength: Int = 300, eagerFirst: Bool = false) {
        self.codeBlock = codeBlock
        self.maxLength = maxLength
        self.eagerFirst = eagerFirst
    }

    public mutating func feed(_ delta: String) -> [String] {
        pending += delta
        if eagerFirst, !emitted, Self.safeCut(in: pending) == nil, let comma = Self.firstComma(in: pending) {
            let head = String(pending[..<comma]).trimmingCharacters(in: .whitespaces)
            pending = String(pending[comma...])
            let out = sentences(head)
            emitted = !out.isEmpty
            return out
        }
        guard let cut = Self.safeCut(in: pending) else { return [] }
        let ready = String(pending[..<cut])
        pending = String(pending[cut...])
        let out = sentences(ready)
        if !out.isEmpty { emitted = true }
        return out
    }

    /// After the first ", " past `eagerMinimum` characters, outside code.
    static func firstComma(in text: String) -> String.Index? {
        guard !text.contains("`"), text.count > eagerMinimum else { return nil }
        var i = text.index(text.startIndex, offsetBy: eagerMinimum)
        while i < text.endIndex {
            let next = text.index(after: i)
            if text[i] == ",", next < text.endIndex, text[next] == " " { return next }
            i = next
        }
        return nil
    }

    public mutating func finish() -> [String] {
        defer { pending = "" }
        return sentences(pending)
    }

    /// Where the text can be cut now: after the last sentence end or block
    /// break that isn't inside an open code fence.
    static func safeCut(in text: String) -> String.Index? {
        // An open fence: only before it.
        var open: String.Index?
        var searchFrom = text.startIndex
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            if lineEnd == text.endIndex && !text.hasSuffix("\n") {
                // The last line may still be growing into a fence.
                if line.hasPrefix("`") || line.hasPrefix("~") { open = open ?? lineStart }
                break
            }
            if SpeakableText.fence(line) != nil {
                if open == nil { open = lineStart } else { open = nil; searchFrom = text.index(after: lineEnd) }
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        let limit = open ?? text.endIndex
        guard searchFrom <= limit else { return nil }
        let region = text[..<limit]
        // The last sentence end followed by whitespace, or a newline.
        var best: String.Index?
        var i = region.startIndex
        while i < region.endIndex {
            let c = region[i]
            let next = region.index(after: i)
            if c == "\n" {
                best = next
            } else if ".!?…".contains(c), next < region.endIndex, region[next].isWhitespace {
                best = next
            }
            i = next
        }
        if let open, best == nil, open > text.startIndex { return open }
        return best
    }

    private func sentences(_ markdown: String) -> [String] {
        let plain = SpeakableText.plain(fromMarkdown: markdown, codeBlock: codeBlock)
        guard !plain.isEmpty else { return [] }
        var out: [String] = []
        for paragraph in plain.components(separatedBy: "\n") where !paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = paragraph
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
                let s = paragraph[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isSpeakable(s) { out += Self.split(s, maxLength: maxLength) }
                return true
            }
        }
        return out
    }

    /// Has a letter or a digit: punctuation alone isn't read.
    static func isSpeakable(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// Cuts a long sentence at the last comma, semicolon or colon before the
    /// limit, else the last space; words are never split.
    static func split(_ sentence: String, maxLength: Int) -> [String] {
        var rest = Substring(sentence)
        var out: [String] = []
        while rest.count > maxLength {
            let window = rest.prefix(maxLength)
            let cut = window.lastIndex(where: { ",;:".contains($0) }).map { rest.index(after: $0) }
                ?? window.lastIndex(of: " ")
                ?? window.endIndex
            let head = rest[..<cut].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { out.append(head) }
            rest = rest[cut...].drop(while: { $0 == " " })
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }
}

/// The language of a sentence to speak, as Chatterbox's language codes
/// (adr/0016). A short sentence is guessed poorly, so the whole answer's
/// language is the fallback.
public enum SpeechLanguage {
    /// Chatterbox Multilingual's 23 languages.
    public static let chatterbox: [String] = ["ar", "da", "de", "el", "en", "es", "fi", "fr", "he", "hi", "it", "ja",
                                              "ko", "ms", "nl", "no", "pl", "pt", "ru", "sv", "sw", "tr", "zh"]

    /// The code for an NLLanguage ("zh-Hans" -> "zh", "nb" -> "no"); nil
    /// when undetermined.
    public static func code(_ language: NLLanguage) -> String? {
        switch language {
        case .undetermined: return nil
        case .simplifiedChinese, .traditionalChinese: return "zh"
        case .norwegian: return "no"
        default:
            let raw = language.rawValue
            return String(raw.prefix { $0 != "-" && $0 != "_" })
        }
    }

    /// The most likely language of `text`, given that `fallback` is the
    /// answer's; a guess below `confidence` gives the fallback.
    public static func detect(_ text: String, fallback: String?, confidence: Double = 0.7) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let (lang, p) = recognizer.languageHypotheses(withMaximum: 1).first, p >= confidence, let c = code(lang) {
            return c
        }
        return fallback ?? recognizer.dominantLanguage.flatMap(code)
    }
}
