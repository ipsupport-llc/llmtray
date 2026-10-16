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
    /// Tool name → the definition hash the user reviewed. A tool missing
    /// here, or with another hash now, is hidden until reviewed again.
    public var reviewed: [String: String] = [:]
    /// Approval keys (`MCPApproval.key`) that run without asking, each bound
    /// to the hash it was given for.
    public var runWithoutAsking: [String: String] = [:]
    public var added = Date()

    public init(id: UUID = UUID(), name: String, key: String, kind: Kind) {
        self.id = id
        self.name = name
        self.key = key
        self.kind = kind
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
        public var workingDirectory: String?
        /// A bundle's settings to ask the user for (`user_config`).
        public var asks: [Ask] = []
    }

    /// One `user_config` entry of a bundle.
    public struct Ask: Equatable, Sendable {
        public var key: String
        public var title: String
        public var sensitive: Bool
        public var required: Bool
        public var defaultValue: String?
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
            if let url = (s["url"] as? String) ?? (s["serverUrl"] as? String), URL(string: url)?.scheme?.hasPrefix("http") == true {
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
        f.workingDirectory = folder
        for (key, value) in (m["user_config"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let v = value as? [String: Any] ?? [:]
            f.asks.append(Ask(key: key, title: (v["title"] as? String) ?? key, sensitive: v["sensitive"] as? Bool ?? false,
                              required: v["required"] as? Bool ?? false, defaultValue: v["default"].map { "\($0)" }))
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
        var out = text.replacingOccurrences(of: "${__dirname}", with: folder).replacingOccurrences(of: "${HOME}", with: home)
        for (key, value) in answers { out = out.replacingOccurrences(of: "${user_config.\(key)}", with: value) }
        return out
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
