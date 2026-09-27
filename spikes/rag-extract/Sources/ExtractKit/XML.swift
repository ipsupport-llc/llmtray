import Foundation

/// SAX walking for OOXML parts, hardened:
/// - any DOCTYPE is refused before parsing (OOXML parts never have one; it is
///   the only door to entity expansion -- billion laughs -- and external
///   entities);
/// - external entities off; depth capped (the walker aborts past it).
public final class XMLWalk: NSObject, XMLParserDelegate {
    public var onStart: (String, [String: String]) -> Void = { _, _ in }
    public var onEnd: (String) -> Void = { _ in }
    public var onText: (String) -> Void = { _ in }
    private let maxDepth: Int
    private var depth = 0
    private(set) var failure: String?
    private weak var parser: XMLParser?

    init(maxDepth: Int) { self.maxDepth = maxDepth }

    public static func hasDoctype(_ data: Data) -> Bool {
        // A DTD must precede the root element, so the first 64 KB is enough;
        // "<!" can't occur unescaped in text, so there are no false positives.
        // (UTF-16 parts would need a second probe; OOXML writers use UTF-8.)
        let head = data.prefix(64 * 1024)
        return head.range(of: Data("<!DOCTYPE".utf8)) != nil || head.range(of: Data("<!doctype".utf8)) != nil
    }

    /// Parses `data`, calling the closures with local names (namespaces processed).
    public static func walk(_ data: Data, part: String, limits: Limits, configure: (XMLWalk) -> Void) throws {
        if hasDoctype(data) { throw ExtractError("xml: \(part) has a DOCTYPE (refused: entity expansion / external entities)") }
        let w = XMLWalk(maxDepth: limits.maxXMLDepth)
        configure(w)
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = true
        p.shouldResolveExternalEntities = false
        p.delegate = w
        w.parser = p
        let ok = p.parse()
        if let f = w.failure { throw ExtractError("xml: \(part): \(f)") }
        if !ok { throw ExtractError("xml: \(part): \(p.parserError?.localizedDescription ?? "parse error")") }
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        depth += 1
        if depth > maxDepth { failure = "nesting deeper than \(maxDepth)"; parser.abortParsing(); return }
        onStart(name, attributes)
    }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
        onEnd(name)
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { onText(string) }

    public func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        failure = "entity declaration"; parser.abortParsing()
    }
}

/// OOXML relationships: rId -> resolved part name.
enum Rels {
    static func load(_ zip: ZipArchive, for part: String, limits: Limits) -> [String: (target: String, type: String, external: Bool)] {
        let dir = (part as NSString).deletingLastPathComponent
        let file = (part as NSString).lastPathComponent
        let relsName = (dir.isEmpty ? "" : dir + "/") + "_rels/" + file + ".rels"
        guard let data = try? zip.read(relsName) else { return [:] }
        var out: [String: (String, String, Bool)] = [:]
        try? XMLWalk.walk(data, part: relsName, limits: limits) { w in
            w.onStart = { name, a in
                guard name == "Relationship", let id = a["Id"], let t = a["Target"] else { return }
                let ext = a["TargetMode"] == "External"
                out[id] = (ext ? t : resolve(t, base: dir), a["Type"] ?? "", ext)
            }
        }
        return out
    }

    static func resolve(_ target: String, base: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for c in target.split(separator: "/") {
            if c == ".." { if !parts.isEmpty { parts.removeLast() } } else if c != "." { parts.append(String(c)) }
        }
        return parts.joined(separator: "/")
    }
}
