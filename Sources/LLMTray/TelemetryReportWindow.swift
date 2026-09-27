import AppKit
import LLMTrayCore
import SwiftUI

/// The telemetry reports as the server gets them: the ones still to go
/// (built now from this Mac's counters) and the last one it stored. A
/// window of its own: Settings can open it, and the JSON wants room.
@MainActor
enum TelemetryReportWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.contentView = NSHostingView(rootView: TelemetryReportView())
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = NSLocalizedString("Usage statistics: the reports", comment: "telemetry window title")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = NSHostingView(rootView: TelemetryReportView())
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct TelemetryReportView: View {
    @ObservedObject private var telemetry = UsageTelemetry.shared
    @State private var reports: [(day: String, pending: Bool, json: String)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(telemetry.isEnabled
                     ? "Exactly what LLMTray sends to ipsupport.us, field for field. Nothing else leaves your Mac."
                     : "Usage statistics are off: nothing is sent. This is what a report would look like if you turned them on (the ID is made then).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(reports, id: \.day) { report in
                    block(title: report.pending
                          ? String(format: NSLocalizedString("Waiting to be sent: %@", comment: "telemetry report for a day"), report.day)
                          : String(format: NSLocalizedString("Today so far: %@ (sent once the day is over)", comment: "telemetry report for today"), report.day),
                          json: report.json)
                }
                if let json = telemetry.lastSentJSON, let day = telemetry.lastSentDay {
                    block(title: String(format: NSLocalizedString("Last sent: %@", comment: "telemetry report sent"), day), json: json)
                } else if telemetry.isEnabled {
                    Text("Nothing sent yet.").font(.callout).foregroundStyle(.secondary)
                }
                Text("The server also notes the approximate country from the connection; LLMTray doesn't send it and can't set it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 460, minHeight: 360)
        .onAppear { reports = telemetry.previewReports() }
        // Turned off, on, or a new ID while open: not the old previews.
        .onChange(of: telemetry.installID) { reports = telemetry.previewReports() }
        .onChange(of: telemetry.isEnabled) { reports = telemetry.previewReports() }
    }

    private func block(title: String, json: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: title).font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(json, forType: .string)
                }
            }
            Text(verbatim: json)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
