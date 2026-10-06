import Combine
import Foundation
import LLMTrayCore
import SwiftUI

/// The chats open at once, one ChatClient each: a tab keeps streaming while
/// another is on screen. They share the app's one image generator and the
/// one server (the selected model -- a turn in each tab is just two
/// requests to it). The open saved chats come back after a relaunch.
@MainActor
final class ChatTabs: ObservableObject {
    static let shared = ChatTabs()

    @Published private(set) var tabs: [ChatClient] = []
    @Published private(set) var selectedIndex = 0
    /// Any tab is running a turn or compacting: operations that restart
    /// the server wait for all of them, not just the one on screen.
    @Published private(set) var isAnyBusy = false
    /// For the menu bar icon's pulse: any tab streaming / making an image.
    @Published private(set) var isAnyStreaming = false
    @Published private(set) var isAnyGeneratingMedia = false

    let mflux = MfluxManager()
    let music = MusicManager()
    /// Settings' image- and music-model downloads run on a client of their
    /// own (their progress is shown there), not on whichever tab is open.
    private(set) lazy var imageModels = ChatClient(mflux: mflux, music: music)
    /// `llmtray image` (ControlCommands, adr/0019) unloads the model for an
    /// image: the tabs' answers wait for it, as for another tab's.
    var isControlUnloadingModel = false
    private var busyWatch: AnyCancellable?
    /// Closed tabs still finishing something (see close).
    private var closing: [ChatClient] = []
    private var sessionWatch: AnyCancellable?

    var selected: ChatClient { tabs[selectedIndex] }

    /// The saved chats that were open come back, and a new chat is on
    /// screen -- every launch starts one, as it always has. An empty one
    /// that came back is that new chat (a project's, kept on disk as it was
    /// made, e.g. Getting Started's): not a second empty tab next to it.
    private init() {
        restore()
        if tabs.last.map({ $0.messages.isEmpty }) != true {
            tabs.append(makeClient())
        }
        selectedIndex = tabs.count - 1
        tabsChanged()
        // Into Getting Started while its card is shown, as any new chat --
        // after this init, which the project's lookups mustn't re-enter.
        DispatchQueue.main.async { [weak self] in self?.intoDefaultProject() }
    }

    // MARK: - Tabs

    /// New chat: in this tab, or in a new one if this tab is still busy
    /// (starting over here would stop its answer).
    func newChat() {
        if selected.isBusy { newTab() } else { selected.newSession() }
        intoDefaultProject()
    }

    /// A fresh install's first project takes new chats while its card is
    /// shown (GettingStarted): a tab's new chat (the selected one's by
    /// default) goes into it.
    func intoDefaultProject(_ chat: ChatClient? = nil) {
        if let project = GettingStarted.defaultProjectForNewChats, let id = (chat ?? selected).currentSessionID,
           ChatLibraryStore.shared.library.projectContext(forChat: id) == nil {
            ChatLibraryStore.shared.move(id, to: project)
        }
    }

    /// A new chat already in `project`: its id is mapped as it's made, in
    /// the same main-actor turn, so its first message knows its project
    /// (adr/0012). A temporary chat is never in one.
    func newChat(inProject project: UUID) {
        guard ChatLibraryStore.shared.library.project(project) != nil else { return }
        newChat()
        guard let id = selected.currentSessionID else { return }
        ChatLibraryStore.shared.move(id, to: project)
    }

    /// The same for a temporary chat.
    func newTemporaryChat() {
        if selected.isBusy { newTab() }
        selected.newTemporaryChat()
    }

    /// A new tab with a new chat, selected.
    func newTab() {
        tabs.append(makeClient())
        selectedIndex = tabs.count - 1
        tabsChanged()
        intoDefaultProject()
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
    }

    func selectNext(_ step: Int) {
        guard tabs.count > 1 else { return }
        select((selectedIndex + step + tabs.count) % tabs.count)
    }

    /// Stops its turn and saves it. The last tab isn't closed: it becomes
    /// a new chat (there's always one on screen).
    func close(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        guard tabs.count > 1 else {
            tabs[index].cancel()
            tabs[index].newSession()
            tabsChanged()
            intoDefaultProject()
            return
        }
        let closed = tabs[index]
        AudioPlayback.shared.stop(ifAnyOf: closed.messages)
        closed.close()
        // Still reloading the model after an image, say: counted as busy
        // until it's done, so nothing restarts the server under it.
        if closed.isBusy { closing.append(closed) }
        tabs.remove(at: index)
        if selectedIndex >= index, selectedIndex > 0 { selectedIndex -= 1 }
        tabsChanged()
    }

    /// The tab showing that chat, if one is.
    func index(of sessionID: UUID) -> Int? {
        tabs.firstIndex { $0.currentSessionID == sessionID }
    }

    /// A saved chat: its tab if it's open already, else in a new tab or in
    /// the one on screen.
    func open(_ sessionID: UUID, inNewTab: Bool) {
        if let index = index(of: sessionID) {
            select(index)
            return
        }
        guard let file = ChatSessionStore.load(id: sessionID) else { return }
        // The tab on screen is answering: opening over it would stop that.
        if inNewTab || selected.isBusy {
            let client = makeClient()
            client.loadSession(file)
            tabs.append(client)
            selectedIndex = tabs.count - 1
            tabsChanged()
        } else {
            selected.loadSession(file)
        }
    }

    /// Everything unsaved, before quitting.
    func saveAll() {
        tabs.forEach { $0.saveNow() }
        // A chat first saved just now is reopened too (remember() otherwise
        // runs a main-loop turn after the save, and there's none left).
        remember()
    }

    // MARK: -

    private func makeClient() -> ChatClient {
        let client = ChatClient(mflux: mflux, music: music)
        client.isAnotherChatUnloadingModel = { [weak self, weak client] in
            guard let self, let client else { return false }
            return self.isControlUnloadingModel
                || (self.tabs + self.closing).contains { $0 !== client && $0.isUnloadingModelForMedia }
        }
        return client
    }

    private func tabsChanged() {
        busyWatch = Publishers.MergeMany((tabs + closing).map { tab in
            tab.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        })
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.updateBusy() }
        updateBusy()
        // A chat switched or saved in a tab: the open tabs to restore.
        sessionWatch = Publishers.Merge(
            Publishers.MergeMany(tabs.map { $0.$currentSessionID.map { _ in () }.eraseToAnyPublisher() }),
            // A new chat's first save gives it a file to reopen.
            NotificationCenter.default.publisher(for: .sessionsDidChange).map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.remember() }
        remember()
    }

    private func updateBusy() {
        if closing.contains(where: { !$0.isBusy }) {
            closing.removeAll { !$0.isBusy }
            tabsChanged()   // resubscribes without them
            return
        }
        let busy = tabs.contains { $0.isBusy } || !closing.isEmpty
        if busy != isAnyBusy { isAnyBusy = busy }
        let streaming = (tabs + closing).contains { $0.isStreaming }
        if streaming != isAnyStreaming { isAnyStreaming = streaming }
        let generating = (tabs + closing).contains { $0.isGeneratingMedia }
        if generating != isAnyGeneratingMedia { isAnyGeneratingMedia = generating }
    }

    /// The saved chats open in tabs. A temporary one isn't kept, nor a new
    /// one with nothing in it yet (no file to reopen).
    private func remember() {
        UserDefaults.standard[Pref.openChatTabs] = tabs.compactMap { tab in
            tab.currentSessionID.flatMap { ChatSessionStore.exists($0) ? $0.uuidString : nil }
        }
    }

    private func restore() {
        for id in UserDefaults.standard[Pref.openChatTabs].compactMap(UUID.init(uuidString:)) {
            guard let file = ChatSessionStore.load(id: id) else { continue }
            let client = makeClient()
            client.loadSession(file)
            tabs.append(client)
        }
    }
}

/// The chat of the tab on screen, rebuilt when the tab changes: its draft
/// and state are that tab's; it opens at the latest message.
struct ChatRoot: View {
    @ObservedObject private var tabs = ChatTabs.shared
    @EnvironmentObject private var presentation: ChatPresentation

    var body: some View {
        let chat = tabs.selected
        ContentView()
            .environmentObject(chat)
            .environmentObject(presentation.composer(for: chat))
            .id(chat.tabID)
    }
}

/// The tray's controls while the chat has its own window, for the tab on
/// screen.
struct TrayRoot: View {
    @ObservedObject private var tabs = ChatTabs.shared

    var body: some View {
        TrayControlsView().environmentObject(tabs.selected)
    }
}

/// The chat window's tabs: one pill per tab (its chat's title, a spinner
/// while it answers), and + for a new one.
struct ChatTabStrip: View {
    @ObservedObject private var tabs = ChatTabs.shared

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(tabs.tabs.enumerated()), id: \.element.tabID) { index, chat in
                            TabPill(chat: chat, isSelected: index == tabs.selectedIndex,
                                    select: { tabs.select(index) }, close: { tabs.close(index) })
                                .id(chat.tabID)
                        }
                    }
                }
                .onChange(of: tabs.selectedIndex) { _, index in
                    guard tabs.tabs.indices.contains(index) else { return }
                    withAnimation { proxy.scrollTo(tabs.tabs[index].tabID) }
                }
            }
            Button { tabs.newTab() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .help("New Tab (⌘T)")
                .accessibilityLabel("New Tab")
        }
    }

    private struct TabPill: View {
        @ObservedObject var chat: ChatClient
        let isSelected: Bool
        let select: () -> Void
        let close: () -> Void
        @State private var hovered = false
        @ObservedObject private var store = ChatLibraryStore.shared

        /// The project the chat is in: a folder on the pill, its name on
        /// hover (two "New chat" tabs otherwise look the same).
        private var project: String? {
            chat.currentSessionID.flatMap { store.library.projectContext(forChat: $0)?.name }
        }

        var body: some View {
            HStack(spacing: 5) {
                if chat.isBusy {
                    ProgressView().controlSize(.mini)
                } else if chat.currentSessionID == nil {
                    Image(systemName: "eye.slash").font(.caption2)
                } else if project != nil {
                    Image(systemName: "folder").font(.caption2)
                }
                Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 160, alignment: .leading)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain)
                    .opacity(hovered || isSelected ? 1 : 0)
                    .help("Close Tab")
                    .accessibilityLabel("Close Tab")
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundColor(isSelected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(
                isSelected ? Color.primary.opacity(0.10) : Color.primary.opacity(hovered ? 0.05 : 0)
            ))
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .onHover { hovered = $0 }
            .help(project.map { String(format: NSLocalizedString("%@ — in project %@", comment: "a tab's tooltip: chat title, project name"), title, $0) } ?? title)
        }

        private var title: String {
            if chat.currentSessionID == nil { return NSLocalizedString("Temporary chat", comment: "") }
            return chat.currentSessionTitle.isEmpty ? NSLocalizedString("New chat", comment: "") : chat.currentSessionTitle
        }
    }
}
