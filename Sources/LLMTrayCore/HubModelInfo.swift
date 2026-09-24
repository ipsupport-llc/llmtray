import Foundation

/// What the Hugging Face model API says about a repo's license and access,
/// for the model browser (from /api/models/<id>).
public struct HubModelInfo: Equatable, Sendable {
    public enum Access: Equatable, Sendable {
        case open
        /// The license must be accepted on the model's page (automatically
        /// approved, or reviewed by its authors), and downloads need a token.
        case gated(manualApproval: Bool)
    }

    public var sizeBytes: Int64?
    /// The license's name: `license_name` when the card's `license` is
    /// "other", else the `license` id ("apache-2.0", "llama3.2").
    public var license: String?
    public var licenseLink: String?
    public var access: Access

    public init(sizeBytes: Int64? = nil, license: String? = nil, licenseLink: String? = nil, access: Access = .open) {
        self.sizeBytes = sizeBytes
        self.license = license
        self.licenseLink = licenseLink
        self.access = access
    }

    /// From the JSON of /api/models/<id>.
    public static func parse(_ data: Data) -> HubModelInfo? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], obj["id"] != nil else { return nil }
        let card = obj["cardData"] as? [String: Any] ?? [:]
        var license = card["license"] as? String
        if license == nil {
            // Not in the card's front matter: the "license:<id>" tag.
            license = (obj["tags"] as? [String])?.first { $0.hasPrefix("license:") }.map { String($0.dropFirst("license:".count)) }
        }
        if license == "other" || license == nil, let name = card["license_name"] as? String, !name.isEmpty {
            license = name
        }
        let access: Access
        switch obj["gated"] {
        case let flag as Bool: access = flag ? .gated(manualApproval: false) : .open
        case let mode as String: access = mode == "false" ? .open : .gated(manualApproval: mode == "manual")
        default: access = .open
        }
        return HubModelInfo(
            sizeBytes: (obj["usedStorage"] as? NSNumber)?.int64Value,
            license: license,
            licenseLink: card["license_link"] as? String,
            access: access
        )
    }

    /// Whether the license limits use to non-commercial / research use
    /// (CC BY-NC, "non-commercial" licenses): worth flagging before a
    /// download.
    public var isNonCommercial: Bool {
        guard let l = license?.lowercased() else { return false }
        let tokens = Set(l.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        // Known ids that don't say so in their name: Mistral's
        // non-production license, Apple's ML research license.
        let known: Set<String> = ["mnpl", "mnpl-0.1", "apple-amlr", "apple-ascl"]
        return tokens.contains("nc") || l.contains("non-commercial") || l.contains("noncommercial")
            || tokens.contains("research") || known.contains(l)
    }
}
