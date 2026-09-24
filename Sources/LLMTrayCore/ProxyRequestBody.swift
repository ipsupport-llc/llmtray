import Foundation

/// What the proxy lets through to mlx_lm.server in a request body. The
/// server loads whatever a body names -- "model", "draft_model", "adapters":
/// any path, or a Hugging Face repo, downloading it -- which would bypass
/// the app's model switch and the model's profile. So the proxy resolves
/// the model itself and the backend only ever sees the name of the model
/// it was started with.
public enum ProxyRequestBody {
    /// The model a request asks for; nil when it names none (absent, empty,
    /// or a "use whatever is loaded" name).
    public static func requestedModel(_ body: Data) -> String? {
        // The last "model" wins, as in Python's json (Foundation keeps the
        // first).
        guard object(body) != nil, let member = topLevelMembers(Array(body))?.last(where: { $0.key == "model" }),
              let name = requestedModelValue(body, member) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return ["", "default", "default_model"].contains(trimmed) ? nil : trimmed
    }

    /// Sampling fields; a null one fails the backend's validation, so it's
    /// dropped (its default applies).
    static let samplingKeys: Set<String> = ["temperature", "top_p", "top_k", "min_p", "max_tokens", "max_completion_tokens"]

    /// Keys the backend would load models or weights from.
    static let loadingKeys = ["draft_model", "adapters"]

    /// `body` with its model set to `backendModel` (the name the running
    /// server knows its own model by) and the loading keys removed; a body
    /// that isn't a JSON object is returned unchanged (the backend rejects
    /// it anyway). Every other member is copied byte for byte: parsing and
    /// re-serializing would turn a client's `0.0` into `0`, which mlx_lm
    /// refuses for its float-only parameters.
    ///
    /// `defaults` (key, JSON literal) are added where the body has no such
    /// key -- the profile's sampling; "max_tokens" also yields to a
    /// client's "max_completion_tokens".
    public static func rewrite(_ body: Data, backendModel: String, defaults: [(key: String, json: String)] = []) -> Data {
        guard object(body) != nil, let members = topLevelMembers(Array(body)) else { return body }
        // A null counts as absent, as it does for the server.
        let bytes = Array(body)
        let present = Set(members.filter { String(decoding: bytes[$0.valueRange], as: UTF8.self) != "null" }.map(\.key))
        let missing = defaults.filter { d in
            !present.contains(d.key) && !(d.key == "max_tokens" && present.contains("max_completion_tokens"))
        }
        // Already right: one model, the backend's, and no loading keys.
        let models = members.filter { $0.key == "model" }
        if models.count == 1, requestedModelValue(body, models[0]) == backendModel,
           !members.contains(where: { loadingKeys.contains($0.key) }), missing.isEmpty,
           !members.contains(where: { m in (samplingKeys.contains(m.key) || defaults.contains { $0.key == m.key }) && String(decoding: Array(body)[m.valueRange], as: UTF8.self) == "null" }) { return body }
        guard let name = try? JSONSerialization.data(withJSONObject: [backendModel], options: [.withoutEscapingSlashes]) else { return body }
        var out = Array("{\"model\":".utf8) + Array(name.dropFirst().dropLast())   // the string out of ["..."]
        // A null sampling field: the server would fail its validation --
        // dropped, so the default (filled in or the server's own) applies.
        let defaultKeys = samplingKeys.union(defaults.map(\.key))
        func isNull(_ m: Member) -> Bool { String(decoding: bytes[m.valueRange], as: UTF8.self) == "null" }
        for m in members where m.key != "model" && !loadingKeys.contains(m.key) && !(defaultKeys.contains(m.key) && isNull(m)) {
            out += Array(",".utf8) + bytes[m.range]
        }
        for d in missing {
            out += Array(",\"\(d.key)\":\(d.json)".utf8)
        }
        out += Array("}".utf8)
        return Data(out)
    }

    struct Member {
        let key: String
        let range: Range<Int>        // from the key's opening quote to the value's end
        let valueRange: Range<Int>
    }

    private static func requestedModelValue(_ body: Data, _ m: Member) -> String? {
        (try? JSONSerialization.jsonObject(with: Data("[".utf8) + Data(Array(body)[m.valueRange]) + Data("]".utf8)) as? [Any])?.first as? String
    }

    /// The members of a top-level JSON object, as byte ranges. Only called
    /// on a body JSONSerialization already accepted as an object, so it
    /// just has to find boundaries: strings (with escapes) and nesting.
    static func topLevelMembers(_ b: [UInt8]) -> [Member]? {
        var i = 0
        func skipSpace() { while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 } }
        func skipString() -> Bool {   // at the opening quote
            i += 1
            while i < b.count {
                if b[i] == 0x5C { i += 2; continue }
                if b[i] == 0x22 { i += 1; return true }
                i += 1
            }
            return false
        }
        func skipValue() -> Bool {
            if i < b.count, b[i] == 0x22 { return skipString() }
            var depth = 0
            while i < b.count {
                switch b[i] {
                case 0x22: if !skipString() { return false }; continue
                case 0x7B, 0x5B: depth += 1
                case 0x7D, 0x5D:
                    if depth == 0 { return true }
                    depth -= 1
                    if depth == 0 { i += 1; return true }
                case 0x2C: if depth == 0 { return true }
                default: break
                }
                i += 1
            }
            return depth == 0
        }
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }   // a UTF-8 BOM, which Foundation accepts
        skipSpace()
        guard i < b.count, b[i] == 0x7B else { return nil }
        i += 1
        var members: [Member] = []
        while true {
            skipSpace()
            guard i < b.count else { return nil }
            if b[i] == 0x7D { return members }
            if b[i] == 0x2C { i += 1; continue }
            guard b[i] == 0x22 else { return nil }
            let start = i
            guard skipString() else { return nil }
            let keyBytes = Data(b[start..<i])
            guard let key = (try? JSONSerialization.jsonObject(with: Data("[".utf8) + keyBytes + Data("]".utf8)) as? [String])?.first else { return nil }
            skipSpace()
            guard i < b.count, b[i] == 0x3A else { return nil }
            i += 1
            skipSpace()
            let valueStart = i
            guard skipValue() else { return nil }
            var end = i
            while end > start, [0x20, 0x09, 0x0A, 0x0D].contains(b[end - 1]) { end -= 1 }
            members.append(Member(key: key, range: start..<end, valueRange: valueStart..<end))
        }
    }

    private static func object(_ body: Data) -> [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}
