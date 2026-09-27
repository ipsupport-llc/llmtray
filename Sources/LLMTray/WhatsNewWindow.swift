import AppKit
import LLMTrayCore
import SwiftUI

extension Notification.Name {
    /// Opens the What's New window (AppDelegate).
    static let showWhatsNew = Notification.Name("LLMTray.showWhatsNew")
}

/// The latest release's notes (WhatsNew.latest): by itself once per minor
/// version (WhatsNew.launchAction), and from the menus any time.
@MainActor
enum WhatsNewWindow {
    private static var window: NSWindow?

    static func show() {
        let release = WhatsNew.latest
        UserDefaults.standard[Pref.whatsNewLastSeen] = release.version
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = NSLocalizedString("What's New", comment: "what's new window title")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = NSHostingView(rootView: WhatsNewView(release: release) { [weak window] in window?.close() })
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct WhatsNewView: View {
    let release: WhatsNew.Release
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(format: NSLocalizedString("What's New in LLMTray %@", comment: "what's new heading"), release.version))
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                ForEach(release.items, id: \.title) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: item.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.title).fontWeight(.semibold)
                            Text(verbatim: item.text)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Continue", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
