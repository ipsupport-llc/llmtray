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
        let window = CloseOnCommandWWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("LLMTray — Chat", comment: "")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName(Self.frameName)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static let frameName = "LLMTrayChatWindow"
    private static let minContentSize = NSSize(width: 420, height: 320)

    /// Shows `content` in the window, at the size and position it had on
    /// the previous detach (a default size the first time).
    func show(_ content: NSViewController) {
        guard let window else { return }
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(NSSize(width: 520, height: 640))
            window.center()
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

/// Closes on ⌘W. The app's only scene is `Settings`, so the main menu has
/// no File > Close to send the shortcut to -- without this the red button
/// was the only way to put the chat back in the menu bar.
private final class CloseOnCommandWWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The window's own content (a SwiftUI shortcut) goes first.
        if super.performKeyEquivalent(with: event) { return true }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "w" else { return false }
        performClose(nil)
        return true
    }
}
