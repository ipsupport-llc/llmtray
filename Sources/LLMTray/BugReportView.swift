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
    @State private var modelDetails: [(String, String)] = []
    /// Read once, when the form opens.
    @State private var crashes: [(name: String, text: String)] = []
    @State private var isWorking = false
    @State private var note: String?
    @FocusState private var descriptionFocused: Bool

    private var report: BugReport {
        BugReporter.report(options, server: server, runtimeVersions: runtimeVersions,
                           modelDetails: modelDetails, attachments: BugReporter.attachments(options, server: server))
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
                .disabled(!BugReporter.canAttachServerLog(server))
            if !server.log.isEmpty, !BugReporter.canAttachServerLog(server) {
                Text("Verbose server logging was on, so the log holds your chats: it isn't attached. To include it, turn verbose logging off in Settings › Server, restart the server and reproduce the problem.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Toggle("Include LLMTray crash reports from the last two weeks", isOn: $options.includeCrashReports)

            // Everything that goes: report.txt, and the log as attached.
            DisclosureGroup {
                ScrollView {
                    Text(report.text())
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 160, maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            } label: {
                Text("The report")
            }
            if options.includeServerLog, BugReporter.canAttachServerLog(server) {
                DisclosureGroup {
                    ScrollView {
                        Text(BugReporter.serverLogForReport(server))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                } label: {
                    Text("The server log")
                }
            }

            if options.includeCrashReports {
                if !crashes.isEmpty {
                    DisclosureGroup {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(crashes, id: \.name) { crash in
                                    Text(verbatim: crash.name).font(.caption.weight(.semibold))
                                    Text(verbatim: String(crash.text.prefix(20_000)))
                                        .font(.system(size: 10, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                        .frame(minHeight: 120, maxHeight: 220)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    } label: {
                        Text("Crash reports (\(crashes.count))")
                    }
                }
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
                    // Once the runtime versions are in.
                    .disabled(isWorking || runtimeVersions == "…")
            }
        }
        .padding(18)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440)
        .task {
            descriptionFocused = true
            crashes = BugReporter.crashReportsForReport()
            modelDetails = await BugReporter.modelDetails()
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
                BugReporter.compose(report, attachment: zip) {
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
