import LLMTrayCore
import SwiftUI

/// The Server window: Usage and Log, one window (a second one for
/// statistics was one too many).
struct ServerWindowView: View {
    let server: ServerManager
    @AppStorage("llmtray.serverWindow.tab") private var tab = "log"

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Usage").tag("usage")
                Text("Log").tag("log")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 8)
            Divider()
            if tab == "usage" {
                UsageView()
            } else {
                ServerLogView(server: server)
            }
        }
    }
}

/// Usage statistics (UsageLedger): requests and tokens per model, client
/// or day, and how fast -- when turned on, kept only on this Mac.
struct UsageView: View {
    @ObservedObject private var store = UsageStore.shared
    @AppStorage(Pref.usageStatsEnabled.name) private var enabled = Pref.usageStatsEnabled.defaultValue
    @AppStorage("llmtray.usage.period") private var period = UsageLedger.Period.week.rawValue
    @AppStorage("llmtray.usage.grouping") private var grouping = UsageLedger.Grouping.model.rawValue
    @State private var confirmsClear = false
    /// Read again every minute: Today moves on at midnight.
    @State private var now = Date()
    /// Bumped when this window comes to the front: the table is made again.
    @State private var shown = 0
    @StateObject private var window = HostWindow()
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var selectedPeriod: UsageLedger.Period { UsageLedger.Period(rawValue: period) ?? .week }
    private var selectedGrouping: UsageLedger.Grouping { UsageLedger.Grouping(rawValue: grouping) ?? .model }

    var body: some View {
        Group { if enabled { statistics } else { off } }
            .onReceive(tick) { now = $0 }
            .background(ChatScrollViewFinder.WindowReader { window.window = $0 })
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard let key = note.object as? NSWindow, key === window.window else { return }
                now = Date()
                shown += 1
            }
            .confirmationDialog("Clear the usage statistics?", isPresented: $confirmsClear) {
                Button("Clear", role: .destructive) { store.clear() }
            } message: {
                Text("Every day's counts are removed. This can't be undone.")
            }
    }

    private var off: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Usage statistics are off").font(.title3.weight(.semibold))
            Text("Count requests and tokens per model, client and day, and how fast they ran. Kept only on this Mac, never sent anywhere.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("Turn On") { enabled = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            // What was kept before it was turned off can still go.
            if !store.ledger.rows.isEmpty {
                Button("Clear Statistics…") { confirmsClear = true }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statistics: some View {
        let lines = store.ledger.lines(selectedPeriod, by: selectedGrouping, now: now)
        let total = UsageLedger.total(lines)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("", selection: $period) {
                    Text("Today").tag(UsageLedger.Period.today.rawValue)
                    Text("7 Days").tag(UsageLedger.Period.week.rawValue)
                    Text("All").tag(UsageLedger.Period.all.rawValue)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("By", selection: $grouping) {
                    Text("Model").tag(UsageLedger.Grouping.model.rawValue)
                    Text("Client").tag(UsageLedger.Grouping.client.rawValue)
                    Text("Day").tag(UsageLedger.Grouping.day.rawValue)
                }
                .pickerStyle(.segmented).fixedSize()
                Spacer()
                Menu {
                    Button("Clear Statistics…", role: .destructive) { confirmsClear = true }
                    Button("Turn Off") { enabled = false }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Clear or turn off")
            }
            summary(total)
            if lines.isEmpty {
                Text(selectedPeriod == .today ? "No requests yet today." : "No requests yet in this period.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table(lines)
            }
            Text("Kept only on this Mac. Clients are named by LLMTray's proxy from their User-Agent; requests the runtime served before it named them count as Other.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private func summary(_ c: UsageLedger.Counts) -> some View {
        HStack(spacing: 10) {
            tile("Requests", Self.count(c.requests), nil)
            tile("Prompt tokens", Self.count(c.promptTokens),
                 c.cachedShare.map { String(format: NSLocalizedString("%@ from cache", comment: "usage: share of prompt tokens the cache had"), Self.percent($0)) })
            tile("Generated tokens", Self.count(c.generatedTokens), nil)
            tile("Speed", c.decodeTokensPerSecond.map(Self.rate) ?? "—",
                 c.meanFirstTokenSeconds.map { String(format: NSLocalizedString("first token in %@ on average", comment: "usage: mean wait for the first token"), Self.seconds($0)) })
        }
    }

    private func tile(_ title: LocalizedStringKey, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(verbatim: detail ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func table(_ lines: [UsageLedger.Line]) -> some View {
        Table(lines) {
            TableColumn(selectedGrouping == .day ? "Day" : selectedGrouping == .client ? "Client" : "Model") { line in
                Text(verbatim: selectedGrouping == .day ? Self.dayName(line.name) : line.name).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 140, ideal: 220)
            TableColumn("Requests") { Text(verbatim: Self.count($0.counts.requests)).monospacedDigit() }.width(70)
            TableColumn("Prompt") { Text(verbatim: Self.count($0.counts.promptTokens)).monospacedDigit() }.width(70)
            TableColumn("Cached") { Text(verbatim: $0.counts.cachedShare.map(Self.percent) ?? "—").monospacedDigit() }.width(60)
            TableColumn("Generated") { Text(verbatim: Self.count($0.counts.generatedTokens)).monospacedDigit() }.width(76)
            TableColumn("Prefill") { Text(verbatim: $0.counts.prefillTokensPerSecond.map(Self.rate) ?? "—").monospacedDigit() }.width(84)
            TableColumn("Decode") { Text(verbatim: $0.counts.decodeTokensPerSecond.map(Self.rate) ?? "—").monospacedDigit() }.width(76)
            TableColumn("First token") { Text(verbatim: $0.counts.meanFirstTokenSeconds.map(Self.seconds) ?? "—").monospacedDigit() }.width(76)
        }
        // Made again when its rows come or go (a new model, client or day)
        // and when the window comes back: the native table could miss rows
        // added while the window was behind others, until reopened.
        .id(TableKey(names: Set(lines.map(\.name)), shown: shown))
    }

    /// The window the tab is in (weak).
    final class HostWindow: ObservableObject {
        weak var window: NSWindow?
    }

    private struct TableKey: Hashable {
        /// The rows there are, not their order (most requests first moves).
        let names: Set<String>
        let shown: Int
    }

    static func count(_ n: Int) -> String { n.formatted(.number.notation(.compactName)) }
    static func percent(_ x: Double) -> String { x.formatted(.percent.precision(.fractionLength(0))) }
    static func rate(_ x: Double) -> String { String(format: NSLocalizedString("%@ tok/s", comment: "usage: tokens a second"), x.formatted(.number.precision(.fractionLength(0)))) }
    static func seconds(_ x: Double) -> String { String(format: NSLocalizedString("%@ s", comment: "usage: seconds"), x.formatted(.number.precision(.fractionLength(x < 10 ? 2 : 1)))) }

    /// "2026-10-18" as the locale writes a day ("Oct 18, 2026").
    private static let dayParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = UsageLedger.localCalendar
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()

    static func dayName(_ day: String) -> String {
        guard let date = dayParser.date(from: day) else { return day }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
