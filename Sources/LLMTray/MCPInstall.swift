import Foundation
import LLMTrayCore

/// Installing, updating and configuring servers (adr/0027, as the user
/// asked: Install is one click; asked only for what has no default).
@MainActor
final class MCPInstaller: ObservableObject {
    static let shared = MCPInstaller()

    /// Names (or server ids) being installed or updated now.
    @Published private(set) var busy: Set<String> = []
    /// Server id → the newer version there is.
    @Published private(set) var updates: [UUID: String] = [:]
    @Published var message: String?
    private var lastCheck: Date?

    private var hub: MCPHub { MCPHub.shared }

    // MARK: Values

    /// A server's settings applied: a bundle's placeholders filled (secret
    /// ones kept out of what's stored), registry variables or headers set,
    /// secret-looking values to the Keychain. `values`: every ask's value
    /// ("" for a secret left as it is).
    static func prepare(_ found: MCPImport.Found, values: [String: String]) -> (found: MCPImport.Found, secrets: [String: String], answers: [String: String]) {
        var f = found
        var secrets: [String: String] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let plain = values.filter { key, _ in !(found.asks.first { $0.key == key }?.sensitive ?? false) }
        if let folder = f.workingDirectory, isBundle(found) {
            f.command = MCPImport.fill(f.command, folder: folder, home: home, answers: plain)
            f.arguments = f.arguments.map { MCPImport.fill($0, folder: folder, home: home, answers: plain) }
            // Variables holding secret settings: every placeholder filled in
            // one value, then kept in the Keychain.
            var environment = f.environment.mapValues { MCPImport.fill($0, folder: folder, home: home, answers: plain) }
            for (k, v) in environment {
                var filled = v
                for ask in found.asks where ask.sensitive {
                    filled = filled.replacingOccurrences(of: "${user_config.\(ask.key)}", with: values[ask.key] ?? "")
                }
                if filled != v { secrets[k] = filled; environment.removeValue(forKey: k) }
            }
            f.environment = environment
            for ask in found.asks where ask.sensitive {
                let value = values[ask.key] ?? ""
                guard !value.isEmpty else { continue }
                let marker = "${user_config.\(ask.key)}"
                if (f.arguments + [f.command]).contains(where: { $0.contains(marker) }) { secrets["user_config.\(ask.key)"] = value }
            }
            if !f.command.hasPrefix("/"), !f.command.contains("${"), let path = MCPImport.resolveCommand(f.command) { f.command = path }
        } else {
            for ask in found.asks {
                let value = values[ask.key] ?? ""
                guard !value.isEmpty else { continue }
                if ask.sensitive { secrets[ask.key] = value }
                else if f.kind == .command { f.environment[ask.key] = value }
                else { f.headers[ask.key] = value }
            }
        }
        for (k, v) in f.environment.merging(f.headers, uniquingKeysWith: { a, _ in a })
            where MCPServerConfig.looksSecret(k) && secrets[k] == nil && !v.contains("${") && !v.isEmpty { secrets[k] = v }
        return (f, secrets, plain)
    }

    static func isBundle(_ found: MCPImport.Found) -> Bool {
        found.workingDirectory.map { $0.hasPrefix(MCPHub.bundlesFolder.path + "/") } ?? false
    }

    /// The defaults as values (${HOME} as the home folder).
    static func defaults(_ found: MCPImport.Found) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return Dictionary(uniqueKeysWithValues: found.asks.map { ($0.key, ($0.defaultValue ?? "").replacingOccurrences(of: "${HOME}", with: home)) })
    }

    /// Whether the user must be asked: a required setting with no default.
    static func needsAsking(_ found: MCPImport.Found) -> Bool {
        found.asks.contains { $0.required && ($0.defaultValue ?? "").isEmpty }
    }

    // MARK: Install

    /// One click: added, connected, its tools listed, on. False: it needs
    /// settings from the user first (the caller shows them, then `finish`).
    func install(_ found: MCPImport.Found, origin: String?, source: MCPSource?) async -> Bool {
        if Self.needsAsking(found) { return false }
        await finish(found, values: Self.defaults(found), origin: origin, source: source)
        return true
    }

    func finish(_ found: MCPImport.Found, values: [String: String], origin: String?, source: MCPSource?) async {
        busy.insert(found.name)
        defer { busy.remove(found.name) }
        var prepared = Self.prepare(found, values: values)
        // A bare command (npx, uvx), as Terminal would find it.
        if prepared.found.kind == .command, !prepared.found.command.hasPrefix("/") {
            guard let path = MCPImport.resolveCommand(prepared.found.command) else {
                message = String(format: NSLocalizedString("%1$@: the command %2$@ wasn't found.", comment: "MCP install"), found.name, prepared.found.command)
                return
            }
            prepared.found.command = path
        }
        var config = hub.add(prepared.found, secrets: prepared.secrets, origin: origin)
        config.version = found.version
        config.icon = found.icon
        config.source = source
        config.answers = prepared.answers
        config.enabled = true
        hub.update(config)
        if let error = await hub.startForReview(config.id) {
            message = String(format: NSLocalizedString("%1$@ was installed but didn't start: %2$@", comment: "MCP install"), found.name, error)
            hub.setEnabled(config.id, false)
            return
        }
        // Installing it was the review (the user's call): its tools as listed now.
        hub.markReviewed(config.id)
        message = nil
    }

    /// A bundle downloaded, checked and unpacked.
    func downloadBundle(_ url: String, sha256: String?) async throws -> MCPImport.Found {
        guard let u = URL(string: url), u.scheme == "https" else { throw MCPImport.Failure.notABundle("its address isn't https") }
        let (data, response) = try await URLSession.shared.data(from: u)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MCPImport.Failure.notABundle("it couldn't be downloaded") }
        guard data.count < 200 << 20, MCPRegistry.verifyBundle(data, sha256: sha256) else {
            throw MCPImport.Failure.notABundle("the download doesn't match what was listed for it")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mcpb")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try MCPBundles.install(file)
    }

    // MARK: Settings

    /// A bundle's settings, read from its manifest again (nil: not a bundle).
    func asks(of config: MCPServerConfig) -> MCPImport.Found? {
        guard let folder = config.workingDirectory, folder.hasPrefix(MCPHub.bundlesFolder.path + "/"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("manifest.json")) else { return nil }
        return try? MCPImport.parseManifest(data, folder: folder)
    }

    /// New settings: the command, arguments and variables made again from
    /// the manifest; a secret left empty keeps its value. Restarted.
    func apply(_ id: UUID, values: [String: String]) async {
        guard var config = hub.server(id), let found = asks(of: config) else { return }
        var values = values
        for ask in found.asks where ask.sensitive && (values[ask.key] ?? "").isEmpty {
            // Unchanged: the stored secret goes back in.
            if let v = MCPSecrets.get(server: id, name: "user_config.\(ask.key)") { values[ask.key] = v }
        }
        let prepared = Self.prepare(found, values: values)
        config.command = prepared.found.command
        config.arguments = prepared.found.arguments
        config.environment = prepared.found.environment
        config.answers = prepared.answers
        for (name, value) in prepared.secrets {
            MCPSecrets.set(value, server: id, name: name)
            if !config.secretNames.contains(name) { config.secretNames.append(name) }
        }
        hub.update(config)
        await hub.stop(id)
        if config.enabled { _ = try? await hub.connect(id) }
    }

    // MARK: Updates

    /// At most once an hour, when the Tools pane shows.
    func checkUpdates(force: Bool = false) async {
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < 3600 { return }
        lastCheck = Date()
        for config in hub.servers {
            guard let source = config.source, let latest = await latestVersion(source) else { continue }
            if MCPSource.isNewer(latest, than: config.version) { updates[config.id] = latest } else { updates.removeValue(forKey: config.id) }
        }
    }

    private func latestVersion(_ source: MCPSource) async -> String? {
        switch source {
        case .githubRelease(let owner, let repo, _):
            guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else { return nil }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return object["tag_name"] as? String
        case .registry(let name):
            return await registryEntry(name)?.version
        }
    }

    private func registryEntry(_ name: String) async -> MCPRegistry.Entry? {
        guard let (data, _) = try? await URLSession.shared.data(from: MCPRegistry.searchURL(name, limit: 10)) else { return nil }
        let runners = Set(["npx", "uvx"].filter { MCPImport.resolveCommand($0) != nil })
        return MCPRegistry.parse(data, available: runners).entries.first { $0.name == name }
    }

    /// One click: the new version in, the settings kept, its tools taken as
    /// they are now (the user asked for the update).
    func update(_ id: UUID) async {
        guard var config = hub.server(id), let source = config.source else { return }
        busy.insert(id.uuidString)
        defer { busy.remove(id.uuidString) }
        do {
            var found: MCPImport.Found
            switch source {
            case .githubRelease(let owner, let repo, let asset):
                found = try await downloadBundle("https://github.com/\(owner)/\(repo)/releases/latest/download/\(asset)", sha256: nil)
            case .registry(let name):
                guard let entry = await registryEntry(name), let install = entry.installs.first else {
                    throw MCPImport.Failure.notABundle("the registry doesn't list it any more")
                }
                if case .bundle(let url, let sha) = install {
                    found = try await downloadBundle(url, sha256: sha)
                } else {
                    guard let f = MCPRegistry.found(entry, install, runnerPath: { MCPImport.resolveCommand($0) }) else {
                        throw MCPImport.Failure.notABundle("it can't run here any more")
                    }
                    found = f
                    found.version = entry.version
                }
            }
            var values = Self.defaults(found).merging(config.answers) { _, kept in kept }
            for ask in found.asks where ask.sensitive {
                values[ask.key] = MCPSecrets.get(server: id, name: "user_config.\(ask.key)") ?? MCPSecrets.get(server: id, name: ask.key) ?? ""
            }
            let prepared = Self.prepare(found, values: values)
            let oldFolder = config.workingDirectory
            await hub.stop(id)
            config.command = prepared.found.command
            config.arguments = prepared.found.arguments
            config.environment = prepared.found.environment.merging(config.environment.filter { key, _ in prepared.found.environment[key] == nil && found.kind == .command && !Self.isBundle(found) }) { new, _ in new }
            config.url = prepared.found.url.isEmpty ? config.url : prepared.found.url
            config.workingDirectory = prepared.found.workingDirectory ?? config.workingDirectory
            config.version = found.version
            config.icon = found.icon ?? config.icon
            config.answers = prepared.answers
            for (name, value) in prepared.secrets {
                MCPSecrets.set(value, server: id, name: name)
                if !config.secretNames.contains(name) { config.secretNames.append(name) }
            }
            hub.update(config)
            if let oldFolder, oldFolder != config.workingDirectory, oldFolder.hasPrefix(MCPHub.bundlesFolder.path + "/") {
                try? FileManager.default.removeItem(atPath: oldFolder)
            }
            if config.enabled, await hub.startForReview(id) == nil { hub.markReviewed(id) }
            updates.removeValue(forKey: id)
        } catch {
            message = String(format: NSLocalizedString("%1$@ couldn't be updated: %2$@", comment: "MCP update"), config.name, error.localizedDescription)
        }
    }
}
