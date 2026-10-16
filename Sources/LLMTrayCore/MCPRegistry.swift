import CryptoKit
import Foundation

/// The official MCP Registry (adr/0027, "The catalog"): searched when the
/// user opens Browse; an entry becomes a server to review, the same as one
/// added by hand. Only what can run here is offered.
public enum MCPRegistry {
    public static let base = URL(string: "https://registry.modelcontextprotocol.io/v0/servers")!

    /// One way to run an entry.
    public enum Install: Equatable, Sendable {
        /// A remote server's URL; `headers` to ask the user for.
        case remote(url: String, headers: [MCPImport.Ask])
        /// An npm or PyPI package run by `npx` / `uvx`.
        case package(runner: String, identifier: String, version: String?, arguments: [String], environment: [MCPImport.Ask])
        /// An MCP bundle to download (checked against its SHA-256 when given).
        case bundle(url: String, sha256: String?)
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: String { name }
        /// The registry's name (`io.github.owner/server`): who published it.
        public var name: String
        public var title: String
        public var description: String
        public var version: String
        public var repository: String?
        /// Ways to run it here, best first (a remote, a bundle, a package).
        public var installs: [Install]
        /// Why it can't run here, when `installs` is empty (needs Docker…).
        public var needs: String?
    }

    /// Search: newest versions only, active only.
    public static func searchURL(_ query: String, cursor: String? = nil, limit: Int = 30) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "limit", value: "\(limit)"), URLQueryItem(name: "version", value: "latest")]
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { items.append(URLQueryItem(name: "search", value: q)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        c.queryItems = items
        return c.url!
    }

    /// `available`: the runners found on this Mac (`npx`, `uvx`).
    public static func parse(_ data: Data, available: Set<String>) -> (entries: [Entry], next: String?) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], nil) }
        let entries = (object["servers"] as? [[String: Any]] ?? []).compactMap { item -> Entry? in
            guard let server = item["server"] as? [String: Any], let name = server["name"] as? String else { return nil }
            let meta = (item["_meta"] as? [String: Any])?["io.modelcontextprotocol.registry/official"] as? [String: Any]
            if let status = meta?["status"] as? String, status != "active" { return nil }
            return entry(server, name: name, available: available)
        }
        return (entries, (object["metadata"] as? [String: Any])?["nextCursor"] as? String)
    }

    static func entry(_ server: [String: Any], name: String, available: Set<String>) -> Entry {
        var installs: [Install] = []
        var needs: [String] = []
        for remote in server["remotes"] as? [[String: Any]] ?? [] {
            guard remote["type"] as? String == "streamable-http", let url = remote["url"] as? String else {
                needs.append("an older kind of connection (SSE)")
                continue
            }
            installs.append(.remote(url: url, headers: asks(remote["headers"])))
        }
        for package in server["packages"] as? [[String: Any]] ?? [] {
            let type = package["registryType"] as? String ?? ""
            let transport = (package["transport"] as? [String: Any])?["type"] as? String ?? "stdio"
            guard let identifier = package["identifier"] as? String else { continue }
            if type == "mcpb" {
                installs.append(.bundle(url: identifier, sha256: package["fileSha256"] as? String))
                continue
            }
            guard transport == "stdio" else { continue }
            let runner: String
            switch type {
            case "npm": runner = "npx"
            case "pypi": runner = "uvx"
            case "oci": needs.append("Docker"); continue
            default: needs.append(type); continue
            }
            guard available.contains(runner) else { needs.append(runner == "npx" ? "Node (npx)" : "uv (uvx)"); continue }
            let arguments = (package["packageArguments"] as? [[String: Any]] ?? []).compactMap { a -> String? in
                guard a["type"] as? String == "positional" else { return nil }
                return (a["value"] as? String) ?? (a["default"] as? String)
            }
            installs.append(.package(runner: runner, identifier: identifier, version: package["version"] as? String,
                                     arguments: arguments, environment: asks(package["environmentVariables"])))
        }
        // A remote first (nothing runs here), then a bundle, then a package.
        func rank(_ i: Install) -> Int {
            switch i { case .remote: return 0; case .bundle: return 1; case .package: return 2 }
        }
        installs.sort { rank($0) < rank($1) }
        return Entry(name: name, title: (server["title"] as? String) ?? name.components(separatedBy: "/").last ?? name,
                     description: server["description"] as? String ?? "", version: server["version"] as? String ?? "",
                     repository: (server["repository"] as? [String: Any])?["url"] as? String,
                     installs: installs, needs: installs.isEmpty ? Array(Set(needs)).sorted().joined(separator: ", ").nilIfEmpty : nil)
    }

    static func asks(_ any: Any?) -> [MCPImport.Ask] {
        (any as? [[String: Any]] ?? []).compactMap { v in
            guard let name = v["name"] as? String else { return nil }
            return MCPImport.Ask(key: name, title: (v["description"] as? String) ?? name,
                                 sensitive: v["isSecret"] as? Bool ?? MCPServerConfig.looksSecret(name),
                                 required: v["isRequired"] as? Bool ?? false, defaultValue: v["default"] as? String)
        }
    }

    /// An install as a server to review: its command (the runner's path) or
    /// URL; the values the user gave go in after.
    public static func found(_ entry: Entry, _ install: Install, runnerPath: (String) -> String?) -> MCPImport.Found? {
        switch install {
        case .remote(let url, let headers):
            var f = MCPImport.Found(name: entry.title, kind: .url)
            f.url = url
            f.description = entry.description
            f.asks = headers
            return f
        case .package(let runner, let identifier, let version, let arguments, let environment):
            guard let path = runnerPath(runner) else { return nil }
            var f = MCPImport.Found(name: entry.title, kind: .command)
            f.command = path
            let spec = version.map { runner == "npx" ? "\(identifier)@\($0)" : "\(identifier)==\($0)" } ?? identifier
            f.arguments = (runner == "npx" ? ["-y", spec] : [spec]) + arguments
            f.description = entry.description
            f.asks = environment
            return f
        case .bundle:
            return nil   // downloaded and unpacked first (`verifyBundle`), then read as a bundle
        }
    }

    /// A downloaded bundle matches the registry's SHA-256 (when it gave one).
    public static func verifyBundle(_ data: Data, sha256: String?) -> Bool {
        guard let sha256 else { return true }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == sha256.lowercased()
    }
}

/// Servers suggested on top of the catalog, kept in the app.
public enum MCPFeatured {
    public struct Item: Sendable, Equatable {
        public var title: String
        public var description: String
        public var bundleURL: String
        public var repository: String
    }

    public static let items: [Item] = [
        Item(title: "Apple Mail, Calendar & Notes",
             description: "Read, search and organize Apple Mail, Calendar and Notes on this Mac. Zero dependencies (runs on macOS's own JavaScript for Automation).",
             bundleURL: "https://github.com/ipsupport-llc/apple-mail-mcp/releases/latest/download/apple-mail-mcp.mcpb",
             repository: "https://github.com/ipsupport-llc/apple-mail-mcp"),
    ]
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
