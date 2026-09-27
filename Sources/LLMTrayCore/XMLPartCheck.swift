import Foundation

/// What an XML part of an Office container must pass before an importer
/// sees it. The system parser already refuses entity expansion and never
/// fetches external entities, but a DOCTYPE is the only door to both: OOXML
/// parts never carry one, so any is refused there, in any of the encodings
/// XML allows. ODF writers (Apple's among them) do put a bare external
/// DOCTYPE on META-INF/manifest.xml, so `allowExternalDoctype` lets one
/// without an internal subset through -- no entity can be declared without
/// one, and none is fetched. Nesting is capped (the parser went 200,000
/// levels deep without complaint).
public enum XMLPartCheck {
    public static func check(_ data: Data, part: String, maxDepth: Int, allowExternalDoctype: Bool = false) throws {
        switch doctype(data) {
        case .internalSubset?:
            throw ExtractionError.unreadable("xml: \(part) has a DOCTYPE")
        case .external? where !allowExternalDoctype:
            throw ExtractionError.unreadable("xml: \(part) has a DOCTYPE")
        default:
            break
        }
        let walker = DepthWalker(maxDepth: maxDepth)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = walker
        let ok = parser.parse()
        if walker.tooDeep { throw ExtractionError.tooLarge(.xmlDepth) }
        if let refused = walker.refused { throw ExtractionError.unreadable("xml: \(part) declares \(refused)") }
        if !ok { throw ExtractionError.unreadable("xml: \(part) is not well-formed") }
    }

    enum Doctype { case external, internalSubset }

    /// "<!DOCTYPE" anywhere, any case, in UTF-8 or UTF-16 -- a DOCTYPE must
    /// precede the root, but a long prologue can push it past any prefix, so
    /// the whole part is searched ("<!" can't occur in text unescaped; one in
    /// a comment or CDATA counts too, which costs nothing real). A "[" before
    /// its ">" is an internal subset; so is any in UTF-16, not worth telling apart.
    static func doctype(_ data: Data) -> Doctype? {
        let needle = Array("<!doctype".utf8)
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Doctype? in
            let b = raw.bindMemory(to: UInt8.self)
            // step 1: UTF-8 (or any ASCII superset). step 2: UTF-16, the
            // character at even offsets (LE) or odd ones (BE), its other byte 0.
            func matches(at i: Int, step: Int) -> Bool {
                guard i + needle.count * step <= b.count else { return false }
                for k in 0..<needle.count {
                    let at = i + k * step
                    let c = b[at]
                    if (c >= 0x41 && c <= 0x5A ? c + 32 : c) != needle[k] { return false }
                    if step == 2 && b[at ^ 1] != 0 { return false }
                }
                return true
            }
            var found: Doctype?
            for i in 0..<b.count where b[i] == 0x3C && matches(at: i, step: 1) {
                var j = i + needle.count
                while j < b.count, b[j] != 0x3E, b[j] != 0x5B { j += 1 }
                if j >= b.count || b[j] == 0x5B { return .internalSubset }
                found = .external
            }
            if found == nil, b.contains(0) {   // no NUL: not UTF-16
                for i in 0..<b.count where b[i] == 0x3C && matches(at: i, step: 2) { return .internalSubset }
            }
            return found
        }
    }

    private final class DepthWalker: NSObject, XMLParserDelegate {
        let maxDepth: Int
        var depth = 0
        var tooDeep = false
        var refused: String?

        init(maxDepth: Int) { self.maxDepth = maxDepth }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            depth += 1
            if depth > maxDepth { tooDeep = true; parser.abortParsing() }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            depth -= 1
        }

        // Belt and braces: none of these can happen without a DOCTYPE.
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            refused = "an entity"; parser.abortParsing()
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            refused = "an external entity"; parser.abortParsing()
        }
    }
}
