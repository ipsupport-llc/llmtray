import AppKit
import Combine
import LLMTrayCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let showServerLog = Notification.Name("LLMTray.showServerLog")
}

/// The server log, parsed (ServerLogParser) off the main thread, a few
/// times a second at most (prefill progress can append many lines a
/// second), and only while the window is open.
@MainActor
final class ServerLogModel: ObservableObject {
    @Published private(set) var lines: [ServerLogLine] = []
    private let server: ServerManager
    private var bag: AnyCancellable?
    private static let queue = DispatchQueue(label: "LLMTray server log parsing", qos: .userInitiated)

    init(server: ServerManager) {
        self.server = server
    }

    /// The window is shown (true) or closed.
    func setActive(_ active: Bool) {
        guard active else {
            bag = nil
            return
        }
        guard bag == nil else { return }
        bag = server.$log
            .map { [server] log in (log, server.logFirstLine) }
            .throttle(for: .milliseconds(250), scheduler: Self.queue, latest: true)
            .map { ServerLogParser.parse($0.0, firstID: $0.1) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lines in self?.lines = lines }
    }
}

struct ServerLogView: View {
    /// Not observed: the view follows the model's throttled lines.
    let server: ServerManager
    @StateObject private var model: ServerLogModel

    enum Level: String, CaseIterable, Identifiable {
        case all, problems, errors
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return NSLocalizedString("All", comment: "Server log: every level")
            case .problems: return NSLocalizedString("Warnings", comment: "Server log: warnings and errors")
            case .errors: return NSLocalizedString("Errors", comment: "Server log: errors only")
            }
        }
    }

    @State private var search = ""
    @State private var level: Level = .all
    @AppStorage("serverLog.showRequests") private var showRequests = true
    @AppStorage("serverLog.showStats") private var showStats = true
    @AppStorage("serverLog.showCache") private var showCache = true
    @AppStorage("serverLog.showProgress") private var showProgress = false
    @AppStorage("serverLog.showEvents") private var showEvents = true
    @AppStorage("serverLog.showOther") private var showOther = true
    @AppStorage("serverLog.follow") private var follow = true
    @AppStorage("serverLog.wrap") private var wrap = true

    init(server: ServerManager) {
        self.server = server
        _model = StateObject(wrappedValue: ServerLogModel(server: server))
    }

    private var visible: [ServerLogLine] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return model.lines.filter { line in
            switch level {
            case .errors where !line.isError: return false
            case .problems where !line.isProblem: return false
            default: break
            }
            if level == .all {
                switch line.kind {
                case .request where !showRequests: return false
                case .stats where !showStats: return false
                case .cache where !showCache: return false
                case .progress where !showProgress: return false
                case .event where !showEvents: return false
                case .info, .debug: if !showOther { return false }
                default: break
                }
            }
            return ServerLogParser.matches(line.text, query)
        }
    }

    var body: some View {
        let lines = visible
        VStack(spacing: 0) {
            toolbar
            Divider()
            if lines.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: model.lines.isEmpty ? "text.alignleft" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(model.lines.isEmpty
                         ? NSLocalizedString("No server output yet", comment: "Server log: empty")
                         : NSLocalizedString("No lines match the filters", comment: "Server log: everything filtered out"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in
                                LogRow(line: line, query: search, wrap: wrap)
                                    .id(line.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: lines.last?.id) {
                        if follow, let last = lines.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                    .onChange(of: follow) {
                        if follow, let last = lines.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                    .onAppear {
                        if follow, let last = lines.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            Divider()
            statusBar(shown: lines.count)
        }
        .frame(minWidth: 720, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.setActive(true) }
        .onDisappear { model.setActive(false) }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(NSLocalizedString("Search the log", comment: "Server log: search field"), text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            .frame(maxWidth: 260)

            Picker("", selection: $level) {
                ForEach(Level.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Menu {
                Toggle(NSLocalizedString("Requests", comment: "Server log filter: HTTP requests"), isOn: $showRequests)
                Toggle(NSLocalizedString("Request stats", comment: "Server log filter: per-request statistics"), isOn: $showStats)
                Toggle(NSLocalizedString("Prompt cache", comment: "Server log filter: prompt cache lines"), isOn: $showCache)
                Toggle(NSLocalizedString("Prefill progress", comment: "Server log filter: prompt processing progress"), isOn: $showProgress)
                Toggle(NSLocalizedString("LLMTray events", comment: "Server log filter: the app's own lines"), isOn: $showEvents)
                Toggle(NSLocalizedString("Other output", comment: "Server log filter: everything else"), isOn: $showOther)
                Divider()
                Toggle(NSLocalizedString("Wrap long lines", comment: "Server log: wrap lines"), isOn: $wrap)
            } label: {
                Label(NSLocalizedString("Show", comment: "Server log: which kinds of lines to show"), systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(level != .all)

            Spacer(minLength: 0)

            Toggle(isOn: $follow) {
                Label(NSLocalizedString("Follow", comment: "Server log: keep scrolled to the newest line"), systemImage: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help(NSLocalizedString("Keep the newest line in view", comment: "Server log: follow help"))

            Button { copy(visible) } label: { Image(systemName: "doc.on.doc") }
                .help(NSLocalizedString("Copy the lines shown", comment: "Server log: copy"))
            Button { save() } label: { Image(systemName: "square.and.arrow.down") }
                .help(NSLocalizedString("Save the whole log to a file…", comment: "Server log: save"))
            Button { server.clearLog() } label: { Image(systemName: "trash") }
                .help(NSLocalizedString("Clear the log", comment: "Server log: clear"))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func statusBar(shown: Int) -> some View {
        let errors = model.lines.filter(\.isError).count
        let warnings = model.lines.filter { $0.isProblem && !$0.isError }.count
        return HStack(spacing: 14) {
            Text(String(format: NSLocalizedString("%@ of %@ lines", comment: "Server log: lines shown of all"),
                        shown.formatted(), model.lines.count.formatted()))
                .foregroundStyle(.secondary)
            Button { level = .errors } label: {
                Label(String(format: NSLocalizedString("Errors: %@", comment: "Server log: error count"), errors.formatted()),
                      systemImage: "xmark.octagon.fill")
                    .foregroundStyle(errors > 0 ? .red : .secondary)
            }
            .buttonStyle(.plain).disabled(errors == 0)
            Button { level = .problems } label: {
                Label(String(format: NSLocalizedString("Warnings: %@", comment: "Server log: warning count"), warnings.formatted()),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(warnings > 0 ? .orange : .secondary)
            }
            .buttonStyle(.plain).disabled(warnings == 0)
            Spacer()
            if level != .all || !search.isEmpty {
                Button(NSLocalizedString("Show all", comment: "Server log: reset the filters")) {
                    level = .all
                    search = ""
                }
                .buttonStyle(.link)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    // MARK: Actions

    private func copy(_ lines: [ServerLogLine]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"), forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "LLMTray-server-\(stamp).log"
        panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try server.log.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = NSLocalizedString("The log couldn't be saved", comment: "Server log: save failed")
            alert.runModal()
        }
    }
}

/// One line: a colored mark by kind, the time, a request's status, the text
/// (search matches highlighted).
private struct LogRow: View {
    let line: ServerLogLine
    let query: String
    let wrap: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.time ?? " ")
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 66, alignment: .leading)
            if let status = line.status {
                Text("\(status)")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(statusColor(status).opacity(0.18)))
                    .foregroundStyle(statusColor(status))
                highlighted("\(line.method ?? "") \(line.path ?? "")")
                    .foregroundStyle(.primary)
                    .lineLimit(wrap ? nil : 1)
                    .fixedSize(horizontal: !wrap, vertical: false)
            } else {
                highlighted(line.message)
                    .foregroundStyle(textColor)
                    .fontWeight(line.kind == .event ? .semibold : .regular)
                    .lineLimit(wrap ? nil : 1)
                    .fixedSize(horizontal: !wrap, vertical: false)
            }
            Spacer(minLength: 0)
        }
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .padding(.vertical, 2)
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .background(line.isError ? Color.red.opacity(0.07) : line.isProblem ? Color.orange.opacity(0.06) : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(tint.opacity(line.kind == .info || line.kind == .debug ? 0 : 0.9)).frame(width: 3)
        }
        .contextMenu {
            Button(NSLocalizedString("Copy Line", comment: "Server log: copy one line")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line.text, forType: .string)
            }
        }
    }

    private var tint: Color {
        switch line.kind {
        case .error: return .red
        case .warning: return .orange
        case .request: return .blue
        case .stats: return .purple
        case .cache: return .teal
        case .progress: return .gray
        case .event: return .accentColor
        case .debug, .info: return .clear
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .error: return .red
        case .warning: return .orange
        case .progress, .debug: return .secondary
        case .stats: return .purple
        case .event: return .accentColor
        default: return .primary
        }
    }

    private func statusColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: return .green
        case 400..<500: return .orange
        default: return .red
        }
    }

    private func highlighted(_ text: String) -> Text {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Text(text) }
        var attributed = AttributedString(text)
        var start = text.startIndex
        while let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            if let lower = AttributedString.Index(r.lowerBound, within: attributed),
               let upper = AttributedString.Index(r.upperBound, within: attributed) {
                attributed[lower..<upper].backgroundColor = .yellow.opacity(0.45)
            }
            start = r.upperBound
        }
        return Text(attributed)
    }
}
