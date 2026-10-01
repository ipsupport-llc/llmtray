import AppKit
import LLMTrayCore
import SwiftUI

/// What an empty chat shows: in a project's, the drop zone for its files;
/// elsewhere a few tiles of what LLMTray does. Gone with the first message.
struct EmptyChatIntro: View {
    let sessionID: UUID?
    let selectedModelID: String?
    let port: Int
    /// Puts a sample prompt in the composer (not sent).
    let insertPrompt: (String) -> Void
    /// Something is dragged over the chat: the drop zone lights up (the
    /// chat takes the drop -- a vision model's images to the message,
    /// other files to the project).
    let dropTargeted: Bool
    @ObservedObject private var store = ChatLibraryStore.shared

    var body: some View {
        if let sessionID, store.library.projectContext(forChat: sessionID) != nil {
            ProjectChatDropZone(sessionID: sessionID, dropTargeted: dropTargeted)
        } else {
            EmptyChatShowcase(selectedModelID: selectedModelID, port: port, insertPrompt: insertPrompt)
        }
    }
}

/// Tiles of what LLMTray can do, each one doing it: a sample prompt, the
/// feature's window, the API's address copied. A feature that's off (they
/// all are until turned on, adr/0013) leads to its place in Settings --
/// nothing is turned on or downloaded from here.
private struct EmptyChatShowcase: View {
    let selectedModelID: String?
    let port: Int
    let insertPrompt: (String) -> Void
    @ObservedObject private var profiles = ProfileManager.shared
    @ObservedObject private var indexer = ProjectIndexer.shared
    @ObservedObject private var voice = VoiceModelStore.shared
    @State private var copied = false
    @State private var copiedReset: Task<Void, Never>?

    private var apiURL: String { "http://localhost:\(port)/v1" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                BrainMark(size: 16)
                Text("Ask anything, or try one of these:").font(.system(size: 12)).foregroundColor(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
                filesTile
                imageTile
                musicTile
                voiceTile
                apiTile
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - tiles

    private var filesTile: some View {
        let on = indexer.isEnabled
        return ShowcaseTile(symbol: "doc.text.magnifyingglass", title: Text("Your files"),
                            detail: on ? Text("Chat with the files of a project") : offDetail, isOn: on) {
            guard on else { return openFilesSettings() }
            // A new project and a chat in it: its drop zone takes the files.
            if let project = ChatLibraryStore.shared.addNewProject() { ChatTabs.shared.newChat(inProject: project.id) }
        }
    }

    private var imageTile: some View {
        let on = profiles.value(\.tools.enableImageGeneration, for: selectedModelID)
        return ShowcaseTile(symbol: "photo", title: Text("Images"),
                            detail: on ? Text("Describe a picture, drawn on this Mac") : offDetail, isOn: on) {
            guard on else { return openProfileSettings() }
            insertPrompt(NSLocalizedString("Generate an image: a lighthouse at dawn, in watercolor", comment: "a sample prompt of the empty chat's image tile"))
        }
    }

    private var musicTile: some View {
        let on = profiles.value(\.tools.enableMusicGeneration, for: selectedModelID)
        return ShowcaseTile(symbol: "music.note", title: Text("Music"),
                            detail: on ? Text("A song from a description") : offDetail, isOn: on) {
            guard on else { return openProfileSettings() }
            insertPrompt(NSLocalizedString("Make a 30-second calm lo-fi instrumental for studying", comment: "a sample prompt of the empty chat's music tile"))
        }
    }

    private var voiceTile: some View {
        // Voice Lab is in the menu only once it's on and its model is here.
        let on = voice.isEnabled && voice.isDownloaded(voice.selected)
        return ShowcaseTile(symbol: "waveform", title: Text("Voice"),
                            detail: on ? Text("Talk with the model in Voice Lab") : offDetail, isOn: on) {
            if on {
                NotificationCenter.default.post(name: .showVoiceLab, object: nil)
            } else {
                NotificationCenter.default.post(name: .showSettings, object: nil, userInfo: ["pane": SettingsPane.voice.rawValue])
            }
        }
    }

    private var apiTile: some View {
        ShowcaseTile(symbol: "chevron.left.forwardslash.chevron.right", title: Text("Coding agents"),
                     detail: copied ? Text("Copied") : Text(verbatim: apiURL), isOn: true) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(apiURL, forType: .string)
            copied = true
            copiedReset?.cancel()
            copiedReset = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { copied = false }
            }
        }
        .help(Text("OpenAI-compatible: point a coding agent or app at this address (copies it)"))
    }

    private var offDetail: Text { Text("Off · turn on in Settings") }

    /// Image and music generation are profile settings: the selected model's.
    private func openProfileSettings() {
        NotificationCenter.default.post(name: .showSettings, object: nil, userInfo: [
            "pane": SettingsPane.profiles.rawValue, "profileID": profiles.profile(for: selectedModelID).id,
        ])
    }
}

/// One tile: a symbol, a title and a line under it; a feature that's off is dimmed.
private struct ShowcaseTile: View {
    let symbol: String
    let title: Text
    let detail: Text
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: symbol).foregroundColor(isOn ? .accentColor : .secondary).frame(width: 16)
                    title.font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                }
                detail.font(.system(size: 10)).foregroundColor(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(hovering ? 0.16 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
