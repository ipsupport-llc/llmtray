import AppKit
import LLMTrayCore
import SwiftUI

/// A project's instructions (adr/0012), edited in a small window of their
/// own: the sidebar is also in the popover, and SwiftUI's sheets don't
/// present reliably from one (BenchmarkView). One window per project; asked
/// again, it comes to the front with what's typed in it.
@MainActor
enum ProjectInstructionsWindow {
    private static var windows: [UUID: NSWindow] = [:]

    /// Drops a window once it closes.
    private final class Delegate: NSObject, NSWindowDelegate {
        static let shared = Delegate()

        func windowWillClose(_ notification: Notification) {
            ProjectInstructionsWindow.windows = ProjectInstructionsWindow.windows.filter { $0.value !== notification.object as? NSWindow }
        }
    }

    /// Its project was deleted: nothing left to save the text to.
    static func close(_ projectID: UUID) {
        windows[projectID]?.close()
    }

    static func show(_ projectID: UUID) {
        guard let project = ChatLibraryStore.shared.library.project(projectID) else { return }
        if let window = windows[projectID] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = String(format: NSLocalizedString("Instructions for %@", comment: ""), project.name)
        window.isReleasedWhenClosed = false
        // Not in the saved window state: it's the user's text, not layout.
        window.isRestorable = false
        window.contentView = NSHostingView(rootView: ProjectInstructionsView(
            projectID: projectID, text: project.instructions, close: { [weak window] in window?.close() }
        ))
        window.center()
        window.delegate = Delegate.shared
        windows[projectID] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ProjectInstructionsView: View {
    let projectID: UUID
    @State private var text: String
    let close: () -> Void

    init(projectID: UUID, text: String, close: @escaping () -> Void) {
        self.projectID = projectID
        _text = State(initialValue: text)
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Every chat in this project gets these instructions, after the model profile's system prompt. A change applies from the next message.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                // ⌘Return: Return is a new line in the text.
                Button("Save") {
                    ChatLibraryStore.shared.setInstructions(projectID, text)
                    close()
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 260)
    }
}
