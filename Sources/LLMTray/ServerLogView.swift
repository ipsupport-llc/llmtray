import AppKit
import Combine
import LLMTrayCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let showServerLog = Notification.Name("LLMTray.showServerLog")
}

/// The server log, parsed and grouped (ServerLogParser, ServerLogGrouping)
/// off the main thread, a few times a second at most (prefill progress can
/// append many lines a second), and only while the window is open.
@MainActor
final class ServerLogModel: ObservableObject {
    @Published private(set) var entries: [ServerLogEntry] = []
    /// What the status bar counts, with the entries.
    private(set) var counts = (requests: 0, errors: 0, warnings: 0)
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
            .map { ServerLogGrouping.entries(ServerLogParser.parse($0.0, firstID: $0.1)) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries in
                self?.counts = (entries.filter { $0.kind == .request }.count, entries.filter(\.isError).count,
                                entries.filter { $0.isProblem && !$0.isError }.count)
                self?.entries = entries
            }
    }
}

/// Where the log's scroll view is: at its end (following) or read back by
/// the user. Only the user's own scrolling moves it off the end -- new
/// lines growing the content don't.
@MainActor
final class LogScrollState: ObservableObject {
    @Published var atEnd = true
    let watch = UserScrollWatch()
    weak var scrollView: NSScrollView?
    private var observer: NSObjectProtocol?

    func attach(_ scroll: NSScrollView) {
        guard scrollView !== scroll else { return }
        scrollView = scroll
        watch.target = scroll
        watch.start()
        scroll.contentView.postsBoundsChangedNotifications = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // The view moved: by the user (wheel, scroller, keys) unless
                // it's the log's own scroll to the end. New lines don't move
                // it (the content grows below).
                guard let self, Date() >= self.ownScrollUntil || self.watch.isScrolling else { return }
                let end = self.isAtEnd
                if end != self.atEnd { self.atEnd = end }
            }
        }
    }

    /// The log scrolls itself (to the end, to a problem): its moves until
    /// then aren't the user's.
    private var ownScrollUntil = Date.distantPast
    func scrollingItself() { ownScrollUntil = Date().addingTimeInterval(0.4) }

    var isAtEnd: Bool {
        guard let scroll = scrollView, let document = scroll.documentView else { return true }
        let visible = scroll.contentView.bounds
        return visible.maxY >= document.frame.height - 30
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

struct ServerLogView: View {
    /// Not observed: the view follows the model's throttled entries.
    let server: ServerManager
    @StateObject private var model: ServerLogModel
    @StateObject private var scroll = LogScrollState()

    enum Scope: String, CaseIterable, Identifiable {
        case all, requests, problems
        var id: String { rawValue }
    }

    @State private var search = ""
    @AppStorage("serverLog.scope") private var scope: Scope = .all
    @AppStorage("serverLog.showEvents") private var showEvents = true
    @AppStorage("serverLog.showOther") private var showOther = true
    @AppStorage("serverLog.showDebug") private var showDebug = false
    @AppStorage("serverLog.follow") private var follow = true
    @AppStorage("serverLog.wrap") private var wrap = true
    @AppStorage("serverLog.compact") private var compact = false
    @State private var expanded: Set<Int> = []
    /// Opened by a search match and closed by hand.
    @State private var collapsed: Set<Int> = []
    @State private var newSinceLeft = 0
    @State private var lastProblemJump: Int?
    @FocusState private var searchFocused: Bool
    /// Asks the list to go to the end / to a problem (it holds the proxy).
    @State private var endRequest = 0
    @State private var problemRequest: ProblemJump?
    private struct ProblemJump: Equatable { let id: Int; let serial: Int }

    init(server: ServerManager) {
        self.server = server
        _model = StateObject(wrappedValue: ServerLogModel(server: server))
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private var visible: [ServerLogEntry] {
        model.entries.filter { entry in
            switch scope {
            case .requests where entry.kind != .request: return false
            case .problems where !entry.isProblem: return false
            default: break
            }
            if scope == .all {
                switch entry.kind {
                case .event where !showEvents: return false
                case .line where entry.head.kind == .debug && !showDebug: return false
                case .line where entry.head.kind != .debug && !showOther: return false
                default: break
                }
            }
            return query.isEmpty || entry.lines.contains { ServerLogParser.matches($0.text, query) }
        }
    }

    var body: some View {
        let entries = visible
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack(alignment: .bottomTrailing) {
                if entries.isEmpty {
                    emptyState
                } else {
                    list(entries)
                }
                if follow, !scroll.atEnd, newSinceLeft > 0 {
                    Button { jumpToEnd() } label: {
                        Label(String(format: NSLocalizedString("%@ new", comment: "Server log: entries added while reading back"),
                                     newSinceLeft.formatted()), systemImage: "arrow.down.circle.fill")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.regularMaterial))
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                    .help("Back to the newest (End)")
                }
            }
            Divider()
            LogStatusBar(server: server, counts: model.counts, total: model.entries.count, shown: entries.count,
                         filtered: scope != .all || !query.isEmpty || !showEvents || !showOther,
                         jumpToProblem: { jumpToProblem(errorsOnly: $0) }, showAll: { scope = .all; search = "" })
        }
        .frame(minWidth: 760, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(shortcuts)
        .onAppear { model.setActive(true) }
        .onDisappear { model.setActive(false) }
    }

    // MARK: List

    private static let endID = Int.min

    private func list(_ entries: [ServerLogEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                        if let gap = Self.gap(before: i, in: entries) {
                            GapMarker(seconds: gap)
                        }
                        EntryRow(entry: entry, query: query, wrap: wrap, compact: compact,
                                 expanded: isExpanded(entry), toggle: { toggle(entry) })
                            .id(entry.id)
                    }
                    Color.clear.frame(height: 1).id(Self.endID)
                }
                .padding(.vertical, 4)
                .background(ChatScrollViewFinder { scroll.attach($0) })
            }
            .background(Color(nsColor: .textBackgroundColor))
            // Anything new in the log -- a new entry, or a line joining an
            // earlier one (a request's stats after a warning).
            .onChange(of: model.entries.map(\.lines.count).reduce(0, +) + model.entries.count) { old, new in
                guard follow, new > old else { return }
                if scroll.atEnd {
                    scroll.scrollingItself()
                    proxy.scrollTo(Self.endID, anchor: .bottom)
                } else {
                    newSinceLeft += new - old
                }
            }
            .onChange(of: scroll.atEnd) { if scroll.atEnd { newSinceLeft = 0 } }
            .onChange(of: follow) {
                if follow { scroll.atEnd = true; newSinceLeft = 0; scroll.scrollingItself(); proxy.scrollTo(Self.endID, anchor: .bottom) }
            }
            .onChange(of: endRequest) {
                scroll.atEnd = true; newSinceLeft = 0; scroll.scrollingItself(); proxy.scrollTo(Self.endID, anchor: .bottom)
            }
            .onChange(of: problemRequest) {
                if let id = problemRequest?.id { scroll.scrollingItself(); withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            .onAppear {
                // A list made again (after Clear, or filters that hid all):
                // at the end, following.
                scroll.atEnd = true
                newSinceLeft = 0
                if follow { scroll.scrollingItself(); proxy.scrollTo(Self.endID, anchor: .bottom) }
            }
        }
    }

    private func jumpToEnd() { endRequest += 1 }

    /// The next error (or problem) after the last one jumped to, wrapping
    /// around; expanded, and the filters that would hide it cleared.
    private func jumpToProblem(errorsOnly: Bool) {
        let problems = model.entries.filter { errorsOnly ? $0.isError : $0.isProblem }
        guard !problems.isEmpty else { return }
        let next = problems.first { $0.id > (lastProblemJump ?? Int.min) } ?? problems[0]
        lastProblemJump = next.id
        if !visible.contains(where: { $0.id == next.id }) { scope = .all; search = "" }
        if !next.children.isEmpty { expanded.insert(next.id) }
        follow = false
        problemRequest = ProblemJump(id: next.id, serial: (problemRequest?.serial ?? 0) + 1)
    }

    private func isExpanded(_ entry: ServerLogEntry) -> Bool {
        expanded.contains(entry.id)
            || (!query.isEmpty && !collapsed.contains(entry.id) && entry.children.contains { ServerLogParser.matches($0.text, query) })
    }

    private func toggle(_ entry: ServerLogEntry) {
        if isExpanded(entry) {
            expanded.remove(entry.id)
            collapsed.insert(entry.id)
        } else {
            expanded.insert(entry.id)
            collapsed.remove(entry.id)
        }
    }

    /// Seconds since the entry before, when it's a pause worth seeing
    /// (10 s to an hour): a server that went quiet, or hung.
    static func gap(before i: Int, in entries: [ServerLogEntry]) -> Int? {
        guard i > 0, let now = seconds(entries[i].head.time) else { return nil }
        // From when the one before ended (a request's last line), not began.
        guard let before = entries[..<i].last(where: { $0.lastTime != nil }).flatMap({ seconds($0.lastTime) }) else { return nil }
        let gap = now - before
        // Negative: past midnight, or out of order -- no marker.
        return gap >= 10 ? gap : nil
    }

    static func seconds(_ time: String?) -> Int? {
        guard let parts = time?.split(separator: ":").compactMap({ Int($0) }), parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 8) {
            if model.entries.isEmpty {
                Image(systemName: "server.rack").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("No server output yet").font(.headline)
                Text("Start a model and its output shows up here: loading, requests, errors.")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("Nothing matches").font(.headline)
                Button("Show Everything") { scope = .all; search = ""; showEvents = true; showOther = true; showDebug = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        let problems = model.entries.filter(\.isProblem).count
        return HStack(spacing: 10) {
            Picker("", selection: $scope) {
                Text("All").tag(Scope.all)
                Text("Requests").tag(Scope.requests)
                Text(problems > 0 ? String(format: NSLocalizedString("Problems %@", comment: "Server log: warnings and errors (their count)"), problems.formatted())
                                  : NSLocalizedString("Problems", comment: "Server log: warnings and errors")).tag(Scope.problems)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Menu {
                Toggle("LLMTray events", isOn: $showEvents)
                Toggle("Other output", isOn: $showOther)
                Toggle("Debug lines", isOn: $showDebug)
                Divider()
                Toggle("Wrap long lines", isOn: $wrap)
                Toggle("Compact rows", isOn: $compact)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("What to show")

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { if search.isEmpty { searchFocused = false } else { search = "" } }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(searchFocused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25)))
            .frame(width: 240)
            .help("Search the log (⌘F)")

            Toggle(isOn: $follow) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Follow: keep the newest in view. Scrolling up pauses it.")

            Menu {
                Button("Copy Shown") { copy(visible) }
                Button("Save Log…") { save() }
                Divider()
                Button("Clear Log", role: .destructive) { server.clearLog(); expanded = [] }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copy, save or clear")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    /// The window's keys: ⌘F search, ⌘K clear, ⌘S save, ⇧⌘C copy, ⌘E the
    /// next error, End the newest.
    private var shortcuts: some View {
        ZStack {
            Button("") { searchFocused = true }.keyboardShortcut("f")
            // Not while typing in the search field: End moves its caret, ⌘K
            // isn't a reason to lose the log.
            Group {
                Button("") { server.clearLog(); expanded = [] }.keyboardShortcut("k")
                Button("") { save() }.keyboardShortcut("s")
                Button("") { copy(visible) }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("") { jumpToProblem(errorsOnly: true) }.keyboardShortcut("e")
                Button("") { follow = true; jumpToEnd() }.keyboardShortcut(.end, modifiers: [])
            }
            .disabled(searchFocused)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private func copy(_ entries: [ServerLogEntry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entries.map(\.text).joined(separator: "\n"), forType: .string)
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

/// The bottom line: the server's state, how many requests and problems
/// (a click goes to the next), what the filters show.
private struct LogStatusBar: View {
    @ObservedObject var server: ServerManager
    let counts: (requests: Int, errors: Int, warnings: Int)
    let total: Int
    let shown: Int
    let filtered: Bool
    let jumpToProblem: (_ errorsOnly: Bool) -> Void
    let showAll: () -> Void

    var body: some View {
        let (requests, errors, warnings) = counts
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Circle().fill(Color(nsColor: ServerStatusText.color(server))).frame(width: 7, height: 7)
                Text(ServerStatusText.text(server)).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: 340, alignment: .leading)
            Text(String(format: NSLocalizedString("%@ requests", comment: "Server log: request count"), requests.formatted()))
                .foregroundStyle(.secondary)
            Button { jumpToProblem(true) } label: {
                Label(errors.formatted(), systemImage: "xmark.octagon.fill").foregroundStyle(errors > 0 ? .red : .secondary)
            }
            .buttonStyle(.plain).disabled(errors == 0)
            .help("Errors: go to the next one (⌘E)")
            Button { jumpToProblem(false) } label: {
                Label(warnings.formatted(), systemImage: "exclamationmark.triangle.fill").foregroundStyle(warnings > 0 ? .orange : .secondary)
            }
            .buttonStyle(.plain).disabled(warnings == 0)
            .help("Warnings and errors: go to the next one")
            Spacer()
            if filtered {
                Text(String(format: NSLocalizedString("%@ of %@ shown", comment: "Server log: entries shown of all"),
                            shown.formatted(), total.formatted()))
                    .foregroundStyle(.secondary)
                Button("Show All", action: showAll).buttonStyle(.link)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }
}

/// "— 47 s later —": a pause between two entries.
private struct GapMarker: View {
    let seconds: Int

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1)
            Text(seconds < 60 ? String(format: NSLocalizedString("%lld s later", comment: "Server log: a pause between entries"), seconds)
                 : seconds < 3600 ? String(format: NSLocalizedString("%lld min later", comment: "Server log: a pause between entries"), seconds / 60)
                 : String(format: NSLocalizedString("%lld h later", comment: "Server log: a pause between entries"), seconds / 3600))
                .font(.caption2).foregroundStyle(.tertiary).fixedSize()
            Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1)
        }
        .padding(.horizontal, 90).padding(.vertical, 3)
    }
}

/// One entry: time, a symbol or a request's status, the summary and, for a
/// request, its numbers; its own lines below when expanded.
private struct EntryRow: View {
    let entry: ServerLogEntry
    let query: String
    let wrap: Bool
    let compact: Bool
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    private var mono: Font { .system(size: compact ? 11 : 12, design: .monospaced) }

    var body: some View {
        if entry.kind == .event { event } else { row }
    }

    /// An LLMTray event: a quiet divider between phases ("runtime ready").
    private var event: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 40, height: 1)
            Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(Color.accentColor)
            highlighted(entry.head.message).font(.caption).foregroundStyle(.secondary)
                .lineLimit(wrap ? nil : 1)
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 3 : 6)
        .textSelection(.enabled)
        .contextMenu { copyItems }
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                    .opacity(entry.children.isEmpty ? 0 : 1)
                Text(verbatim: entry.head.time ?? "")
                    .font(mono).foregroundStyle(.tertiary)
                    .frame(width: 62, alignment: .leading)
                marker.frame(width: 38, alignment: .leading)
                summary
                Spacer(minLength: 8)
                if let metrics {
                    Text(verbatim: metrics).font(mono).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
                }
                if entry.repeats > 1 {
                    Text(verbatim: "×\(entry.repeats)")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 5).background(Capsule().fill(Color.orange.opacity(0.15)))
                }
            }
            if let context = entry.context, entry.kind == .error, context != entry.summary {
                highlighted(context).font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 126)
                    .lineLimit(wrap ? nil : 1)
            }
            if expanded { details }
        }
        .padding(.vertical, compact ? 1 : 3)
        .padding(.horizontal, 8)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture { if !entry.children.isEmpty { withAnimation(.easeOut(duration: 0.12)) { toggle() } } }
        .onHover { hovering = $0 }
        .textSelection(.enabled)
        .contextMenu { copyItems }
    }

    @ViewBuilder private var marker: some View {
        if let status = entry.head.status {
            Text(verbatim: "\(status)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(statusColor(status).opacity(0.16)))
                .foregroundStyle(statusColor(status))
        } else if entry.kind == .error {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        } else if entry.kind == .warning {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    @ViewBuilder private var summary: some View {
        if entry.kind == .request {
            (Text(verbatim: entry.head.method ?? "").fontWeight(.semibold) + Text(verbatim: " ") + highlighted(entry.head.path ?? ""))
                .font(mono)
                .lineLimit(wrap ? nil : 1)
        } else {
            highlighted(entry.summary)
                .font(mono)
                .fontWeight(entry.kind == .error ? .semibold : .regular)
                .foregroundStyle(entry.head.kind == .debug ? .secondary : .primary)
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: false)
        }
    }

    /// "521 → 19 tok · first 0.66 s · 124 tok/s", or the prompt being read.
    private var metrics: String? {
        guard entry.kind == .request else { return nil }
        if let s = entry.stats {
            var parts = [String(format: NSLocalizedString("%@ → %@ tok", comment: "Server log: prompt and generated tokens"), s.prompt.formatted(), s.tokens.formatted())]
            parts.append(String(format: NSLocalizedString("first %@ s", comment: "Server log: wait for the first token"),
                                s.firstTokenSeconds.formatted(.number.precision(.fractionLength(2)))))
            if let tps = s.decodeTokensPerSecond {
                parts.append(String(format: NSLocalizedString("%@ tok/s", comment: "Server log: decode speed"), tps.formatted(.number.precision(.fractionLength(0)))))
            }
            return parts.joined(separator: " · ")
        }
        if let p = entry.progress, p.total > 0 {
            return String(format: NSLocalizedString("reading the prompt %@", comment: "Server log: prefill progress (percent)"),
                          (Double(p.done) / Double(p.total)).formatted(.percent.precision(.fractionLength(0))))
        }
        return nil
    }

    /// A request's numbers in words, then its own lines as written.
    private var details: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let s = entry.stats {
                Text(verbatim: String(format: NSLocalizedString("Prompt %@ tokens, %@ from the cache · first token after %@ s · %@ tokens in %@ s", comment: "Server log: a request's numbers"),
                                      s.prompt.formatted(), s.cached.formatted(), s.firstTokenSeconds.formatted(.number.precision(.fractionLength(2))),
                                      s.tokens.formatted(), s.decodeSeconds.formatted(.number.precision(.fractionLength(2))))
                     + (s.drafted > 0 ? String(format: NSLocalizedString(" · %@ drafted", comment: "Server log: tokens from accepted drafts"), s.drafted.formatted()) : ""))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }
            // The head as written, where the row shows it otherwise (a
            // request's access line, a warning without its source).
            if entry.kind == .request || (entry.kind == .warning && entry.summary != entry.head.message) {
                highlighted(entry.head.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(wrap ? nil : 1)
            }
            ForEach(entry.children) { line in
                highlighted(line.time.map { "\($0)  \(line.message)" } ?? line.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(wrap ? nil : 1)
                    .fixedSize(horizontal: !wrap, vertical: false)
            }
        }
        .padding(.leading, 126)
        .padding(.vertical, 2)
    }

    private var background: Color {
        if entry.isError { return Color.red.opacity(0.07) }
        if entry.isProblem { return Color.orange.opacity(0.06) }
        return hovering ? Color.primary.opacity(0.04) : .clear
    }

    @ViewBuilder private var copyItems: some View {
        Button("Copy Entry") { copy(entry.text) }
        if !entry.children.isEmpty { Button("Copy First Line") { copy(entry.head.text) } }
        if let path = entry.head.path { Button("Copy Path") { copy(path) } }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func statusColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: return .green
        case 300..<400: return .secondary
        case 400..<500: return .orange
        default: return .red
        }
    }

    private func highlighted(_ text: String) -> Text {
        guard !query.isEmpty else { return Text(verbatim: text) }
        var attributed = AttributedString(text)
        var start = text.startIndex
        while let r = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            if let lower = AttributedString.Index(r.lowerBound, within: attributed),
               let upper = AttributedString.Index(r.upperBound, within: attributed) {
                attributed[lower..<upper].backgroundColor = .yellow.opacity(0.45)
            }
            start = r.upperBound
        }
        return Text(attributed)
    }
}
