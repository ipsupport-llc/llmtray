import Combine
import Foundation
import LLMTrayCore

/// Where the chat is shown, and the chat state and reactions that have to
/// outlive the view showing it. The popover and the window each get their
/// own freshly built ContentView (a hosting controller that has once been
/// shown in an NSPopover can never be made resizable in a window, and moving
/// it froze resizing in the app's other windows too), so what used to be
/// view state lives here, owned by AppDelegate. Only one ContentView exists
/// at a time: its side effects must not run twice.
///
/// The reactions below can't live in ContentView either: a hosting
/// controller never shown yet (the popover's, right after re-attaching)
/// gets no onChange / onReceive at all, so a turn ending or a download
/// landing then would go unnoticed until the popover is opened.
@MainActor
final class ChatPresentation: ObservableObject {
    @Published var isDetached = false

    private let tabs: ChatTabs
    /// Per tab: its draft (survives a detach / attach and a tab switch) and
    /// its turn tracker.
    private var composers: [ObjectIdentifier: ComposerModel] = [:]
    private var trackers: [ObjectIdentifier: TurnTracker] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(tabs: ChatTabs) {
        self.tabs = tabs
        tabs.$tabs
            .sink { [weak self] in self?.syncTabs($0) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .modelsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.modelsDidChange($0) }
            .store(in: &cancellables)
    }

    /// The message being composed in that tab.
    func composer(for chat: ChatClient) -> ComposerModel {
        let key = ObjectIdentifier(chat)
        if let composer = composers[key] { return composer }
        let composer = ComposerModel()
        composers[key] = composer
        return composer
    }

    private func syncTabs(_ open: [ChatClient]) {
        let keys = Set(open.map(ObjectIdentifier.init))
        composers = composers.filter { keys.contains($0.key) }
        trackers = trackers.filter { keys.contains($0.key) }
        for chat in open where trackers[ObjectIdentifier(chat)] == nil {
            trackers[ObjectIdentifier(chat)] = TurnTracker(chat) { [weak self, weak chat] epoch in
                guard let self, let chat else { return }
                self.autoTitleIfNeeded(chat)
                self.autoCompactIfNeeded(chat, epoch: epoch)
            }
        }
    }

    /// A new chat's first answer: the model names the chat (ChatClient
    /// does it once per chat, and leaves a renamed one alone).
    private func autoTitleIfNeeded(_ chat: ChatClient) {
        guard UserDefaults.standard[Pref.autoTitleChats] else { return }
        let (port, alias) = requestTarget
        chat.generateTitleIfNeeded(port: port, modelAlias: alias)
    }

    /// Where requests made outside a view go: the selected model, by the
    /// name the proxy knows it by.
    private var requestTarget: (port: Int, modelAlias: String) {
        let defaults = UserDefaults.standard
        let modelID = defaults[Pref.selectedModelID]
        return (defaults[Pref.port], modelID.map(ModelCatalog.shared.requestName(for:)) ?? "default")
    }

    /// A Hugging Face download finished: jump to the model that just landed
    /// on disk (the catalog rescans on the same notification).
    private func modelsDidChange(_ notification: Notification) {
        guard let repoID = notification.object as? String else { return }
        let catalog = ModelCatalog.shared
        catalog.rescan()
        let downloaded = catalog.root + "/\(repoID)"
        if catalog.model(id: downloaded) != nil {
            UserDefaults.standard[Pref.selectedModelID] = downloaded
        }
    }

    private func autoCompactIfNeeded(_ chat: ChatClient, epoch: Int) {
        let threshold = UserDefaults.standard[Pref.autoCompactThreshold]
        guard threshold > 0, chat.messages.count > threshold else { return }
        Task {
            // Still that chat, still idle: the task runs later still.
            guard chat.conversationEpoch == epoch, !chat.isBusy else { return }
            await compact(chat)
        }
    }

    /// Compacts that tab's session with the selected model's settings --
    /// read here, not from a view, so it works with no chat on screen.
    func compact(_ chat: ChatClient) async {
        let defaults = UserDefaults.standard
        let modelID = defaults[Pref.selectedModelID]
        let (port, alias) = requestTarget
        await chat.compactSession(
            port: port,
            modelAlias: alias,
            settings: ChatSettings.forModel(
                modelID, supportsVision: modelID.map(ModelDiscovery.supportsVision(forModelPath:)) ?? false
            ),
            keepStart: defaults[Pref.compactKeepStart], keepEnd: defaults[Pref.compactKeepEnd]
        )
    }
}

/// "A turn just finished in the chat it started in", for one tab -- the one
/// reliable signal: send()/regenerate() don't await the turn.
///
/// Acted on a main-loop turn later: @Published emits in willSet, inside
/// ChatClient's own state changes -- opening another chat clears the busy
/// flags in cancel() before the epoch moves on, and a Stop clears them
/// before the cancelled tool calls get their results. Acting there compacted
/// the chat just opened, or checked the threshold against a history about
/// to grow. Each change carries the conversation it happened in, read as it
/// happens (read later, a tool round's busy again could belong to a chat
/// opened meanwhile), and its place in line: only the latest one acts (a
/// Stop mid tool round delivers idle, busy, idle at once -- both idles saw
/// idle).
@MainActor
private final class TurnTracker {
    private struct BusyChange {
        let busy: Bool
        let conversation: Int
        let number: Int
    }

    private weak var chat: ChatClient?
    private var turnConversation: Int?
    private var busyChanges = 0
    private var subscription: AnyCancellable?

    init(_ chat: ChatClient, turnEnded: @escaping (_ epoch: Int) -> Void) {
        self.chat = chat
        subscription = Publishers.CombineLatest3(chat.$isStreaming, chat.$isGeneratingImage, chat.$isRunningTools)
            .map { $0 || $1 || $2 }
            .removeDuplicates()
            .dropFirst()
            .map { [weak self, weak chat] busy -> BusyChange in
                self?.busyChanges += 1
                return BusyChange(busy: busy, conversation: chat?.conversationEpoch ?? -1, number: self?.busyChanges ?? 0)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self, let chat = self.chat else { return }
                if change.busy {
                    self.turnConversation = change.conversation
                } else if change.number == self.busyChanges, self.turnConversation == change.conversation,
                          change.conversation == chat.conversationEpoch,
                          !chat.isTurnInProgress {  // not a tool round's hand-off
                    turnEnded(change.conversation)
                }
            }
    }
}
