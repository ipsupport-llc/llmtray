import Foundation
import LLMTrayCore
import UserNotifications

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
    /// A server whose Configure should open now (set by an install).
    @Published var openConfigure: UUID?
    private var lastCheck: Date?

    private var hub: MCPHub { MCPHub.shared }

    // MARK: Values

    /// Whether a setting is secret: the bundle says so, its name looks like
    /// a key, or it goes into a variable or header whose name does.
    static func isSecret(_ ask: MCPImport.Ask, in found: MCPImport.Found) -> Bool {
        if ask.sensitive || MCPServerConfig.looksSecret(ask.key) { return true }
        let marker = "${user_config.\(ask.key)}"
        return found.environment.merging(found.headers) { a, _ in a }.contains { MCPServerConfig.looksSecret($0.key) && $0.value.contains(marker) }
    }

    /// A server's settings applied (adr/0027). A bundle's plain settings are
    /// filled in; a secret one stays a placeholder in what's stored, its value
    /// in the Keychain as `user_config.<key>`, filled in when the server
    /// starts -- so saving or updating never loses or writes it. Registry
    /// variables and headers go in by name, secret ones to the Keychain;
    /// secret-looking values given outright too. A secret left empty keeps
    /// what the Keychain has. `values`: every setting's value.
    static func prepare(_ found: MCPImport.Found, values: [String: String]) -> (found: MCPImport.Found, secrets: [String: String], answers: [String: String]) {
        var f = found
        var secrets: [String: String] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let secretKeys = Set(found.asks.filter { isSecret($0, in: found) }.map(\.key))
        let plain = values.filter { !secretKeys.contains($0.key) }
        if let folder = f.workingDirectory, isBundle(found) {
            f.command = MCPImport.fill(f.command, folder: folder, home: home, answers: plain)
            f.arguments = f.arguments.map { MCPImport.fill($0, folder: folder, home: home, answers: plain) }
            f.environment = f.environment.mapValues { MCPImport.fill($0, folder: folder, home: home, answers: plain) }
            for key in secretKeys {
                if let value = values[key], !value.isEmpty { secrets["user_config.\(key)"] = value }
            }
            if !f.command.hasPrefix("/"), !f.command.contains("${"), let path = MCPImport.resolveCommand(f.command) { f.command = path }
        } else {
            for ask in found.asks {
                let value = values[ask.key] ?? ""
                guard !value.isEmpty else { continue }
                if secretKeys.contains(ask.key) { secrets[ask.key] = value }
                else if f.kind == .command { f.environment[ask.key] = value }
                else { f.headers[ask.key] = value }
            }
        }
        // Secret-looking values given outright (a pasted config): out of
        // what's stored, into the Keychain.
        for (k, v) in f.environment where MCPServerConfig.looksSecret(k) && !v.contains("${") && !v.isEmpty {
            secrets[k] = v
            f.environment.removeValue(forKey: k)
        }
        for (k, v) in f.headers where MCPServerConfig.looksSecret(k) && !v.contains("${") && !v.isEmpty {
            secrets[k] = v
            f.headers.removeValue(forKey: k)
        }
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
                if Self.isBundle(found), let folder = found.workingDirectory { try? FileManager.default.removeItem(atPath: folder) }
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
        if let error = await startOrSignIn(config.id) {
            // It needs the user's own app (Slack): kept, off, and Configure
            // opens where its client id and secret go.
            if MCPSignIn.shared.needsOwnApp.contains(config.id), var kept = hub.server(config.id) {
                kept.enabled = false
                kept.pendingOwnApp = true
                hub.update(kept)
                message = String(format: NSLocalizedString("%@ needs your own app: add its Client ID and secret in Configure, add the Redirect URL shown there to your app, then Sign In.", comment: "MCP install"), found.name)
                openConfigure = config.id
                return
            }
            // Nothing left behind that doesn't work: taken out again, with why.
            hub.remove(config.id)
            message = String(format: NSLocalizedString("%1$@ wasn't installed: %2$@.", comment: "MCP install"), found.name,
                             error.replacingOccurrences(of: "The server stopped: ", with: ""))
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
        // A secret left empty keeps its Keychain value (prepare skips it).
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

    /// Starts a server; one that asks to sign in (a web server, adr/0028)
    /// opens the browser, then starts again. nil, or why it didn't.
    func startOrSignIn(_ id: UUID) async -> String? {
        await hub.stop(id)
        do {
            _ = try await hub.connect(id, forReview: true)
            return nil
        } catch MCPError.unauthorized(let header) {
            do {
                try await MCPSignIn.shared.signIn(id, challenge: MCPOAuth.parseChallenge(header))
            } catch {
                return error is CancellationError ? NSLocalizedString("the sign-in was cancelled", comment: "MCP") : error.localizedDescription
            }
            return await hub.startForReview(id)
        } catch {
            return hub.redact(error.localizedDescription, hub.server(id))
        }
    }

    /// Sign In, asked for: the browser opens whatever the server answers
    /// unsigned (some list their tools to anyone), then it starts again.
    func signInNow(_ id: UUID) async -> String? {
        await hub.stop(id)
        var challenge: MCPOAuth.Challenge?
        do {
            _ = try await hub.connect(id, forReview: true)
        } catch MCPError.unauthorized(let header) {
            challenge = MCPOAuth.parseChallenge(header)
        } catch {}
        await hub.stop(id)
        do {
            try await MCPSignIn.shared.signIn(id, challenge: challenge)
        } catch {
            return error is CancellationError ? NSLocalizedString("the sign-in was cancelled", comment: "MCP") : error.localizedDescription
        }
        if let error = await hub.startForReview(id) { return error }
        // The install that waited for the user's own app finishes here (the
        // user chose to install it): its tools as listed now, and on. Any
        // other server's sign-in approves or enables nothing.
        if var config = hub.server(id), config.pendingOwnApp {
            config.pendingOwnApp = false
            hub.update(config)
            hub.markReviewed(id)
            hub.setEnabled(id, true)
        }
        return nil
    }

    // MARK: Updates

    static let notificationPrefix = "mcp-update-"
    private var checking: Task<Void, Never>?
    private static let notifiedKey = "llmtray.mcp.notifiedUpdates"

    /// A minute after launch, then daily: servers with a newer version get a
    /// notification, once per version; a click opens Settings › Tools.
    func startChecking() {
        guard checking == nil else { return }
        checking = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            while !Task.isCancelled {
                await self?.checkUpdates(force: true)
                self?.notifyUpdates()
                try? await Task.sleep(nanoseconds: 24 * 3_600_000_000_000)
            }
        }
    }

    private func notifyUpdates() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let notified = UserDefaults.standard.dictionary(forKey: Self.notifiedKey) as? [String: String] ?? [:]
        for (id, latest) in updates where notified[id.uuidString] != latest {
            guard let server = hub.server(id) else { continue }
            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("Tool server update", comment: "MCP update notification title")
            content.body = String(format: NSLocalizedString("%1$@ %2$@ is available. Update it in Settings › Tools.", comment: "MCP update notification: server, version"),
                                  server.name, latest)
            let request = UNNotificationRequest(identifier: Self.notificationPrefix + id.uuidString, content: content, trigger: nil)
            Task {
                let center = UNUserNotificationCenter.current()
                guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
                do {
                    try await center.add(request)
                    // Once per version, counted only when it was shown.
                    var done = UserDefaults.standard.dictionary(forKey: Self.notifiedKey) as? [String: String] ?? [:]
                    done[id.uuidString] = latest
                    UserDefaults.standard.set(done, forKey: Self.notifiedKey)
                } catch {}
            }
        }
    }

    /// At most once an hour, when the Tools pane shows.
    /// A passing word for the pane (not a problem): it goes by itself.
    @Published var notice: String?

    /// An update check under way (the pane's button spins).
    @Published private(set) var checkingUpdates = false

    /// Check for Updates, asked for: every server now, and a word when
    /// nothing is newer -- or when the check couldn't be made.
    func checkNow() async {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        let failed = await checkUpdates(force: true)
        checkingUpdates = false
        let checkable = hub.servers.filter { $0.source != nil }
        guard updates.isEmpty else { notice = nil; return }
        if hub.servers.isEmpty {
            notice = NSLocalizedString("No servers installed.", comment: "MCP updates")
        } else if checkable.isEmpty {
            notice = NSLocalizedString("None of these servers can be updated from here (added by hand or from a file).", comment: "MCP updates")
        } else if failed > 0 {
            message = String(format: NSLocalizedString("Couldn't check %lld of the servers (no connection?). Try again later.", comment: "MCP updates"), failed)
            return
        } else {
            notice = NSLocalizedString("All servers are up to date.", comment: "MCP updates")
        }
        let shown = notice
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if notice == shown { notice = nil }
        }
    }

    /// One check at a time (the pane, the daily one, the button share it).
    private var running: Task<Int, Never>?

    /// The number of servers whose source couldn't be read.
    @discardableResult
    func checkUpdates(force: Bool = false) async -> Int {
        if let running { return await running.value }
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < 3600 { return 0 }
        lastCheck = Date()
        let task = Task { @MainActor () -> Int in
            var failed = 0
            for config in hub.servers {
                guard let source = config.source else { continue }
                guard let latest = await latestVersion(source) else { failed += 1; continue }
                if MCPSource.isNewer(latest, than: config.version) { updates[config.id] = latest } else { updates.removeValue(forKey: config.id) }
            }
            return failed
        }
        running = task
        defer { running = nil }
        return await task.value
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

    /// One click: the new version in, installed the same way (a remote stays
    /// remote), the settings kept, its tools taken as they are now (the user
    /// asked for the update). A new required setting with no default stops
    /// it: Configure first.
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
                guard let entry = await registryEntry(name) else { throw MCPImport.Failure.notABundle("the registry doesn't list it any more") }
                let same = entry.installs.first { install in
                    switch install {
                    case .remote: return config.kind == .url
                    case .bundle: return config.kind == .command && config.workingDirectory?.hasPrefix(MCPHub.bundlesFolder.path + "/") == true
                    case .package: return config.kind == .command && config.workingDirectory?.hasPrefix(MCPHub.bundlesFolder.path + "/") != true
                    }
                }
                guard let install = same else { throw MCPImport.Failure.notABundle("it isn't offered the way it was installed any more") }
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
            // A secret already in the Keychain stays: its default doesn't
            // replace what the user gave.
            for ask in found.asks where Self.isSecret(ask, in: found)
                && (MCPSecrets.get(server: id, name: "user_config.\(ask.key)") ?? MCPSecrets.get(server: id, name: ask.key)) != nil {
                values[ask.key] = ""
            }
            // A new required setting nobody gave: not now.
            let missing = found.asks.filter { ask in
                ask.required && (values[ask.key] ?? "").isEmpty
                    && MCPSecrets.get(server: id, name: "user_config.\(ask.key)") == nil && MCPSecrets.get(server: id, name: ask.key) == nil
            }
            guard missing.isEmpty else {
                if Self.isBundle(found), let folder = found.workingDirectory { try? FileManager.default.removeItem(atPath: folder) }
                throw MCPImport.Failure.unsupported(String(format: NSLocalizedString("a new setting (%@): uninstall and install it again to give it", comment: "MCP update"),
                                                           missing.map(\.title).joined(separator: ", ")))
            }
            let prepared = Self.prepare(found, values: values)
            let oldFolder = config.workingDirectory
            await hub.stop(id)
            config.kind = found.kind
            config.command = prepared.found.command
            config.arguments = prepared.found.arguments
            config.environment = prepared.found.environment
            config.headers = prepared.found.headers
            config.url = prepared.found.url
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
