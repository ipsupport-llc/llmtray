import AppKit
import LLMTrayCore
import SwiftUI

extension Notification.Name {
    /// Opens the bug report window (Help menu, the quick menu, Settings,
    /// About).
    static let showBugReport = Notification.Name("LLMTray.showBugReport")
}

/// What happened, what goes into the report (shown in full), and Create
/// Email: the system's mail with the report attached, to support.
struct BugReportView: View {
    @EnvironmentObject var server: ServerManager
    @State private var options = BugReporter.Options()
    @State private var runtimeVersions = "…"
    @State private var isWorking = false
    @State private var note: String?
    @FocusState private var descriptionFocused: Bool

    private var report: BugReport {
        BugReporter.report(options, server: server, runtimeVersions: runtimeVersions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What happened?").font(.headline)
            TextEditor(text: $options.description)
                .font(.system(size: 13))
                .frame(minHeight: 90)
                .focused($descriptionFocused)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            Text("What you were doing, what you expected, what you saw instead. Your chats are never included.")
                .font(.caption).foregroundColor(.secondary)

            Toggle("Include the server log", isOn: $options.includeServerLog)
            Toggle("Include LLMTray crash reports from the last two weeks", isOn: $options.includeCrashReports)

            DisclosureGroup("The report") {
                ScrollView {
                    Text(report.text())
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 160, maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }

            if let note {
                Text(note).font(.callout).foregroundColor(.secondary)
            }

            HStack {
                Text(verbatim: BugReporter.address).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                Spacer()
                Button("Show in Finder") { Task { await make(send: false) } }
                    .disabled(isWorking)
                Button("Create Email…") { Task { await make(send: true) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
        }
        .padding(18)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440)
        .task {
            descriptionFocused = true
            runtimeVersions = await BugReporter.runtimeVersions()
        }
    }

    private func make(send: Bool) async {
        isWorking = true
        defer { isWorking = false }
        note = nil
        do {
            let report = report
            let zip = try await BugReporter.package(report, options: options, server: server)
            if send {
                if !BugReporter.compose(report, attachment: zip) {
                    note = NSLocalizedString("Your mail app couldn't take the attachment: the report is shown in Finder, attach it to the email.", comment: "")
                }
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([zip])
            }
        } catch {
            note = String(format: NSLocalizedString("Couldn't create the report: %@", comment: ""), error.localizedDescription)
        }
    }
}
