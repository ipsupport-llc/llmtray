import Foundation

/// The license list About LLMTray shows: generated at build time
/// (scripts/generate_licenses.py -> Licenses.json in the app's Resources)
/// for what's bundled, plus what's installed on this Mac, read live.
public struct LicenseCatalog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        public var version: String?
        public var license: String
        public var url: String?
        public var text: String
        public var id: String { name + "@" + (version ?? "") }

        public init(name: String, version: String? = nil, license: String, url: String? = nil, text: String) {
            self.name = name
            self.version = version
            self.license = license
            self.url = url
            self.text = text
        }
    }

    public struct Group: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var entries: [Entry]

        public init(id: String, title: String, entries: [Entry]) {
            self.id = id
            self.title = title
            self.entries = entries
        }
    }

    public var groups: [Group]

    public init(groups: [Group]) { self.groups = groups }

    public static func load(_ url: URL) -> LicenseCatalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LicenseCatalog.self, from: data)
    }
}

/// Licenses of the Python packages installed in a venv, from their
/// .dist-info metadata -- no Python needed.
public enum PythonPackageLicenses {
    /// Name, Version and license of a METADATA file (RFC 822-style headers
    /// up to the first blank line).
    public static func parseMetadata(_ text: String) -> (name: String, version: String, license: String)? {
        var headers: [(String, String)] = []
        // "\r\n" is one Character: split on it only after normalizing.
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Folded continuation (an old Description: can have blank-looking
            // indented lines); only a truly empty line ends the headers.
            if line.first == " " || line.first == "\t" { continue }
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        func first(_ key: String) -> String? { headers.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1 }
        guard let name = first("Name"), let version = first("Version") else { return nil }
        let license: String
        if let expr = first("License-Expression"), !expr.isEmpty {
            license = expr
        } else {
            let classifiers = headers.filter { $0.0 == "Classifier" && $0.1.hasPrefix("License ::") }
                .compactMap { $0.1.components(separatedBy: "::").last?.trimmingCharacters(in: .whitespaces) }
            if !classifiers.isEmpty {
                license = classifiers.joined(separator: ", ")
            } else if let text = first("License"), !text.isEmpty {
                license = String(text.prefix(100))
            } else {
                license = "unknown"
            }
        }
        return (name, version, license)
    }

    /// Every package in `sitePackages`, sorted by name, with the license
    /// files its .dist-info ships.
    public static func scan(sitePackages: URL) -> [LicenseCatalog.Entry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: sitePackages, includingPropertiesForKeys: nil) else { return [] }
        let entries: [LicenseCatalog.Entry] = items.filter { $0.pathExtension == "dist-info" }.compactMap { dir -> LicenseCatalog.Entry? in
            guard let meta = try? String(contentsOf: dir.appendingPathComponent("METADATA"), encoding: .utf8),
                  let info = parseMetadata(meta) else { return nil }
            var files: [URL] = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { isLicenseFile($0.lastPathComponent) }
            if let licenses = fm.enumerator(at: dir.appendingPathComponent("licenses"), includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let url as URL in licenses where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    files.append(url)
                }
            }
            // License files a package ships inside itself (vendored code,
            // e.g. mlx's metal_cpp), from its RECORD.
            if let record = try? String(contentsOf: dir.appendingPathComponent("RECORD"), encoding: .utf8) {
                for line in record.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
                    let path = String(line.split(separator: ",", maxSplits: 1).first ?? "")
                    guard !path.contains(".dist-info/"), !path.hasPrefix(".."), isLicenseFile((path as NSString).lastPathComponent) else { continue }
                    files.append(sitePackages.appendingPathComponent(path))
                }
            }
            let texts = files.sorted { $0.path < $1.path }.compactMap { url -> String? in
                let shown = url.path.hasPrefix(sitePackages.path + "/") ? String(url.path.dropFirst(sitePackages.path.count + 1)) : url.lastPathComponent
                return (try? String(contentsOf: url, encoding: .utf8)).map { "--- \(shown) ---\n" + $0 }
            }
            return LicenseCatalog.Entry(
                name: info.name, version: info.version, license: info.license,
                url: "https://pypi.org/project/\(info.name)/",
                text: texts.isEmpty ? "No license file shipped; see https://pypi.org/project/\(info.name)/" : texts.joined(separator: "\n\n")
            )
        }
        return entries.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func isLicenseFile(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["LICENSE", "LICENCE", "COPYING", "NOTICE"].contains { upper.hasPrefix($0) }
            && !upper.hasSuffix(".PY") && !upper.hasSuffix(".PYC")
    }

    /// `<venv>/lib/python3.X/site-packages`, whichever Python it has.
    public static func sitePackages(venv: URL) -> URL? {
        let lib = venv.appendingPathComponent("lib")
        let python = (try? FileManager.default.contentsOfDirectory(atPath: lib.path))?.sorted().last { $0.hasPrefix("python") }
        return python.map { lib.appendingPathComponent($0).appendingPathComponent("site-packages") }
    }
}

/// A Hugging Face model card's license: the `license:` (or `license_name:`
/// for "other") field of its YAML front matter.
public enum ModelCardLicense {
    public static func parse(_ readme: String) -> String? {
        var text = readme.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            // Top-level keys only (an indented `license:` belongs to
            // something else); the first one wins.
            guard let first = line.first, first != " ", first != "\t", first != "-", first != "#",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            var value = String(line[line.index(after: colon)...])
            if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !value.isEmpty, fields[key] == nil { fields[key] = value }
        }
        if let name = fields["license_name"], fields["license"] == "other" || fields["license"] == nil { return name }
        return fields["license"]
    }
}
