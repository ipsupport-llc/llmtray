import Foundation

/// A server the user added (adr/0027): how to reach it, whether it's on,
/// and what they reviewed and allowed. Secrets aren't here: their names
/// are, the values live in the Keychain.
public struct MCPServerConfig: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case command, url }

    public var id: UUID
    public var name: String
    /// The `<server>` in tool names: made once, never changed by a rename.
    public var key: String
    public var kind: Kind
    /// command: the absolute path (a bare name was looked up when added).
    public var command: String = ""
    public var arguments: [String] = []
    /// Plain variables; secret ones are named in `secretNames` and kept in
    /// the Keychain.
    public var environment: [String: String] = [:]
    public var workingDirectory: String?
    public var url: String = ""
    /// Plain headers; secret ones as above.
    public var headers: [String: String] = [:]
    public var secretNames: [String] = []
    public var enabled = false
    /// Where it came from, for the list: "Added by hand", a bundle's folder,
    /// a registry name.
    public var origin: String?
    public var description: String?
    /// The installed version (a bundle's manifest, a registry entry's).
    public var version: String?
    /// Where an update comes from; nil: added by hand, never updated.
    public var source: MCPSource?
    /// A bundle's settings as given (not the secret ones): kept for updates.
    public var answers: [String: String] = [:]
    /// Its icon: an https URL, or a file in its bundle folder.
    public var icon: String?
    /// Tool name → the definition hash the user reviewed. A tool missing
    /// here, or with another hash now, is hidden until reviewed again.
    public var reviewed: [String: String] = [:]
    /// Tool name → whether the server said it only reads when the user
    /// reviewed it: a hint changed since (a write relisted as a read) isn't
    /// trusted after outside text (adr/0027).
    public var reviewedReadOnly: [String: Bool] = [:]
    /// Approval keys (`MCPApproval.key`) that run without asking, each bound
    /// to the hash it was given for.
    public var runWithoutAsking: [String: String] = [:]
    /// The tools as last listed: declared from here without starting the
    /// server; refreshed whenever it starts.
    public var tools: [MCP.Tool] = []
    /// Tool name → the name the model sees: given once, kept.
    public var modelNames: [String: String] = [:]
    public var added = Date()

    /// The tools the model may see: those whose definition is the one the
    /// user reviewed.
    public var visibleTools: [MCP.Tool] { tools.filter { reviewed[$0.name] == $0.definitionHash } }
    /// Tools new or changed since the review.
    public var unreviewedTools: [MCP.Tool] { tools.filter { reviewed[$0.name] != $0.definitionHash } }

    public init(id: UUID = UUID(), name: String, key: String, kind: Kind) {
        self.id = id
        self.name = name
        self.key = key
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case id, name, key, kind, command, arguments, environment, workingDirectory, url, headers, secretNames, enabled,
             origin, description, version, source, answers, icon, reviewed, reviewedReadOnly, runWithoutAsking, tools, modelNames, added
    }

    /// Fields added later read as their defaults: an older file still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        key = try c.decode(String.self, forKey: .key)
        kind = try c.decode(Kind.self, forKey: .kind)
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        secretNames = try c.decodeIfPresent([String].self, forKey: .secretNames) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        source = try c.decodeIfPresent(MCPSource.self, forKey: .source)
        answers = try c.decodeIfPresent([String: String].self, forKey: .answers) ?? [:]
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        reviewed = try c.decodeIfPresent([String: String].self, forKey: .reviewed) ?? [:]
        reviewedReadOnly = try c.decodeIfPresent([String: Bool].self, forKey: .reviewedReadOnly) ?? [:]
        runWithoutAsking = try c.decodeIfPresent([String: String].self, forKey: .runWithoutAsking) ?? [:]
        tools = try c.decodeIfPresent([MCP.Tool].self, forKey: .tools) ?? []
        modelNames = try c.decodeIfPresent([String: String].self, forKey: .modelNames) ?? [:]
        added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date()
    }

    /// Variable or header names whose values default to secret.
    public static func looksSecret(_ name: String) -> Bool {
        let n = name.uppercased()
        return ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "AUTH", "COOKIE", "CREDENTIAL"].contains { n.contains($0) }
    }
}

/// What an approval is for: one tool, or one value of its action field.
public enum MCPApproval {
    public static func key(tool: String, action: String?) -> String {
        action.map { "\(tool)#\($0)" } ?? tool
    }

    /// The action a call is for: the value of the tool's action field in
    /// its arguments (nil: the tool has none, or the call didn't give one).
    public static func action(of tool: MCP.Tool, arguments: [String: Any]) -> String? {
        guard let field = tool.actionField, let value = arguments[field.name] as? String else { return nil }
        return value
    }

    /// Whether a call may run without the card: the user let this tool (or
    /// this action of it) run without asking, for the definition they saw.
    /// A tool with actions is never allowed whole: only per action.
    public static func runsWithoutAsking(_ tool: MCP.Tool, arguments: [String: Any], config: MCPServerConfig) -> Bool {
        let hash = tool.definitionHash
        guard config.reviewed[tool.name] == hash else { return false }
        if tool.actionField != nil {
            guard let action = action(of: tool, arguments: arguments) else { return false }
            return config.runWithoutAsking[key(tool: tool.name, action: action)] == hash
        }
        return config.runWithoutAsking[key(tool: tool.name, action: nil)] == hash
    }
}

/// The names the model sees (adr/0027): `<server>_<tool>` within MCP's
/// `[A-Za-z0-9_-]{1,64}`, unique among every tool the chat has, with the
/// exact way back.
public enum MCPNames {
    /// A server's key from its name: ASCII letters and digits, lowercase,
    /// words joined by `_`, at most 20; `server1`… when nothing is left or
    /// it's taken.
    public static func serverKey(for name: String, taken: Set<String>) -> String {
        var words: [String] = []
        var word = ""
        for scalar in name.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) { word.unicodeScalars.append(scalar) }
            else if !word.isEmpty { words.append(word); word = "" }
        }
        if !word.isEmpty { words.append(word) }
        var key = String(words.joined(separator: "_").prefix(20)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if key.first?.isNumber == true { key = "s" + key }
        if !key.isEmpty, !taken.contains(key) { return key }
        let base = key.isEmpty ? "server" : String(key.prefix(17))
        var n = key.isEmpty ? 1 : 2
        while taken.contains("\(base)\(n)") { n += 1 }
        return "\(base)\(n)"
    }

    /// One tool's name for the model: the key and the tool's own name with
    /// anything outside the allowed set made `_`, cut to 64; a number added
    /// (`_2`, `_3`…) while the name is in `taken`.
    public static func toolName(server key: String, tool: String, taken: Set<String>) -> String {
        let cleaned = String(tool.unicodeScalars.map { s -> Character in
            (s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "_" || s == "-")) ? Character(s) : "_"
        })
        let base = String("\(key)_\(cleaned)".prefix(64))
        if !taken.contains(base) { return base }
        var n = 2
        while true {
            let suffix = "_\(n)"
            let candidate = String(base.prefix(64 - suffix.count)) + suffix
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }
}

// MARK: - Import

public enum MCPImport {
    public enum Failure: Error, Equatable, LocalizedError {
        case notAConfig
        case notABundle(String)
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .notAConfig: return "That isn't an MCP server config: it needs \"mcpServers\" with a command or a URL for each server."
            case .notABundle(let why): return "That isn't an MCP bundle LLMTray can install: \(why)"
            case .unsupported(let what): return "This bundle needs \(what), which LLMTray doesn't fill in."
            }
        }
    }

    /// A server as found in a pasted config or a bundle, before the user
    /// confirms it.
    public struct Found: Equatable, Sendable {
        public var name: String
        public var kind: MCPServerConfig.Kind
        public var command = ""
        public var arguments: [String] = []
        public var environment: [String: String] = [:]
        public var url = ""
        public var headers: [String: String] = [:]
        public var description: String?
        public var version: String?
        /// A bundle's icon file, or an https icon.
        public var icon: String?
        public var workingDirectory: String?
        /// A bundle's settings to ask the user for (`user_config`).
        public var asks: [Ask] = []

        public init(name: String, kind: MCPServerConfig.Kind) {
            self.name = name
            self.kind = kind
        }
    }

    /// One `user_config` entry of a bundle.
    public struct Ask: Equatable, Sendable {
        public enum Kind: String, Sendable { case string, number, boolean, directory, file }
        public var key: String
        public var title: String
        public var sensitive: Bool
        public var required: Bool
        /// As text: "true" / "false" for a boolean, a path for a folder.
        public var defaultValue: String?
        public var kind: Kind = .string
        public var help: String?

        public init(key: String, title: String, sensitive: Bool, required: Bool, defaultValue: String?,
                    kind: Kind = .string, help: String? = nil) {
            self.key = key
            self.title = title
            self.sensitive = sensitive
            self.required = required
            self.defaultValue = defaultValue
            self.kind = kind
            self.help = help
        }
    }

    /// A manifest value as the text a placeholder becomes: true/false, a
    /// whole number without ".0".
    static func text(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.doubleValue == n.doubleValue.rounded() ? String(n.int64Value) : n.stringValue
        }
        return "\(value)"
    }

    /// The common `{"mcpServers": {name: {command, args, env} | {url, headers}}}`
    /// shape servers' READMEs give; also a bare `{name: {...}}` map, or one
    /// server object with a name around it missing.
    public static func parseConfig(_ text: String) throws -> [Found] {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A README fragment: `"name": {...}` without the outer braces.
        if trimmed.hasPrefix("\"") { trimmed = "{" + trimmed + "}" }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else { throw Failure.notAConfig }
        let servers: [String: Any]
        if let s = object["mcpServers"] as? [String: Any] { servers = s }
        else if let s = object["servers"] as? [String: Any] { servers = s }
        else if object["command"] != nil || object["url"] != nil { servers = ["server": object] }
        else { servers = object }
        let found = servers.sorted { $0.key < $1.key }.compactMap { name, value -> Found? in
            guard let s = value as? [String: Any] else { return nil }
            if let command = s["command"] as? String, !command.isEmpty {
                var f = Found(name: name, kind: .command)
                f.command = command
                f.arguments = (s["args"] as? [Any] ?? []).map { "\($0)" }
                f.environment = (s["env"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
                f.workingDirectory = s["cwd"] as? String
                return f
            }
            if let url = (s["url"] as? String) ?? (s["serverUrl"] as? String), ["http", "https"].contains(URL(string: url)?.scheme?.lowercased() ?? "") {
                var f = Found(name: name, kind: .url)
                f.url = url
                f.headers = (s["headers"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
                return f
            }
            return nil
        }
        guard !found.isEmpty else { throw Failure.notAConfig }
        return found
    }

    /// A bundle's `manifest.json` (unpacked in `folder`): the server's
    /// command with `${__dirname}`, `${HOME}` and `${user_config.<key>}`
    /// left for `fill`; anything else it needs is refused.
    public static func parseManifest(_ data: Data, folder: String) throws -> Found {
        guard let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.notABundle("its manifest.json can't be read") }
        guard let server = m["server"] as? [String: Any], let config = server["mcp_config"] as? [String: Any],
              let command = config["command"] as? String, !command.isEmpty else {
            throw Failure.notABundle("its manifest names no command")
        }
        if let platforms = (m["compatibility"] as? [String: Any])?["platforms"] as? [String], !platforms.isEmpty,
           !platforms.contains("darwin") {
            throw Failure.notABundle("it isn't made for macOS")
        }
        var f = Found(name: (m["display_name"] as? String) ?? (m["name"] as? String) ?? "Server", kind: .command)
        f.command = command
        f.arguments = (config["args"] as? [Any] ?? []).map { "\($0)" }
        f.environment = (config["env"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
        f.description = m["description"] as? String
        f.version = m["version"] as? String
        if let icon = m["icon"] as? String, !icon.contains(".."), !icon.hasPrefix("/") { f.icon = (folder as NSString).appendingPathComponent(icon) }
        f.workingDirectory = folder
        for (key, value) in (m["user_config"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let v = value as? [String: Any] ?? [:]
            f.asks.append(Ask(key: key, title: (v["title"] as? String) ?? key, sensitive: v["sensitive"] as? Bool ?? false,
                              required: v["required"] as? Bool ?? false, defaultValue: text(v["default"]),
                              kind: Ask.Kind(rawValue: v["type"] as? String ?? "") ?? .string, help: v["description"] as? String))
        }
        // Every placeholder must be one we fill.
        for text in [f.command] + f.arguments + Array(f.environment.values) {
            for name in placeholders(in: text) where !(name == "__dirname" || name == "HOME" || name.hasPrefix("user_config.")) {
                throw Failure.unsupported("${\(name)}")
            }
            for name in placeholders(in: text) where name.hasPrefix("user_config.") {
                let key = String(name.dropFirst("user_config.".count))
                if !f.asks.contains(where: { $0.key == key }) { throw Failure.unsupported("${\(name)}") }
            }
        }
        return f
    }

    /// `${...}` names in `text`.
    static func placeholders(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let start = rest.range(of: "${"), let end = rest[start.upperBound...].firstIndex(of: "}") {
            out.append(String(rest[start.upperBound..<end]))
            rest = rest[rest.index(after: end)...]
        }
        return out
    }

    /// The placeholders filled: the bundle's folder, the home folder, the
    /// user's answers.
    public static func fill(_ text: String, folder: String, home: String, answers: [String: String]) -> String {
        var out = text
        // Answers first (a default can say ${HOME}), then the paths.
        for (key, value) in answers { out = out.replacingOccurrences(of: "${user_config.\(key)}", with: value) }
        return out.replacingOccurrences(of: "${__dirname}", with: folder).replacingOccurrences(of: "${HOME}", with: home)
    }

    /// Unpacks a bundle (a zip) into `destination`, a new folder: entries
    /// whose path leaves it, links, and more than `maxBytes` unpacked are
    /// refused, before and after unpacking.
    public static func unpackBundle(_ archive: URL, into destination: URL, maxBytes: Int64 = 200 << 20) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw Failure.notABundle("the folder for it exists already") }
        // The listing first: names and sizes, refused before anything is written.
        let listing = try run("/usr/bin/zipinfo", ["-l", archive.path])
        var total: Int64 = 0
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            // Entry lines only (perms, version, os, size, …, date, time, name);
            // the header and the totals line have fewer fields.
            guard fields.count >= 10, fields[7].contains("-"), fields[8].contains(":"), let mode = fields.first else { continue }
            if mode.hasPrefix("l") { throw Failure.notABundle("it holds a link") }
            if let size = Int64(fields[3]) { total += size }
            let name = fields[9...].joined(separator: " ")
            if name.hasPrefix("/") || name.split(separator: "/").contains("..") { throw Failure.notABundle("a file in it points outside it") }
        }
        guard total <= maxBytes else { throw Failure.notABundle("it unpacks to more than \(maxBytes >> 20) MB") }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, destination.path])
            // And after: what's really there.
            var bytes: Int64 = 0
            let root = destination.resolvingSymlinksInPath().path
            let walker = fm.enumerator(at: destination, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey], options: [])
            while let item = walker?.nextObject() as? URL {
                let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                if values.isSymbolicLink == true { throw Failure.notABundle("it holds a link") }
                guard item.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw Failure.notABundle("a file in it points outside it") }
                bytes += Int64(values.fileSize ?? 0)
            }
            guard bytes <= maxBytes else { throw Failure.notABundle("it unpacks to more than \(maxBytes >> 20) MB") }
            guard fm.fileExists(atPath: destination.appendingPathComponent("manifest.json").path) else {
                throw Failure.notABundle("there's no manifest.json in it")
            }
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure.notABundle("it can't be unpacked") }
        return String(decoding: data, as: UTF8.self)
    }

    /// A bare command (`npx`) as an absolute path, looked up through the
    /// user's login shell -- the app's own PATH has no Homebrew or nvm.
    /// nil: not found.
    public static func resolveCommand(_ command: String, shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") -> String? {
        if command.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
        guard command.allSatisfy({ $0.isLetter || $0.isNumber || "._-+".contains($0) }) else { return nil }
        guard let found = try? run(shell, ["-l", "-c", "command -v -- \(command)"]) else { return nil }
        let path = found.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}

/// A line under an answer for each MCP call (adr/0027): saved with the
/// message, since saved chats keep no tool calls.
public struct MCPCallRecord: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case done, failed, unknown, denied
        /// Not sent: the server wasn't there, or the tool changed.
        case notSent
    }

    public var server: String
    public var tool: String
    public var action: String?
    /// The arguments as approved (JSON, at most 2,000 characters).
    public var arguments: String
    public var outcome: Outcome
    public var date: Date

    public init(server: String, tool: String, action: String?, arguments: [String: Any], outcome: Outcome, date: Date = Date()) {
        self.server = server
        self.tool = tool
        self.action = action
        let data = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let text = String(decoding: data, as: UTF8.self)
        self.arguments = text.count > 2000 ? String(text.prefix(2000)) + "…" : text
        self.outcome = outcome
        self.date = date
    }
}

/// Where an installed server's updates come from (adr/0027).
public enum MCPSource: Codable, Equatable, Sendable {
    /// A bundle in a GitHub repository's latest release.
    case githubRelease(owner: String, repo: String, asset: String)
    /// An entry of the official registry, and how it was installed.
    case registry(name: String)

    /// A Featured item's or a release URL's source:
    /// https://github.com/<owner>/<repo>/releases/latest/download/<asset>
    public static func githubRelease(url: String) -> MCPSource? {
        guard let u = URL(string: url), u.host == "github.com" else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 6, parts[2] == "releases", parts[parts.count - 2] == "download" else { return nil }
        return .githubRelease(owner: parts[0], repo: parts[1], asset: parts[parts.count - 1])
    }

    /// Whether `latest` is newer than `installed` (dotted numbers; a
    /// leading "v" ignored; anything unreadable is "not newer").
    public static func isNewer(_ latest: String, than installed: String?) -> Bool {
        /// The numbers, and whether it's a prerelease (`-beta.1`).
        func parts(_ v: String) -> (numbers: [Int], pre: Bool)? {
            var t = v.hasPrefix("v") ? String(v.dropFirst()) : v
            let pre = t.contains("-")
            if let dash = t.firstIndex(of: "-") { t = String(t[..<dash]) }
            let p = t.split(separator: ".").map { Int($0) }
            return p.contains(nil) || p.isEmpty ? nil : (p.compactMap { $0 }, pre)
        }
        guard let installed, let a = parts(latest), let b = parts(installed) else { return false }
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0, y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x > y }
        }
        // The same numbers: a release is newer than its prerelease.
        return b.pre && !a.pre
    }
}

/// Who stands behind a server: IPSupport's own (ipsupport-llc on GitHub or
/// in the registry) or a third party, with no warranty from us.
public enum MCPVendor {
    public static let owner = "ipsupport-llc"

    /// A GitHub URL or a registry name of ours.
    public static func isIPSupport(_ text: String?) -> Bool {
        guard let t = text?.lowercased() else { return false }
        return t.hasPrefix("io.github.\(owner)/") || t.contains("github.com/\(owner)/")
    }
}

extension MCPServerConfig {
    /// Published by IPSupport (adr/0027): everything else is third-party.
    public var isFromIPSupport: Bool {
        switch source {
        case .githubRelease(let owner, _, _)?: if owner.lowercased() == MCPVendor.owner { return true }
        case .registry(let name)?: if MCPVendor.isIPSupport(name) { return true }
        case nil: break
        }
        return MCPVendor.isIPSupport(origin)
    }
}
