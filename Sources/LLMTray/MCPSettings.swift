import AppKit
import LLMTrayCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Tools: the MCP servers the chat may use (adr/0027). Installed
/// or Discover, a search, + Add; a server installs in one click (asked only
/// for a setting with no default), updates in one, and is configured or
/// uninstalled from its row.
struct ToolsPane: View {
    @ObservedObject private var hub = MCPHub.shared
    @ObservedObject private var installer = MCPInstaller.shared
    @State private var tab: Tab = .installed
    @State private var query = ""
    @State private var sheet: Sheet?
    @State private var dropTargeted = false

    enum Tab: Hashable { case installed, discover }

    enum Sheet: Identifiable {
        case command, url, paste
        case asks(MCPImport.Found, origin: String?, source: MCPSource?)
        case configure(UUID)
        var id: String {
            switch self {
            case .command: return "command"
            case .url: return "url"
            case .paste: return "paste"
            case .asks(let f, _, _): return "asks-\(f.name)-\(f.command)-\(f.url)"
            case .configure(let id): return "configure-\(id)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Tools").font(.title2.weight(.semibold))
                Picker("", selection: $tab) {
                    Text("Installed").tag(Tab.installed)
                    Text("Discover").tag(Tab.discover)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.3)))
                .frame(width: 180)
                Menu {
                    if MCPHub.commandsAllowed {
                        Button("Install a Bundle (.mcpb)…") { pickBundle() }
                        Button("Paste a Config…") { sheet = .paste }
                        Button("Add a Command…") { sheet = .command }
                    }
                    Button("Add a URL…") { sheet = .url }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
            if let message = installer.message {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(message).font(.callout)
                    Spacer()
                    Button { installer.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 20).padding(.bottom, 8)
            }
            Divider()
            switch tab {
            case .installed: installed
            case .discover: DiscoverView(query: query, askFor: { found, origin, source in sheet = .asks(found, origin: origin, source: source) })
            }
        }
        .task { await installer.checkUpdates() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "mcpb" else { return }
                Task { @MainActor in installBundle(url) }
            }
            return true
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .command: AddServerSheet(kind: .command) { found in self.sheet = nil; install(found, origin: nil, source: nil) }
            case .url: AddServerSheet(kind: .url) { found in self.sheet = nil; install(found, origin: nil, source: nil) }
            case .paste: PasteConfigSheet { found in
                self.sheet = nil
                found.forEach { install($0, origin: NSLocalizedString("Pasted config", comment: "MCP server origin"), source: nil) }
            }
            case .asks(let found, let origin, let source):
                AsksSheet(found: found) { values in
                    Task { await installer.finish(found, values: values, origin: origin, source: source) }
                }
            case .configure(let id): ConfigureSheet(serverID: id)
            }
        }
    }

    private var installed: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let shown = hub.servers.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                    if !hub.servers.isEmpty {
                        HStack {
                            Text("Server").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Runs").frame(width: 90, alignment: .leading)
                            Text("Status").frame(width: 60, alignment: .leading)
                            // Only a width: Color.clear alone takes all the height it's offered.
                            Color.clear.frame(width: 190, height: 0)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        Divider().padding(.horizontal, 12)
                        ForEach(shown) { server in
                            ServerRow(server: server, configure: { sheet = .configure(server.id) })
                            Divider().padding(.horizontal, 12)
                        }
                    }
                    // The rest of the pane: where a bundle is dropped (the
                    // App Store build installs none: only its empty state).
                    if MCPHub.commandsAllowed || hub.servers.isEmpty {
                        dropZone
                            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
                            .padding(20)
                    }
                }
                .frame(minHeight: geo.size.height)
            }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                          style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1.5, dash: [7, 5]))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: hub.servers.isEmpty ? "puzzlepiece.extension" : "square.and.arrow.down")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
                    if hub.servers.isEmpty {
                        Text("Give the chat more tools").font(.title3.weight(.semibold))
                        Text("Mail, notes, calendars, files and services. The chat asks you before each call.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Discover Servers") { tab = .discover }.controlSize(.large)
                    }
                    if MCPHub.commandsAllowed {
                        Text("Drop .mcpb files here to install").font(hub.servers.isEmpty ? .callout : .body.weight(.medium))
                            .foregroundStyle(hub.servers.isEmpty ? .secondary : .primary)
                        Button("or choose a file…") { pickBundle() }.buttonStyle(.link).font(.callout)
                    }
                }
                .padding(24)
            }
            .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    private func install(_ found: MCPImport.Found, origin: String?, source: MCPSource?) {
        Task {
            if await !installer.install(found, origin: origin, source: source) {
                sheet = .asks(found, origin: origin, source: source)
            }
        }
    }

    private func pickBundle() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mcpb") ?? .zip, .zip]
        panel.message = NSLocalizedString("Choose an MCP bundle (.mcpb).", comment: "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        installBundle(url)
    }

    private func installBundle(_ url: URL) {
        do {
            install(try MCPBundles.install(url), origin: url.lastPathComponent, source: nil)
        } catch {
            installer.message = error.localizedDescription
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

/// A server's icon: its bundle's file, an https icon, or its first letter.
struct ServerIcon: View {
    let icon: String?
    let name: String
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let icon, icon.hasPrefix("/"), let image = NSImage(contentsOfFile: icon) {
                Image(nsImage: image).resizable().scaledToFit()
            } else if let icon, icon.hasPrefix("https://"), let url = URL(string: icon) {
                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { monogram }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var monogram: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Color.accentColor.opacity(0.18))
            .overlay(Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(Color.accentColor))
    }
}

// MARK: - A server's row

private struct ServerRow: View {
    let server: MCPServerConfig
    let configure: () -> Void
    @ObservedObject private var hub = MCPHub.shared
    @ObservedObject private var installer = MCPInstaller.shared

    private var state: MCPHub.ServerState? { hub.states[server.id] }

    var body: some View {
        HStack(spacing: 10) {
            ServerIcon(icon: server.iconPath, name: server.name)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(server.name).font(.body.weight(.medium))
                    if let version = server.version { Text(version).font(.caption).foregroundStyle(.secondary) }
                }
                if let problem { Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(server.kind == .command ? "This Mac" : "Web").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            status.frame(width: 60, alignment: .leading)
            HStack(spacing: 6) {
                if let latest = installer.updates[server.id] {
                    Button(String(format: NSLocalizedString("Update to %@", comment: "MCP server"), latest)) {
                        Task { await installer.update(server.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(installer.busy.contains(server.id.uuidString))
                }
                Button("Configure", action: configure)
                Menu {
                    Button(server.enabled ? "Turn Off" : "Turn On") { hub.setEnabled(server.id, !server.enabled) }
                        .disabled(server.visibleTools.isEmpty || !MCPHub.runsHere(server))
                    Button("Show Log…", action: configure)
                    Divider()
                    Button("Uninstall", role: .destructive) { hub.remove(server.id) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .frame(width: 190, alignment: .trailing)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    @ViewBuilder private var status: some View {
        if installer.busy.contains(server.id.uuidString) || state?.status == .starting {
            ProgressView().controlSize(.small)
        } else if problem != nil {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        } else if server.enabled {
            Image(systemName: "checkmark").foregroundStyle(.green)
        } else {
            Text("Off").foregroundStyle(.secondary)
        }
    }

    private var problem: String? {
        if !MCPHub.runsHere(server) { return NSLocalizedString("Doesn't run in this version of LLMTray.", comment: "") }
        switch state?.status {
        case .failed(let why): return why
        case .crashing: return NSLocalizedString("Keeps crashing -- see its log.", comment: "MCP server")
        default: break
        }
        if !server.unreviewedTools.isEmpty, !server.reviewed.isEmpty {
            return String(format: NSLocalizedString("%lld tools changed on the server: Configure to accept them.", comment: "MCP server"),
                          server.unreviewedTools.count)
        }
        return nil
    }
}

// MARK: - Discover

private struct DiscoverView: View {
    let query: String
    let askFor: (MCPImport.Found, String?, MCPSource?) -> Void
    @ObservedObject private var hub = MCPHub.shared
    @ObservedObject private var installer = MCPInstaller.shared
    @State private var entries: [MCPRegistry.Entry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var runners: [String: String] = [:]

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let featured = MCPFeatured.items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
                if !featured.isEmpty, MCPHub.commandsAllowed {
                    Text("Featured").font(.headline)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(featured, id: \.bundleURL) { item in
                            Card(icon: item.iconURL, title: item.title, description: item.description, publisher: item.publisher,
                                 state: state(source: MCPSource.githubRelease(url: item.bundleURL), name: item.title),
                                 install: { installFeatured(item) })
                        }
                    }
                }
                HStack {
                    Text("From the MCP Registry").font(.headline)
                    if loading {
                        ProgressView().controlSize(.small)
                        Text(query.isEmpty ? "Loading…" : "Searching the registry…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !loading, error == nil, entries.isEmpty, !query.isEmpty {
                    Text("Nothing found for “\(query)”.").foregroundStyle(.secondary)
                }
                Text("The registry checks who published a name, not what the code does. The chat asks you before each call.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.orange).font(.callout) }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(entries) { entry in
                        Card(icon: entry.iconURL, title: entry.title, description: entry.description, publisher: entry.publisher,
                             state: entryState(entry), install: { install(entry) })
                    }
                }
            }
            .padding(20)
        }
        .task(id: query) {
            if runners.isEmpty {
                runners = ["npx": MCPImport.resolveCommand("npx"), "uvx": MCPImport.resolveCommand("uvx")].compactMapValues { $0 }
            }
            try? await Task.sleep(nanoseconds: query.isEmpty ? 0 : 400_000_000)
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    enum CardState: Equatable { case available, installing, installed, needs(String) }

    private func state(source: MCPSource?, name: String) -> CardState {
        if installer.busy.contains(name) { return .installing }
        if let source, hub.servers.contains(where: { $0.source == source }) { return .installed }
        return .available
    }

    private func entryState(_ entry: MCPRegistry.Entry) -> CardState {
        let s = state(source: .registry(name: entry.name), name: entry.title)
        guard s == .available else { return s }
        if !entry.installs.contains(where: allowed) { return .needs(entry.needs ?? NSLocalizedString("something LLMTray can't run", comment: "")) }
        return .available
    }

    private func allowed(_ install: MCPRegistry.Install) -> Bool {
        if case .remote = install { return true }
        return MCPHub.commandsAllowed
    }

    /// The registry's search can take half a minute: results that don't
    /// match the words typed now are never shown (nor left on screen).
    private func search() async {
        let words = query
        entries = []
        error = nil
        loading = true
        var request = URLRequest(url: MCPRegistry.searchURL(words, limit: 40))
        request.timeoutInterval = 30
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard words == query, !Task.isCancelled else { return }
            entries = MCPRegistry.parse(data, available: Set(runners.keys)).entries
        } catch {
            guard words == query, !Task.isCancelled else { return }
            self.error = (error as? URLError)?.code == .timedOut
                ? NSLocalizedString("The registry didn't answer in 30 seconds. Try again in a moment.", comment: "MCP catalog")
                : error.localizedDescription
        }
        loading = false
    }

    private func installFeatured(_ item: MCPFeatured.Item) {
        Task {
            do {
                var found = try await installer.downloadBundle(item.bundleURL, sha256: nil)
                found.name = item.title
                found.icon = found.icon ?? item.iconURL
                await go(found, origin: item.repository, source: MCPSource.githubRelease(url: item.bundleURL))
            } catch {
                installer.message = error.localizedDescription
            }
        }
    }

    private func install(_ entry: MCPRegistry.Entry) {
        guard let install = entry.installs.first(where: allowed) else { return }
        Task {
            do {
                var found: MCPImport.Found
                if case .bundle(let url, let sha) = install {
                    found = try await installer.downloadBundle(url, sha256: sha)
                } else {
                    guard let f = MCPRegistry.found(entry, install, runnerPath: { runners[$0] }) else { return }
                    found = f
                }
                found.name = entry.title
                found.version = found.version ?? entry.version
                found.icon = found.icon ?? entry.iconURL
                await go(found, origin: entry.name, source: .registry(name: entry.name))
            } catch {
                installer.message = error.localizedDescription
            }
        }
    }

    private func go(_ found: MCPImport.Found, origin: String?, source: MCPSource?) async {
        if await !installer.install(found, origin: origin, source: source) { askFor(found, origin, source) }
    }

    private struct Card: View {
        let icon: String?
        let title: String
        let description: String
        let publisher: String
        let state: CardState
        let install: () -> Void

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                ServerIcon(icon: icon, name: title, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold)).lineLimit(1)
                    Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 4) {
                        if state == .installed {
                            Label("Installed", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                            Text("·").foregroundStyle(.secondary)
                        }
                        Text("by \(publisher)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if case .needs(let what) = state {
                        Text(String(format: NSLocalizedString("Needs %@", comment: "MCP catalog"), what)).font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 4)
                switch state {
                case .available:
                    Button(action: install) { Image(systemName: "plus").frame(width: 18, height: 18) }
                        .help(Text("Install"))
                case .installing:
                    ProgressView().controlSize(.small)
                case .installed:
                    Image(systemName: "checkmark").foregroundStyle(.green).frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.15)))
                case .needs:
                    EmptyView()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
        }
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
/// One setting a server asks for, by its type: a checkbox, a number, a
/// folder or file with Choose…, text (secure for a secret); its
/// description under it.
private struct AskField: View {
    let ask: MCPImport.Ask
    @Binding var value: String
    /// Shown as a secret: the bundle says so, or it looks like one.
    var secret = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch ask.kind {
            case .boolean:
                Toggle(ask.title, isOn: Binding(get: { value == "true" }, set: { value = $0 ? "true" : "false" }))
            case .directory, .file:
                LabeledContent(ask.title + (ask.required ? " *" : "")) {
                    HStack {
                        Text(value.isEmpty ? NSLocalizedString("None", comment: "MCP setting: no folder") : (value as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(value.isEmpty ? .secondary : .primary)
                        Button("Choose…") { choose() }
                    }
                }
            case .number:
                TextField(ask.title + (ask.required ? " *" : ""), text: $value)
            case .string:
                if ask.sensitive || secret {
                    SecureField(ask.title + (ask.required ? " *" : ""), text: $value)
                } else {
                    TextField(ask.title + (ask.required ? " *" : ""), text: $value)
                }
            }
            if let help = ask.help, !help.isEmpty {
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = ask.kind == .directory
        panel.canChooseFiles = ask.kind == .file
        panel.canCreateDirectories = ask.kind == .directory
        if !value.isEmpty { panel.directoryURL = URL(fileURLWithPath: value) }
        if panel.runModal() == .OK, let url = panel.url { value = url.path }
    }
}


// MARK: - Settings a server needs

/// Only when a server needs a setting with no default (a key): its
/// settings, then Install.
private struct AsksSheet: View {
    let found: MCPImport.Found
    let install: ([String: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var installing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ServerIcon(icon: found.icon, name: found.name, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(found.name).font(.headline)
                    if let description = found.description { Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                }
            }
            Form {
                ForEach(found.asks, id: \.key) { ask in
                    AskField(ask: ask, value: Binding(get: { values[ask.key] ?? "" }, set: { values[ask.key] = $0 }),
                             secret: MCPInstaller.isSecret(ask, in: found))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Install") {
                    installing = true
                    install(values)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(found.asks.contains { $0.required && (values[$0.key] ?? "").isEmpty })
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { values = MCPInstaller.defaults(found) }
        // Closed without Install (Cancel, Esc): an unpacked bundle goes.
        .onDisappear {
            if !installing, MCPInstaller.isBundle(found), let folder = found.workingDirectory { try? FileManager.default.removeItem(atPath: folder) }
        }
    }
}

// MARK: - Configure

/// On or off, the server's settings, what each tool does (and which run
/// without asking), tools changed on the server, the command and the log
/// under Details, Uninstall.
private struct ConfigureSheet: View {
    let serverID: UUID
    @ObservedObject private var hub = MCPHub.shared
    @ObservedObject private var installer = MCPInstaller.shared
    @Environment(\.dismiss) private var dismiss
    @State private var details = false
    @State private var values: [String: String] = [:]
    @State private var settingsFound: MCPImport.Found?
    @State private var saving = false
    @State private var starting = false

    private var server: MCPServerConfig? { hub.server(serverID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let server {
                HStack(spacing: 10) {
                    ServerIcon(icon: server.iconPath, name: server.name, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(server.name).font(.headline)
                            if let v = server.version { Text(v).font(.caption).foregroundStyle(.secondary) }
                        }
                        if let d = server.description { Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                    }
                    Spacer()
                    Toggle("On", isOn: Binding(get: { server.enabled }, set: { hub.setEnabled(serverID, $0) }))
                        .toggleStyle(.switch)
                        .disabled(server.visibleTools.isEmpty || !MCPHub.runsHere(server))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let found = settingsFound, !found.asks.isEmpty {
                            GroupBox("Settings") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(found.asks, id: \.key) { ask in
                                        AskField(ask: ask, value: Binding(get: { values[ask.key] ?? "" }, set: { values[ask.key] = $0 }),
                                                 secret: MCPInstaller.isSecret(ask, in: found))
                                    }
                                    HStack {
                                        Spacer()
                                        if saving { ProgressView().controlSize(.small) }
                                        Button("Save") {
                                            saving = true
                                            Task {
                                                await installer.apply(serverID, values: values)
                                                saving = false
                                            }
                                        }
                                    }
                                }
                                .padding(6)
                            }
                        }
                        if !server.unreviewedTools.isEmpty, !server.reviewed.isEmpty {
                            HStack {
                                Label(String(format: NSLocalizedString("%lld tools are new or changed on the server: hidden from the chat until you accept them.", comment: "MCP"),
                                             server.unreviewedTools.count), systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button("Accept") { hub.markReviewed(serverID) }
                            }
                        }
                        if starting {
                            HStack { ProgressView().controlSize(.small); Text("Connecting…").foregroundStyle(.secondary) }
                        }
                        if server.enabled, !server.visibleTools.isEmpty {
                            HStack(spacing: 8) {
                                Text("Run without asking:").font(.callout)
                                Button("Everything") { hub.setRunWithoutAsking(serverID, tools: server.visibleTools, true) }
                                if server.visibleTools.contains(where: { $0.readOnlyHint == true }) {
                                    Button("Reads Only") {
                                        hub.setRunWithoutAsking(serverID, tools: server.visibleTools, false)
                                        hub.setRunWithoutAsking(serverID, tools: server.visibleTools.filter { $0.readOnlyHint == true }, true)
                                    }
                                }
                                Button("Nothing") { hub.setRunWithoutAsking(serverID, tools: server.visibleTools, false) }
                                Spacer()
                            }
                            .controlSize(.small)
                            Text("Reading on this Mac never asks once allowed. After the chat reads a mail, a file or the web, a change (send, move, delete) or a call to a server on the web is asked anyway.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(server.tools, id: \.name) { tool in
                            ToolReviewRow(server: server, tool: tool, details: details)
                        }
                        DisclosureGroup("Details", isExpanded: $details) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(server.kind == .command ? ([server.command] + server.arguments).joined(separator: " ") : server.url)
                                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let info = hub.states[serverID]?.info {
                                    Text("\(info.name) \(info.version) · MCP \(info.protocolVersion)").font(.caption).foregroundStyle(.secondary)
                                }
                                Text("Log").font(.caption.weight(.semibold))
                                Text((hub.states[serverID]?.log ?? []).joined().isEmpty ? NSLocalizedString("Nothing logged yet.", comment: "") : (hub.states[serverID]?.log ?? []).joined())
                                    .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Connect Again") { reconnect() }.disabled(starting)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 240, maxHeight: 440)
                HStack {
                    Button("Uninstall", role: .destructive) {
                        hub.remove(serverID)
                        dismiss()
                    }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            guard let server else { return }
            settingsFound = installer.asks(of: server)
            if let found = settingsFound {
                values = MCPInstaller.defaults(found).merging(server.answers) { _, kept in kept }
                for ask in found.asks where MCPInstaller.isSecret(ask, in: found) { values[ask.key] = "" }
            }
            if server.tools.isEmpty { reconnect() }
        }
    }

    private func reconnect() {
        starting = true
        Task {
            if let error = await hub.startForReview(serverID) {
                installer.message = error
            } else if hub.server(serverID)?.reviewed.isEmpty == true {
                // It never started at install: this is its first look.
                hub.markReviewed(serverID)
            }
            starting = false
        }
    }
}
/// One tool: its title, the first line of what it says, what it can do
/// (its actions), whether it changes things; its arguments under Details.
private struct ToolReviewRow: View {
    let server: MCPServerConfig
    let tool: MCP.Tool
    let details: Bool
    @ObservedObject private var hub = MCPHub.shared
    @State private var allowOpen = false

    private var reviewed: Bool { server.reviewed[tool.name] == tool.definitionHash }
    private var summary: String {
        tool.description.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: tool.readOnlyHint == true ? "eye" : "pencil")
                    .foregroundStyle(tool.readOnlyHint == true ? Color.secondary : Color.orange)
                    .help(tool.readOnlyHint == true ? Text("The server says this only reads.") : Text("This can change things."))
                Text(tool.title ?? tool.name).font(.callout.weight(.semibold))
                if !reviewed && !server.reviewed.isEmpty { Text("new or changed").font(.caption2).foregroundStyle(.orange) }
            }
            if !summary.isEmpty {
                Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let field = tool.actionField {
                Text(field.values.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if details {
                Text(tool.inputSchemaJSON).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if reviewed && server.enabled {
                DisclosureGroup("Run without asking", isExpanded: $allowOpen) {
                  VStack(alignment: .leading, spacing: 4) {
                    if let field = tool.actionField {
                        Toggle("All", isOn: Binding(get: { field.values.allSatisfy { binding($0).wrappedValue } },
                                                    set: { hub.setRunWithoutAsking(server.id, tools: [tool], $0) }))
                            .toggleStyle(.checkbox).font(.caption.weight(.semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading, spacing: 2) {
                            ForEach(field.values, id: \.self) { action in
                                Toggle(action.replacingOccurrences(of: "_", with: " "), isOn: binding(action))
                                    .toggleStyle(.checkbox).font(.caption)
                            }
                        }
                    } else {
                        Toggle("This tool", isOn: binding(nil)).toggleStyle(.checkbox).font(.caption)
                    }
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
    }

    private func binding(_ action: String?) -> Binding<Bool> {
        Binding(get: { server.runWithoutAsking[MCPApproval.key(tool: tool.name, action: action)] == tool.definitionHash },
                set: { hub.setRunWithoutAsking(server.id, tool: tool, action: action, $0) })
    }
}


extension MCPServerConfig {
    /// Its icon, or a bundle's icon.png when none was recorded (installed
    /// before icons were kept).
    @MainActor var iconPath: String? {
        if let icon { return icon }
        guard let folder = workingDirectory, folder.hasPrefix(MCPHub.bundlesFolder.path + "/") else { return nil }
        let file = (folder as NSString).appendingPathComponent("icon.png")
        return FileManager.default.fileExists(atPath: file) ? file : nil
    }
}
