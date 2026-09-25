import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted by the chat header: move the chat out of the popover into its
    /// own window (AppDelegate.detachChat).
    static let detachChat = Notification.Name("LLMTray.detachChat")
}

/// Where the chat is shown, and the chat state that has to outlive the view
/// showing it. The popover and the window each get their own freshly built
/// ContentView (a hosting controller that has once been shown in an
/// NSPopover can never be made resizable in a window, and moving it froze
/// resizing in the app's other windows too), so what used to be view state
/// -- the draft, the turn being compacted -- lives here, owned by
/// AppDelegate. Only one ContentView exists at a time: its side effects
/// (auto-compaction, model switching) must not run twice.
@MainActor
final class ChatPresentation: ObservableObject {
    @Published var isDetached = false
    /// The message being composed: survives a detach / attach.
    let composer = ComposerModel()
    /// The conversation the running turn belongs to (auto-compaction), so a
    /// turn still streaming when the chat moves is compacted when it ends.
    var turnConversation: Int?
}

/// The window the chat lives in while detached. Closing it (red button,
/// ⌘W) hands the chat back to the popover via onClose.
@MainActor
final class ChatWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LLMTray — Chat"
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
