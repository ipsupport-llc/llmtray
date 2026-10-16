import LLMTrayCore
import SwiftUI

/// An MCP call waiting for the user's answer (adr/0027).
@MainActor
final class MCPCallPrompt: ObservableObject, Identifiable {
    let id = UUID()
    let request: MCPCallRequest
    private var continuation: CheckedContinuation<MCPCallChoice?, Never>?

    init(request: MCPCallRequest) {
        self.request = request
    }

    func decide() async -> MCPCallChoice? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<MCPCallChoice?, Never>) in
                continuation = c
                if Task.isCancelled { resolve(nil) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(nil) }
        }
    }

    func resolve(_ choice: MCPCallChoice?) {
        continuation?.resume(returning: choice)
        continuation = nil
    }
}

/// The card: which server and tool, the arguments in full, Allow / Allow
/// for This Chat / Deny. No Return shortcut: Allow is clicked.
struct MCPCallCard: View {
    @ObservedObject var prompt: MCPCallPrompt
    @State private var showAll = false

    private var request: MCPCallRequest { prompt.request }
    private var lines: [Substring] { request.arguments.split(separator: "\n", omittingEmptySubsequences: false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.server.name, systemImage: "puzzlepiece.extension")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
            Text(title).font(.callout.weight(.medium))
            if request.allowedButAsked {
                Label(!request.chatAllowanceUsable
                      ? "Asked although you allowed it: the server didn't answer when its tools were checked just now (see its log in Settings › Tools)."
                      : "Asked although you allowed it: this turn has read mail, files or the web, and this call can change things or goes to the web.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundColor(.secondary)
            }
            if request.afterOutsideText && !request.allowancesHold {
                Label("Proposed right after reading outside text (mail, files, web) -- check it.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundColor(.orange)
            }
            ScrollView {
                Text(showAll || lines.count <= 14 ? request.arguments : lines.prefix(14).joined(separator: "\n") + "\n…")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: showAll ? 320 : 220)
            .padding(6)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            if lines.count > 14 {
                Button(showAll ? "Show Less" : "Show All \(lines.count) Lines") { showAll.toggle() }
                    .buttonStyle(.link).font(.subheadline)
            }
            Text("The server may do more than these arguments show (a mail reply's recipients and quoted text come from Mail).")
                .font(.caption).foregroundColor(.secondary)
            HStack(spacing: 6) {
                Button("Allow") { prompt.resolve(.allowOnce) }
                if request.allowancesHold {
                    Button(request.action.map { String(format: NSLocalizedString("Always Allow %@", comment: "MCP card: an action"), $0.replacingOccurrences(of: "_", with: " ")) }
                           ?? NSLocalizedString("Always Allow", comment: "MCP card")) { prompt.resolve(.allowAlways) }
                    Menu {
                        Button("Allow for This Chat") { prompt.resolve(.allowForChat) }
                        Button(String(format: NSLocalizedString("Always Allow Everything from %@", comment: "MCP card: a server"), request.server.name)) {
                            prompt.resolve(.allowServerAlways)
                        }
                    } label: {
                        Text("More")
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Deny") { prompt.resolve(.deny) }
            }
            .font(.subheadline)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var title: String {
        let tool = request.tool.title ?? request.tool.name
        if let action = request.action {
            return String(format: NSLocalizedString("Let the chat run %1$@ (%2$@)?", comment: "MCP call card: tool, action"), tool, action)
        }
        return String(format: NSLocalizedString("Let the chat run %@?", comment: "MCP call card: tool"), tool)
    }
}

/// The lines under an answer: each MCP call, its server, tool and outcome;
/// the arguments on click.
struct MCPCallLines: View {
    let records: [MCPCallRecord]
    @State private var open: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(records.enumerated()), id: \.offset) { i, record in
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        open = open == i ? nil : i
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: Self.symbol(record.outcome)).foregroundColor(Self.color(record.outcome))
                            Text("\(record.server): \(record.tool)\(record.action.map { " · \($0)" } ?? "") -- \(Self.word(record.outcome))")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    if open == i {
                        Text(record.arguments)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .padding(.leading, 18)
                    }
                }
            }
        }
    }

    static func word(_ outcome: MCPCallRecord.Outcome) -> String {
        switch outcome {
        case .done: return NSLocalizedString("done", comment: "MCP call outcome")
        case .failed: return NSLocalizedString("failed", comment: "MCP call outcome")
        case .unknown: return NSLocalizedString("outcome unknown -- check before trying again", comment: "MCP call outcome")
        case .denied: return NSLocalizedString("not allowed", comment: "MCP call outcome")
        case .notSent: return NSLocalizedString("not sent", comment: "MCP call outcome")
        }
    }

    static func symbol(_ outcome: MCPCallRecord.Outcome) -> String {
        switch outcome {
        case .done: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .unknown: return "questionmark.circle"
        case .denied: return "hand.raised"
        case .notSent: return "minus.circle"
        }
    }

    static func color(_ outcome: MCPCallRecord.Outcome) -> Color {
        switch outcome {
        case .done: return .green
        case .failed, .unknown: return .orange
        case .denied, .notSent: return .secondary
        }
    }
}
