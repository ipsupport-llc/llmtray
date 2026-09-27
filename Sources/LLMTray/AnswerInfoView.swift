import LLMTrayCore
import SwiftUI

/// Which answer's details are open: one at a time, across the chat. Hover
/// opens them after a short delay and closes them once the pointer has left
/// both the icon and the popover; a click toggles them and keeps them open
/// (the keyboard's way in).
@MainActor
final class AnswerInfoPresenter: ObservableObject {
    static let shared = AnswerInfoPresenter()

    @Published private(set) var openID: UUID?
    /// Opened by a click: leaving doesn't close it.
    private var pinned = false
    private var overIcon: UUID?
    private var overPopover = false
    /// Closed by a click while hovered: not reopened until the pointer leaves.
    private var suppressed: UUID?
    private var task: Task<Void, Never>?

    static let openDelay: UInt64 = 300_000_000
    /// Time to cross from the icon into the popover.
    static let closeDelay: UInt64 = 250_000_000

    func hoverIcon(_ id: UUID, _ inside: Bool) {
        if inside {
            overIcon = id
        } else if overIcon == id {
            overIcon = nil
            if suppressed == id { suppressed = nil }
        }
        schedule()
    }

    func hoverPopover(_ inside: Bool) {
        overPopover = inside
        schedule()
    }

    func toggle(_ id: UUID) {
        task?.cancel()
        if openID == id {
            close()
            suppressed = overIcon
        } else {
            openID = id
            pinned = true
        }
    }

    func close() {
        task?.cancel()
        openID = nil
        pinned = false
        overPopover = false
    }

    private func schedule() {
        task?.cancel()
        let wanted: UUID? = overPopover ? openID : (overIcon == suppressed ? nil : overIcon)
        if wanted == openID { return }
        if wanted == nil, pinned { return }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wanted == nil ? Self.closeDelay : Self.openDelay)
            guard !Task.isCancelled, let self else { return }
            self.openID = wanted
            self.pinned = false
            if wanted == nil { self.overPopover = false }
        }
    }
}

/// The info icon under an answer, and its details popover.
@MainActor
struct AnswerInfoButton: View {
    let id: UUID
    let stats: AnswerStats
    @ObservedObject private var presenter = AnswerInfoPresenter.shared

    var body: some View {
        Button { presenter.toggle(id) } label: {
            Image(systemName: "info.circle").font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .help(Text("Answer details"))
        .accessibilityLabel(Text("Answer details"))
        .onHover { presenter.hoverIcon(id, $0) }
        .popover(isPresented: Binding(get: { presenter.openID == id },
                                      set: { if !$0, presenter.openID == id { presenter.close() } }),
                 arrowEdge: .bottom) {
            AnswerDetailsView(stats: stats)
                .onHover { presenter.hoverPopover($0) }
        }
    }
}

/// How an answer was made: its model, speed, tokens and context.
@MainActor
struct AnswerDetailsView: View {
    let stats: AnswerStats

    var body: some View {
        let sections = stats.sections()
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 2) {
                    if section.kind != .date {
                        Text(Self.heading(section.kind))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                    }
                    if section.kind == .speed, stats.requestCount > 1 {
                        Text(String(format: NSLocalizedString("Rates and first token: the last of %lld requests.", comment: "answer details"),
                                    stats.requestCount))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                        rowView(row)
                    }
                    if section.kind == .context, let fraction = stats.contextFraction {
                        ContextBar(fraction: fraction)
                    }
                }
            }
            if sections.isEmpty {
                Text("No details for this answer.").font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                Button {
                    MediaSharing.copyText(stats.plainText(heading: Self.heading, label: Self.label))
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(Text("Copy the details as text"))
            }
        }
        .padding(10)
        .frame(width: 260, alignment: .leading)
    }

    @ViewBuilder
    private func rowView(_ row: AnswerStats.Row) -> some View {
        switch row.kind {
        case .date:
            Text(verbatim: row.value).font(.system(size: 10)).foregroundColor(.secondary)
        case .model:
            Text(verbatim: row.value).font(.system(size: 11, weight: .medium)).lineLimit(2).textSelection(.enabled)
        case .folder:
            Text(verbatim: row.value).font(.system(size: 10)).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        default:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.label(row.kind)).foregroundColor(.secondary)
                Spacer(minLength: 4)
                Text(verbatim: row.value).monospacedDigit().lineLimit(1).textSelection(.enabled)
            }
            .font(.system(size: 11))
        }
    }

    static func heading(_ kind: AnswerStats.SectionKind) -> String {
        switch kind {
        case .model: return NSLocalizedString("Model", comment: "answer details section")
        case .speed: return NSLocalizedString("Speed", comment: "answer details section")
        case .tokens: return NSLocalizedString("Tokens", comment: "answer details section")
        case .context: return NSLocalizedString("Context", comment: "answer details section")
        case .date: return ""
        }
    }

    static func label(_ kind: AnswerStats.RowKind) -> String {
        switch kind {
        case .model: return NSLocalizedString("Model", comment: "answer details section")
        case .folder: return NSLocalizedString("Folder", comment: "answer details: the model's folder")
        case .profile: return NSLocalizedString("Profile", comment: "answer details")
        case .generation: return NSLocalizedString("Generation", comment: "answer details: decoding speed")
        case .promptProcessing: return NSLocalizedString("Prompt processing", comment: "answer details: prefill speed")
        case .firstToken: return NSLocalizedString("First token", comment: "answer details: time to first token")
        case .totalTime: return NSLocalizedString("Total time", comment: "answer details")
        case .prompt: return NSLocalizedString("Prompt", comment: "answer details: prompt tokens")
        case .promptLast: return NSLocalizedString("Prompt (last request)", comment: "answer details: prompt tokens")
        case .cached: return NSLocalizedString("Cached", comment: "answer details: cached prompt tokens")
        case .answer: return NSLocalizedString("Answer", comment: "answer details: completion tokens")
        case .answerTotal: return NSLocalizedString("Answer (all requests)", comment: "answer details: completion tokens")
        case .reasoning: return NSLocalizedString("Reasoning", comment: "answer details: reasoning tokens")
        case .toolCalls: return NSLocalizedString("Tool calls", comment: "answer details")
        case .context: return NSLocalizedString("Used", comment: "answer details: context used")
        case .date: return NSLocalizedString("Date", comment: "answer details")
        }
    }
}

/// A thin bar: how full the model's context was.
private struct ContextBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.2))
                Capsule().fill(fraction > 0.9 ? Color.orange : Color.accentColor)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}
