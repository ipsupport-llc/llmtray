import Foundation
import LLMTrayCore
import Security

/// The MCP servers the user added (adr/0027): kept in a file (secrets in the
/// Keychain), started when a chat needs one, stopped after 15 idle minutes
/// and on quit; their tools' names for the model, and the calls.
@MainActor
final class MCPHub: ObservableObject {
    static let shared = MCPHub()

    @Published private(set) var servers: [MCPServerConfig] = []
    /// Per server: running, its log, why it's off.
    @Published private(set) var states: [UUID: ServerState] = [:]

    struct ServerState {
        var status: Status = .stopped
        var log: [String] = []
        var info: MCPClient.ServerInfo?
        var crashes: [Date] = []
        var lastUsed = Date()
    }

    enum Status: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
        /// Crashed three times in a minute: off until started in Settings.
        case crashing
    }

    private var clients: [UUID: MCPClient] = [:]
    /// The stdio transports, for the kill at quit.
    private var transports: [UUID: MCPStdioTransport] = [:]
    private var starts: [UUID: Task<MCPClient, Error>] = [:]
    private var idleTimer: Timer?

    static let idleStop: TimeInterval = 15 * 60
    static let callTimeout: TimeInterval = 60

    /// The App Store build runs only URL servers (adr/0027).
    static var commandsAllowed: Bool {
        #if APP_STORE
        false
        #else
        true
        #endif
    }

    private init() {
        load()
        publishGroups()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in MCPHub.shared.stopIdle() }
        }
    }

    // MARK: Store

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LLMTray/mcp", isDirectory: true)
    }
    static var bundlesFolder: URL { folder.appendingPathComponent("bundles", isDirectory: true) }
    private static var file: URL { folder.appendingPathComponent("servers.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        servers = (try? decoder.decode([MCPServerConfig].self, from: data)) ?? []
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(servers) { try? data.write(to: Self.file, options: .atomic) }
    }

    func server(_ id: UUID) -> MCPServerConfig? { servers.first { $0.id == id } }

    /// Adds a server, off and unreviewed; secrets go to the Keychain.
    @discardableResult
    func add(_ found: MCPImport.Found, secrets: [String: String], origin: String?) -> MCPServerConfig {
        var config = MCPServerConfig(name: found.name, key: MCPNames.serverKey(for: found.name, taken: takenKeys), kind: found.kind)
        config.command = found.command
        config.arguments = found.arguments
        config.environment = found.environment
        config.workingDirectory = found.workingDirectory
        config.url = found.url
        config.headers = found.headers
        config.description = found.description
        config.origin = origin
        for (name, value) in secrets {
            config.environment.removeValue(forKey: name)
            config.headers.removeValue(forKey: name)
            config.secretNames.append(name)
            MCPSecrets.set(value, server: config.id, name: name)
        }
        config.secretNames.sort()
        servers.append(config)
        save()
        return config
    }

    /// Keys taken: other servers', and the built-in groups' names.
    private var takenKeys: Set<String> {
        Set(servers.map(\.key)).union(ToolGroups.builtInGroups.map(\.name))
    }

    func update(_ config: MCPServerConfig) {
        guard let i = servers.firstIndex(where: { $0.id == config.id }) else { return }
        let wasEnabled = servers[i].enabled
        servers[i] = config
        save()
        publishGroups()
        if wasEnabled && !config.enabled { Task { await stop(config.id) } }
    }

    func remove(_ id: UUID) {
        guard let config = server(id) else { return }
        Task { await stop(id) }
        for name in config.secretNames { MCPSecrets.set(nil, server: id, name: name) }
        if let dir = config.workingDirectory, dir.hasPrefix(Self.bundlesFolder.path + "/") {
            try? FileManager.default.removeItem(atPath: dir)
        }
        servers.removeAll { $0.id == id }
        states.removeValue(forKey: id)
        save()
        publishGroups()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard var config = server(id) else { return }
        config.enabled = on
        if on { states[id]?.crashes = [] }
        update(config)
    }

    /// What the user reviewed: every tool as listed now.
    func markReviewed(_ id: UUID) {
        guard var config = server(id) else { return }
        config.reviewed = Dictionary(config.tools.map { ($0.name, $0.definitionHash) }, uniquingKeysWith: { a, _ in a })
        // Allowances for definitions that changed go.
        config.runWithoutAsking = config.runWithoutAsking.filter { key, hash in
            let tool = key.components(separatedBy: "#")[0]
            return config.reviewed[tool] == hash
        }
        update(config)
    }

    func setRunWithoutAsking(_ id: UUID, tool: MCP.Tool, action: String?, _ on: Bool) {
        guard var config = server(id) else { return }
        let key = MCPApproval.key(tool: tool.name, action: action)
        if on { config.runWithoutAsking[key] = tool.definitionHash } else { config.runWithoutAsking.removeValue(forKey: key) }
        update(config)
    }

    // MARK: Tools for the chat

    /// The groups the chat sees: one per server switched on with tools
    /// reviewed.
    private func publishGroups() {
        rebuildNames()
        ToolGroups.setExtra(servers.filter { $0.enabled && !$0.visibleTools.isEmpty && Self.runsHere($0) }.map { config in
            ToolGroups.Group(name: config.key,
                             tools: names.filter { $0.value.server == config.id }.map(\.key).sorted(),
                             phrase: Self.phrase(config))
        })
        objectWillChange.send()
    }

    static func runsHere(_ config: MCPServerConfig) -> Bool { config.kind == .url || commandsAllowed }

    private static func phrase(_ config: MCPServerConfig) -> String {
        let about = (config.description ?? config.name).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(about.prefix(120))
    }

    /// Model name → (server, tool name).
    private(set) var names: [String: (server: UUID, tool: String)] = [:]
    /// Names the model's built-in tools use: an MCP tool never takes one.
    var reservedNames: Set<String> = [] {
        didSet { if reservedNames != oldValue { publishGroups() } }
    }

    /// A tool's model name is given once and kept with its server
    /// (`modelNames`): switching another server off or on never moves a
    /// name to a different tool (adr/0027).
    private func rebuildNames() {
        var taken = reservedNames.union(servers.flatMap { $0.modelNames.values })
        var changed = false
        for i in servers.indices {
            for tool in servers[i].tools where servers[i].modelNames[tool.name] == nil {
                let name = MCPNames.toolName(server: servers[i].key, tool: tool.name, taken: taken)
                taken.insert(name)
                servers[i].modelNames[tool.name] = name
                changed = true
            }
        }
        if changed { save() }
        var out: [String: (UUID, String)] = [:]
        for config in servers where config.enabled && Self.runsHere(config) {
            for tool in config.visibleTools {
                guard let name = config.modelNames[tool.name], !reservedNames.contains(name) else { continue }
                out[name] = (config.id, tool.name)
            }
        }
        names = out
    }

    func tool(named model: String) -> (config: MCPServerConfig, tool: MCP.Tool)? {
        guard let (id, toolName) = names[model], let config = server(id), config.enabled,
              let tool = config.visibleTools.first(where: { $0.name == toolName }) else { return nil }
        return (config, tool)
    }

    /// The declaration the model gets: the server's schema as sent.
    func definition(model name: String) -> [String: Any]? {
        guard let (config, tool) = tool(named: name) else { return nil }
        var description = tool.description.isEmpty ? (tool.title ?? tool.name) : tool.description
        description = "[\(config.name)] " + description
        return ["type": "function", "function": ["name": name, "description": String(description.prefix(4000)),
                                                 "parameters": tool.inputSchema.isEmpty ? ["type": "object", "properties": [String: Any]()] : tool.inputSchema]]
    }

    // MARK: Running

    /// Starts the server (once; callers share a start in progress) and lists
    /// its tools, which may change what's visible.
    func connect(_ id: UUID, forReview: Bool = false) async throws -> MCPClient {
        if let client = clients[id], await client.isOpen {
            states[id, default: ServerState()].lastUsed = Date()
            return client
        }
        clients.removeValue(forKey: id)
        if let start = starts[id] { return try await start.value }
        guard let config = server(id) else { throw MCPError.closed("removed") }
        // Nothing starts while it's off, but the user's own review.
        guard config.enabled || forReview else { throw MCPError.closed("it's switched off") }
        if states[id]?.status == .crashing { throw MCPError.closed("it keeps crashing -- see its log in Settings") }
        let start = Task { @MainActor () throws -> MCPClient in
            states[id, default: ServerState()].status = .starting
            let transport = try self.transport(for: config)
            if let stdio = transport as? MCPStdioTransport { transports[id] = stdio }
            let client = MCPClient(transport: transport)
            await client.setToolsChanged { Task { @MainActor in await MCPHub.shared.refreshTools(id) } }
            let info: MCPClient.ServerInfo
            let tools: [MCP.Tool]
            do {
                info = try await client.start()
                tools = try await client.listTools()
            } catch {
                // Started or not, it goes: no child outlives a failed start.
                await client.close()
                await transport.close()
                transports.removeValue(forKey: id)
                throw error
            }
            clients[id] = client
            states[id, default: ServerState()].info = info
            states[id, default: ServerState()].status = .running
            states[id, default: ServerState()].lastUsed = Date()
            storeTools(id, tools)
            return client
        }
        starts[id] = start
        defer { starts.removeValue(forKey: id) }
        do {
            return try await start.value
        } catch {
            // A stop while starting isn't a crash.
            if !(error is CancellationError) && !Task.isCancelled { noteFailure(id, redact(error.localizedDescription, config)) }
            throw error
        }
    }

    private func transport(for config: MCPServerConfig) throws -> MCPTransport {
        switch config.kind {
        case .command:
            guard Self.commandsAllowed else { throw MCPError.closed("command servers don't run in this build") }
            var env = config.environment
            var arguments = config.arguments
            var command = config.command
            for name in config.secretNames {
                guard let v = MCPSecrets.get(server: config.id, name: name) else { continue }
                // A bundle's secret setting used in an argument (adr/0027).
                if name.hasPrefix("user_config.") {
                    arguments = arguments.map { $0.replacingOccurrences(of: "${\(name)}", with: v) }
                    command = command.replacingOccurrences(of: "${\(name)}", with: v)
                } else {
                    env[name] = v
                }
            }
            let secrets = config.secretNames.compactMap { MCPSecrets.get(server: config.id, name: $0) }.filter { $0.count >= 3 }
            let id = config.id
            return MCPStdioTransport(executable: command, arguments: arguments,
                                     environment: MCPStdioTransport.environment(adding: env),
                                     workingDirectory: config.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path,
                                     onLog: { text in
                                         var clean = text
                                         for s in secrets { clean = clean.replacingOccurrences(of: s, with: "•••") }
                                         Task { @MainActor in MCPHub.shared.appendLog(id, clean) }
                                     })
        case .url:
            guard let url = URL(string: config.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw MCPError.closed("its URL isn't valid")
            }
            var headers = config.headers
            for name in config.secretNames { if let v = MCPSecrets.get(server: config.id, name: name) { headers[name] = v } }
            return MCPHTTPTransport(url: url, headers: headers)
        }
    }

    /// The tools as the server lists them now: a changed or new one is
    /// hidden until reviewed (its hash differs); allowances follow hashes.
    private func storeTools(_ id: UUID, _ tools: [MCP.Tool]) {
        guard var config = server(id), config.tools != tools else { return }
        config.tools = tools
        if let i = servers.firstIndex(where: { $0.id == id }) { servers[i] = config }
        save()
        publishGroups()
    }

    func refreshTools(_ id: UUID) async {
        guard let client = clients[id], let tools = try? await client.listTools() else { return }
        storeTools(id, tools)
    }

    /// Starts the server for the review: its tools listed, nothing allowed.
    func startForReview(_ id: UUID) async -> String? {
        await stop(id)
        states[id]?.crashes = []
        if states[id]?.status == .crashing { states[id]?.status = .stopped }
        do {
            _ = try await connect(id, forReview: true)
            return nil
        } catch {
            return redact(error.localizedDescription, server(id))
        }
    }

    enum CallResult {
        case done(String, isError: Bool)
        case unknown
        case notSent(String)
    }

    /// A call, already allowed. A timed-out server is restarted before its
    /// next call; nothing is ever resent.
    func call(_ config: MCPServerConfig, _ tool: MCP.Tool, arguments: [String: Any]) async -> CallResult {
        let client: MCPClient
        do {
            client = try await connect(config.id)
        } catch {
            // The server's own words (an error, its stderr) stay in Settings:
            // they may hold a secret, or instructions for the model.
            return .notSent("the server couldn't be started or reached (its log in Settings says why)")
        }
        // The definition the user allowed must still be the one listed.
        guard let now = server(config.id), now.enabled, now.visibleTools.contains(tool) else {
            return .notSent("the server changed this tool since it was allowed; the user has to review it in Settings")
        }
        states[config.id, default: ServerState()].lastUsed = Date()
        switch await client.call(tool.name, arguments: arguments, timeout: Self.callTimeout) {
        case .result(let text, let isError): return .done(text, isError: isError)
        case .notSent(let why): return .notSent(why)
        case .unknown:
            // Restarted before its next call: the child goes now.
            await stop(config.id)
            return .unknown
        }
    }

    /// The tools listed again before any approval that doesn't ask is used
    /// (adr/0027): false when that failed -- then the user is asked.
    func confirmListed(_ config: MCPServerConfig) async -> Bool {
        guard let client = try? await connect(config.id), let tools = try? await client.listTools() else { return false }
        storeTools(config.id, tools)
        return true
    }

    func stop(_ id: UUID) async {
        starts[id]?.cancel()
        if let client = clients.removeValue(forKey: id) { await client.close() }
        // No client (a start under way or failed): the child still goes.
        if let transport = transports.removeValue(forKey: id) { await transport.close() }
        if states[id]?.status != .crashing { states[id]?.status = .stopped }
    }

    func stopAll() async {
        for id in Set(clients.keys).union(transports.keys) { await stop(id) }
    }

    /// At quit: every server child goes now.
    func killAllNow() {
        transports.values.forEach { $0.killNow() }
        transports = [:]
    }

    private func stopIdle() {
        let now = Date()
        for (id, state) in states where clients[id] != nil && now.timeIntervalSince(state.lastUsed) > Self.idleStop {
            Task { await stop(id) }
        }
    }

    /// A server's secret values blanked out of text shown in Settings.
    func redact(_ text: String, _ config: MCPServerConfig?) -> String {
        guard let config else { return text }
        var out = text
        for name in config.secretNames {
            if let v = MCPSecrets.get(server: config.id, name: name), v.count >= 3 { out = out.replacingOccurrences(of: v, with: "•••") }
        }
        return out
    }

    private func noteFailure(_ id: UUID, _ why: String) {
        var state = states[id, default: ServerState()]
        state.crashes = state.crashes.filter { Date().timeIntervalSince($0) < 60 } + [Date()]
        state.status = state.crashes.count >= 3 ? .crashing : .failed(why)
        state.log.append("! \(why)\n")
        states[id] = state
    }

    private func appendLog(_ id: UUID, _ text: String) {
        var log = states[id, default: ServerState()].log
        log.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) + "\n" }.filter { $0 != "\n" })
        if log.count > 200 { log.removeFirst(log.count - 200) }
        states[id, default: ServerState()].log = log
    }
}

/// Servers' secret values (environment variables, headers): in the login
/// Keychain, one item per server and name.
@MainActor
enum MCPSecrets {
    private static let service = "LLMTray.mcp"

    static func get(server: UUID, name: String) -> String? {
        var query = base(server, name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func set(_ value: String?, server: UUID, name: String) -> Bool {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base(server, name) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base(server, name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = base(server, name)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func base(_ server: UUID, _ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "\(server.uuidString)/\(name)"]
    }
}
