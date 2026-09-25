import AppKit
import SwiftUI

/// What a chat image (generated, or an attachment) can do: open full-size,
/// save, copy. Nothing here writes to disk except an explicit Save.
@MainActor
enum ImageActions {
    /// Retained here, not in a view: a preview outlives the popover that
    /// opened it.
    private static var previewWindows: [NSWindow] = []

    /// Drops a preview window once it closes. A delegate rather than a
    /// block observer that removes itself: that one captured its own
    /// non-Sendable token in a @Sendable closure.
    private final class PreviewWindowDelegate: NSObject, NSWindowDelegate {
        static let shared = PreviewWindowDelegate()

        func windowWillClose(_ notification: Notification) {
            ImageActions.previewWindows.removeAll { $0 === notification.object as? NSWindow }
        }
    }

    /// A full-size, resizable preview window, entirely in memory.
    static func openPreview(_ data: Data, title: String) {
        guard let nsImage = NSImage(data: data) else { return }
        let screenSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let maxSize = NSSize(width: screenSize.width * 0.9, height: screenSize.height * 0.9)
        let scale = min(1, min(maxSize.width / nsImage.size.width, maxSize.height / nsImage.size.height))
        let windowSize = NSSize(width: nsImage.size.width * scale, height: nsImage.size.height * scale)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = title
        window.contentView = NSHostingView(
            rootView: Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fit)
        )
        window.center()
        window.isReleasedWhenClosed = false
        // Not in the saved window state: its title is the prompt (a
        // temporary chat's included), and it's content, not layout.
        window.isRestorable = false
        previewWindows.append(window)
        // Released once closed (each holds its decoded image).
        window.delegate = PreviewWindowDelegate.shared
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The one deliberate way an image reaches disk; the filename comes
    /// from the prompt that made it.
    static func save(_ data: Data, prompt: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = slugify(prompt) + ".png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    static func copy(_ data: Data) {
        guard let nsImage = NSImage(data: data) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }

    static func slugify(_ text: String) -> String {
        let slug = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(slug).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let trimmed = String(collapsed.prefix(48))
        return trimmed.isEmpty ? "image" : trimmed
    }
}

extension View {
    /// Pointing-hand cursor while hovered.
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursor())
    }
}

/// Balances its own push on disappear: a view removed while hovered (an
/// attachment's remove button sits on top of it; a chat image scrolled
/// away) never gets the hover-exit, so a bare push/pop in onHover left the
/// cursor stuck as a hand.
private struct PointingHandCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if !hovering, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}
