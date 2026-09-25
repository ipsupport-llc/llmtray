import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted by the chat header: move the chat out of the popover into its
    /// own window (AppDelegate.detachChat).
    static let detachChat = Notification.Name("LLMTray.detachChat")
}

/// The window the chat lives in while detached. Closing it (red button,
/// ⌘W) hands the chat back to the popover via onClose.
@MainActor
final class ChatWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("LLMTray — Chat", comment: "")
        window.isReleasedWhenClosed = false
        // Chat content (temporary chats included: "nothing is ever saved")
        // stays out of macOS's saved window state.
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName(Self.frameName)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static let frameName = "LLMTrayChatWindow"
    // The sidebar (250) beside a usable chat, or the chat alone.
    private static let minContentSize = NSSize(width: 640, height: 360)

    /// Shows `content` in the window, at the size and position it had on
    /// the previous detach (a default size the first time).
    func show(_ content: NSViewController) {
        guard let window else { return }
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(NSSize(width: 860, height: 680))
            window.center()
        }
        // A frame saved before the sidebar (or the minimum) grew.
        let saved = window.contentRect(forFrameRect: window.frame).size
        if saved.width < Self.minContentSize.width || saved.height < Self.minContentSize.height {
            window.setContentSize(NSSize(width: max(saved.width, Self.minContentSize.width),
                                         height: max(saved.height, Self.minContentSize.height)))
            // constrainFrameRect only fixes the vertical: wider, it could
            // hang off the right edge.
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                var frame = window.constrainFrameRect(window.frame, to: window.screen ?? NSScreen.main)
                frame.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
                window.setFrame(frame, display: false)
            }
        }
        // Assigning a content controller resizes the window to its view's
        // size: sized to the window first, the saved frame stays.
        content.view.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        content.view.autoresizingMask = [.width, .height]
        window.contentViewController = content
        window.makeKeyAndOrderFront(nil)
    }

    /// Drops the chat view (the popover gets a fresh one).
    func removeContent() {
        window?.contentViewController = nil
    }

    /// The minimum size, enforced here rather than with contentMinSize: the
    /// hosting controller resets the window's min/max size itself.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minFrame = sender.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minContentSize)).size
        return NSSize(width: max(frameSize.width, minFrame.width), height: max(frameSize.height, minFrame.height))
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
