import AppKit
import LLMTrayCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Tools: the MCP servers the chat may use (adr/0027).
struct ToolsPane: View {
    @ObservedObject private var hub = MCPHub.shared
    @State private var sheet: Sheet?
    @State private var error: String?

    enum Sheet: Identifiable {
        case command, url, paste, browse
        case asks(MCPImport.Found, origin: String?)
        case review(UUID)
        var id: String {
            switch self {
            case .command: return "command"
            case .url: return "url"
            case .paste: return "paste"
            case .browse: return "browse"
            case .asks(let f, _): return "asks-\(f.name)-\(f.command)-\(f.url)"
            case .review(let id): return "review-\(id)"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Text("Servers that give the chat more tools: mail, notes, calendars, files, services. Each one runs only after you review it, loads into a chat from the + menu (or when the model asks), and asks you before every call unless you let a tool run without asking.")
                    .font(.callout).foregroundStyle(.secondary)
                if hub.servers.isEmpty {
                    Text("No servers yet.").foregroundStyle(.secondary)
                }
                ForEach(hub.servers) { server in
                    ServerRow(server: server, review: { sheet = .review(server.id) })
                }
                HStack {
                    Menu("Add Server") {
                        Button("Browse the Catalog…") { sheet = .browse }
                        Divider()
                        if MCPHub.commandsAllowed {
                            Button("Install a Bundle (.mcpb)…") { installBundle() }
                            Button("Paste a Config…") { sheet = .paste }
                            Button("Add a Command…") { sheet = .command }
                        }
                        Button("Add a URL…") { sheet = .url }
                    }
                    .fixedSize()
                    Spacer()
                }
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("MCP Servers")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .command: AddServerSheet(kind: .command) { found in self.sheet = .asks(found, origin: nil) }
            case .url: AddServerSheet(kind: .url) { found in self.sheet = .asks(found, origin: nil) }
            case .paste: PasteConfigSheet { found in self.sheet = found.count == 1 ? .asks(found[0], origin: nil) : nil; addAll(found) }
            case .browse: BrowseSheet { found, origin in self.sheet = .asks(found, origin: origin) }
            case .asks(let found, let origin):
                AsksSheet(found: found) { filled, secrets in
                    let config = hub.add(filled, secrets: secrets, origin: origin)
                    self.sheet = .review(config.id)
                }
            case .review(let id): ReviewSheet(serverID: id)
            }
        }
    }

    /// Several servers from one pasted config: each added (off), to review
    /// from its row.
    private func addAll(_ found: [MCPImport.Found]) {
        guard found.count > 1 else { return }
        for f in found {
            var f = f
            if f.kind == .command {
                guard let path = MCPImport.resolveCommand(f.command) else {
                    error = String(format: NSLocalizedString("%1$@: the command %2$@ wasn't found.", comment: ""), f.name, f.command)
                    continue
                }
                f.command = path
            }
            let secrets = (f.environment.merging(f.headers) { a, _ in a }).filter { MCPServerConfig.looksSecret($0.key) }
            hub.add(f, secrets: secrets, origin: NSLocalizedString("Pasted config", comment: "MCP server origin"))
        }
    }

    private func installBundle() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mcpb") ?? .zip, .zip]
        panel.message = NSLocalizedString("Choose an MCP bundle (.mcpb).", comment: "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let found = try MCPBundles.install(url)
            sheet = .asks(found, origin: url.lastPathComponent)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Unpacking a bundle into the app's data and reading its manifest.
@MainActor
enum MCPBundles {
    static func install(_ archive: URL) throws -> MCPImport.Found {
        let folder = MCPHub.bundlesFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: MCPHub.bundlesFolder, withIntermediateDirectories: true)
        try MCPImport.unpackBundle(archive, into: folder)
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
            return try MCPImport.parseManifest(data, folder: folder.path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

// MARK: - A server's row

private struct ServerRow: View {
    let server: MCPServerConfig
    let review: () -> Void
    @ObservedObject private var hub = MCPHub.shared
    @State private var showLog = false
    @State private var confirmRemove = false

    private var state: MCPHub.ServerState? { hub.states[server.id] }
    private var needsReview: Bool { server.tools.isEmpty || !server.unreviewedTools.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(server.name).font(.body.weight(.medium))
                        Text(server.kind == .command ? "command" : "URL").font(.caption2)
                            .padding(.horizontal, 4).background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                    }
                    Text(status).font(.caption).foregroundStyle(statusIsBad ? .orange : .secondary)
                }
                Spacer()
                Button(needsReview ? "Review…" : "Tools…", action: review)
                Toggle("", isOn: Binding(get: { server.enabled }, set: { hub.setEnabled(server.id, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(server.visibleTools.isEmpty || !MCPHub.runsHere(server))
            }
            HStack(spacing: 12) {
                Button(showLog ? "Hide Log" : "Log") { showLog.toggle() }.buttonStyle(.link)
                if case .crashing = state?.status {
                    Button("Start Again") { Task { _ = await hub.startForReview(server.id) } }.buttonStyle(.link)
                }
                Spacer()
                Button("Remove…") { confirmRemove = true }.buttonStyle(.link)
            }
            .font(.caption)
            if showLog {
                ScrollView {
                    Text((state?.log ?? []).joined().isEmpty ? NSLocalizedString("Nothing logged yet.", comment: "") : (state?.log ?? []).joined())
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
            }
        }
        .confirmationDialog("Remove \(server.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { hub.remove(server.id) }
        } message: {
            Text("Its settings, secrets and (for a bundle) its files go. Chats keep their record of past calls.")
        }
    }

    private var statusIsBad: Bool {
        switch state?.status {
        case .failed, .crashing: return true
        default: return needsReview && !server.tools.isEmpty
        }
    }

    private var status: String {
        if !MCPHub.runsHere(server) { return NSLocalizedString("Command servers don't run in this version of LLMTray.", comment: "") }
        switch state?.status {
        case .starting: return NSLocalizedString("Starting…", comment: "MCP server")
        case .failed(let why): return why
        case .crashing: return NSLocalizedString("Keeps crashing: off until started again (see its log).", comment: "MCP server")
        default: break
        }
        if server.tools.isEmpty { return NSLocalizedString("Not reviewed yet: review it to see its tools.", comment: "MCP server") }
        if !server.unreviewedTools.isEmpty {
            return String(format: NSLocalizedString("%lld tools new or changed: hidden from the chat until reviewed.", comment: "MCP server"),
                          server.unreviewedTools.count)
        }
        let n = server.visibleTools.count
        let running = state?.status == .running ? NSLocalizedString(" · running", comment: "MCP server") : ""
        return String(format: NSLocalizedString("%lld tools%@", comment: "MCP server: tool count, running"), n, running)
    }
}

// MARK: - Adding

private struct AddServerSheet: View {
    let kind: MCPServerConfig.Kind
    let next: (MCPImport.Found) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = ""
    @State private var arguments = ""
    @State private var variables = ""
    @State private var url = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind == .command ? "Add a Command Server" : "Add a URL Server").font(.headline)
            Form {
                TextField("Name", text: $name)
                if kind == .command {
                    TextField("Command", text: $command, prompt: Text("npx, uvx, or a full path"))
                    VStack(alignment: .leading) {
                        Text("Arguments, one per line").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $arguments).font(.system(.body, design: .monospaced)).frame(height: 70)
                    }
                    VStack(alignment: .leading) {
                        Text("Environment, NAME=value per line (keys, tokens and passwords go to the Keychain)").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $variables).font(.system(.body, design: .monospaced)).frame(height: 60)
                    }
                } else {
                    TextField("URL", text: $url, prompt: Text("https://…/mcp"))
                    VStack(alignment: .leading) {
                        Text("Headers, Name: value per line (an Authorization header goes to the Keychain)").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $variables).font(.system(.body, design: .monospaced)).frame(height: 60)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Next") { submit() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (kind == .command ? command.isEmpty : url.isEmpty))
            }
        }
        .padding()
        .frame(width: 520)
    }

    private func submit() {
        var f = MCPImport.Found(name: name.trimmingCharacters(in: .whitespaces), kind: kind)
        if kind == .command {
            guard let path = MCPImport.resolveCommand(command.trimmingCharacters(in: .whitespaces)) else {
                error = NSLocalizedString("That command wasn't found (looked up the way Terminal would).", comment: "")
                return
            }
            f.command = path
            f.arguments = arguments.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            f.environment = Self.pairs(variables, separator: "=")
        } else {
            guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else {
                error = NSLocalizedString("That isn't an http(s) URL.", comment: "")
                return
            }
            f.url = u.absoluteString
            f.headers = Self.pairs(variables, separator: ":")
        }
        next(f)
    }

    static func pairs(_ text: String, separator: Character) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let i = line.firstIndex(of: separator) else { continue }
            let key = line[..<i].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value }
        }
        return out
    }
}

private struct PasteConfigSheet: View {
    let next: ([MCPImport.Found]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste a Config").font(.headline)
            Text("The JSON a server's README gives, with \"mcpServers\". Each server is added switched off, to review before it runs.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(height: 200)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Next") {
                    do {
                        var found = try MCPImport.parseConfig(text)
                        if found.count == 1, found[0].kind == .command {
                            guard let path = MCPImport.resolveCommand(found[0].command) else {
                                error = String(format: NSLocalizedString("The command %@ wasn't found.", comment: ""), found[0].command)
                                return
                            }
                            found[0].command = path
                        }
                        next(found)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 560)
    }
}

/// The values a server needs from the user (a bundle's settings, a
/// registry entry's variables or headers), and which of its own values
/// are secret. Shows the command or URL in full before anything is added.
private struct AsksSheet: View {
    let found: MCPImport.Found
    let add: (MCPImport.Found, [String: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(format: NSLocalizedString("Add %@", comment: "MCP: add server"), found.name)).font(.headline)
            if let description = found.description, !description.isEmpty {
                Text(description).font(.callout).foregroundStyle(.secondary)
            }
            GroupBox {
                Text(found.kind == .command ? ([found.command] + found.arguments).map(Self.quoted).joined(separator: " ") : found.url)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(found.kind == .command ? "Runs this command" : "Connects to")
            }
            if !found.asks.isEmpty {
                Form {
                    ForEach(found.asks, id: \.key) { ask in
                        let binding = Binding(get: { answers[ask.key] ?? ask.defaultValue ?? "" }, set: { answers[ask.key] = $0 })
                        if ask.sensitive {
                            SecureField(ask.title + (ask.required ? " *" : ""), text: binding)
                        } else {
                            TextField(ask.title + (ask.required ? " *" : ""), text: binding)
                        }
                    }
                }
            }
            Text("Nothing runs yet: next you start it once and review its tools.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(found.asks.contains { $0.required && (answers[$0.key] ?? $0.defaultValue ?? "").isEmpty })
            }
        }
        .padding()
        .frame(width: 560)
    }

    static func quoted(_ s: String) -> String { s.contains(" ") ? "\"\(s)\"" : s }

    private func submit() {
        var f = found
        var secrets: [String: String] = [:]
        let values = Dictionary(uniqueKeysWithValues: found.asks.map { ($0.key, answers[$0.key] ?? $0.defaultValue ?? "") })
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let folder = f.workingDirectory, !f.asks.isEmpty || f.arguments.contains(where: { $0.contains("${") }) || f.command.contains("${") {
            // A bundle: its placeholders filled.
            let plain = values.filter { key, _ in !(found.asks.first { $0.key == key }?.sensitive ?? false) }
            f.command = MCPImport.fill(f.command, folder: folder, home: home, answers: plain)
            f.arguments = f.arguments.map { MCPImport.fill($0, folder: folder, home: home, answers: plain) }
            f.environment = f.environment.mapValues { MCPImport.fill($0, folder: folder, home: home, answers: plain) }
            // A secret placeholder goes in by the environment, never written
            // into the arguments on disk: in an argument it's filled at start.
            for ask in found.asks where ask.sensitive {
                let value = values[ask.key] ?? ""
                guard !value.isEmpty else { continue }
                let marker = "${user_config.\(ask.key)}"
                for (k, v) in f.environment where v.contains(marker) { secrets[k] = v.replacingOccurrences(of: marker, with: value) }
                // In an argument: kept as the placeholder, the value in the
                // Keychain under its name, filled when the server starts.
                if f.arguments.contains(where: { $0.contains(marker) }) { secrets["user_config.\(ask.key)"] = value }
            }
        } else {
            // Registry variables or headers: secret ones to the Keychain.
            for ask in found.asks {
                let value = values[ask.key] ?? ""
                guard !value.isEmpty else { continue }
                if ask.sensitive { secrets[ask.key] = value }
                else if f.kind == .command { f.environment[ask.key] = value }
                else { f.headers[ask.key] = value }
            }
        }
        // The server's own values that look secret, unless already resolved
        // above (a bundle's) or still a placeholder.
        for (k, v) in f.environment.merging(f.headers, uniquingKeysWith: { a, _ in a })
            where MCPServerConfig.looksSecret(k) && secrets[k] == nil && !v.contains("${") && !v.isEmpty { secrets[k] = v }
        add(f, secrets)
    }
}

// MARK: - Review

/// Start once, see every tool, turn it on; then each tool's (or action's)
/// "Run without asking".
private struct ReviewSheet: View {
    let serverID: UUID
    @ObservedObject private var hub = MCPHub.shared
    @Environment(\.dismiss) private var dismiss
    @State private var starting = false
    @State private var error: String?

    private var server: MCPServerConfig? { hub.server(serverID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let server {
                Text(server.name).font(.headline)
                GroupBox {
                    Text(server.kind == .command ? ([server.command] + server.arguments).joined(separator: " ") : server.url)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text(server.kind == .command ? "Command" : "URL") }
                if let info = hub.states[serverID]?.info {
                    Text("\(info.name) \(info.version) · MCP \(info.protocolVersion)").font(.caption).foregroundStyle(.secondary)
                }
                if server.tools.isEmpty {
                    Text("Start it once to see what it offers. Nothing is allowed by starting it; the chat can't use it until you turn it on.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(server.tools, id: \.name) { tool in
                                ToolReviewRow(server: server, tool: tool)
                                Divider()
                            }
                        }
                    }
                    .frame(minHeight: 220, maxHeight: 380)
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Button(server.tools.isEmpty ? "Start and Review" : "List Again") { start() }.disabled(starting)
                    if starting { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Close") { dismiss() }
                    if !server.tools.isEmpty, !server.unreviewedTools.isEmpty || !server.enabled {
                        Button("Turn On") {
                            hub.markReviewed(serverID)
                            hub.setEnabled(serverID, true)
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding()
        .frame(width: 600)
    }

    private func start() {
        starting = true
        error = nil
        Task {
            error = await hub.startForReview(serverID)
            starting = false
        }
    }
}

private struct ToolReviewRow: View {
    let server: MCPServerConfig
    let tool: MCP.Tool
    @ObservedObject private var hub = MCPHub.shared
    @State private var open = false

    private var reviewed: Bool { server.reviewed[tool.name] == tool.definitionHash }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(tool.title ?? tool.name).font(.callout.weight(.medium))
                Text(tool.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                if !reviewed { Text("new or changed").font(.caption2).foregroundStyle(.orange) }
                if tool.readOnlyHint == true {
                    Text("the server says it only reads").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(open ? nil : 3)
            Button(open ? "Less" : "Arguments…") { open.toggle() }.buttonStyle(.link).font(.caption)
            if open {
                Text(tool.inputSchemaJSON).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
            }
            if reviewed && server.enabled {
                if let field = tool.actionField {
                    Text("Run without asking:").font(.caption)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 2) {
                        ForEach(field.values, id: \.self) { action in
                            Toggle(action, isOn: binding(action))
                                .toggleStyle(.checkbox).font(.caption)
                        }
                    }
                } else {
                    Toggle("Run without asking", isOn: binding(nil)).toggleStyle(.checkbox).font(.caption)
                }
            }
        }
    }

    private func binding(_ action: String?) -> Binding<Bool> {
        Binding(get: { server.runWithoutAsking[MCPApproval.key(tool: tool.name, action: action)] == tool.definitionHash },
                set: { hub.setRunWithoutAsking(server.id, tool: tool, action: action, $0) })
    }
}

// MARK: - The catalog

private struct BrowseSheet: View {
    let next: (MCPImport.Found, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var entries: [MCPRegistry.Entry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var runners: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MCP Servers").font(.headline)
            Text("From the official MCP Registry. The registry checks who published a name, not what the code does: review a server before you turn it on.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Search", text: $query).onSubmit { search() }
                Button("Search") { search() }
                if loading { ProgressView().controlSize(.small) }
            }
            List {
                if query.isEmpty {
                    Section("Featured") {
                        ForEach(MCPFeatured.items, id: \.bundleURL) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(item.title).font(.callout.weight(.medium))
                                    Spacer()
                                    if MCPHub.commandsAllowed {
                                        Button("Install") { installFeatured(item) }
                                    }
                                }
                                Text(item.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section(query.isEmpty ? "Recent" : "Results") {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.title).font(.callout.weight(.medium))
                                Text(entry.name).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                if let install = entry.installs.first(where: allowed) {
                                    Button("Install") { pick(entry, install) }
                                } else {
                                    Text(entry.needs.map { String(format: NSLocalizedString("Needs %@", comment: "MCP catalog"), $0) } ?? "")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(entry.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            }
            .frame(minHeight: 320)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding()
        .frame(width: 640, height: 560)
        .task {
            runners = ["npx": MCPImport.resolveCommand("npx"), "uvx": MCPImport.resolveCommand("uvx")].compactMapValues { $0 }
            search()
        }
    }

    private func allowed(_ install: MCPRegistry.Install) -> Bool {
        if case .remote = install { return true }
        return MCPHub.commandsAllowed
    }

    private func search() {
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                let (data, _) = try await URLSession.shared.data(from: MCPRegistry.searchURL(query))
                entries = MCPRegistry.parse(data, available: Set(runners.keys)).entries
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func pick(_ entry: MCPRegistry.Entry, _ install: MCPRegistry.Install) {
        if case .bundle(let url, let sha) = install {
            download(url, sha256: sha, origin: entry.name)
            return
        }
        guard let found = MCPRegistry.found(entry, install, runnerPath: { runners[$0] }) else { return }
        next(found, entry.name)
    }

    private func installFeatured(_ item: MCPFeatured.Item) {
        download(item.bundleURL, sha256: nil, origin: item.repository)
    }

    private func download(_ url: String, sha256: String?, origin: String) {
        guard let u = URL(string: url), u.scheme == "https" else { error = NSLocalizedString("The bundle's address isn't https.", comment: ""); return }
        loading = true
        Task {
            defer { loading = false }
            do {
                let (data, response) = try await URLSession.shared.data(from: u)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    error = NSLocalizedString("The bundle couldn't be downloaded.", comment: "")
                    return
                }
                guard data.count < 200 << 20, MCPRegistry.verifyBundle(data, sha256: sha256) else {
                    error = NSLocalizedString("The download doesn't match what the registry lists for it.", comment: "")
                    return
                }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mcpb")
                try data.write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                next(try MCPBundles.install(file), origin)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
