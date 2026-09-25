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
    /// The message being composed: survives a detach / attach.
    let composer = ComposerModel()

    private let chat: ChatClient
    /// The conversation the running turn belongs to (auto-compaction).
    private var turnConversation: Int?
    private var cancellables: Set<AnyCancellable> = []
    /// Busy changes seen so far (see init).
    private var busyChanges = 0

    init(chat: ChatClient) {
        self.chat = chat
        // Acted on a main-loop turn later: @Published emits in willSet,
        // inside ChatClient's own state changes -- opening another chat
        // clears the busy flags in cancel() before the epoch moves on, and a
        // Stop clears them before the cancelled tool calls get their results.
        // Acting there compacted the chat just opened, or checked the
        // threshold against a history about to grow. Each change carries the
        // conversation it happened in, read as it happens (read later, a
        // tool round's busy again could belong to a chat opened meanwhile),
        // and its place in line: only the latest one acts (a Stop mid tool
        // round delivers idle, busy, idle at once -- both idles saw idle).
        let chat = chat
        Publishers.CombineLatest3(chat.$isStreaming, chat.$isGeneratingImage, chat.$isRunningTools)
            .map { $0 || $1 || $2 }
            .removeDuplicates()
            .dropFirst()
            .map { [weak self] busy -> BusyChange in
                self?.busyChanges += 1
                return BusyChange(busy: busy, conversation: chat.conversationEpoch, number: self?.busyChanges ?? 0)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.turnInProgressChanged($0) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .modelsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.modelsDidChange($0) }
            .store(in: &cancellables)
    }

    /// The one reliable "a turn (streaming + tool calls) just finished"
    /// signal: send()/regenerate() don't await the turn. Only in the chat it
    /// started in: opening another one ends the turn too, and that one
    /// mustn't be compacted for it.
    private func turnInProgressChanged(_ change: BusyChange) {
        if change.busy {
            turnConversation = change.conversation
        } else if change.number == busyChanges, turnConversation == change.conversation,
                  change.conversation == chat.conversationEpoch,
                  !chat.isTurnInProgress {  // not a tool round's hand-off
            autoTitleIfNeeded()
            autoCompactIfNeeded(epoch: change.conversation)
        }
    }

    /// A new chat's first answer: the model names the chat (ChatClient
    /// does it once per chat, and leaves a renamed one alone).
    private func autoTitleIfNeeded() {
        guard UserDefaults.standard[Pref.autoTitleChats] else { return }
        let (port, alias) = requestTarget
        Task { await chat.generateTitleIfNeeded(port: port, modelAlias: alias) }
    }

    /// Where requests made outside a view go: the selected model, by the
    /// name the proxy knows it by.
    private var requestTarget: (port: Int, modelAlias: String) {
        let defaults = UserDefaults.standard
        let modelID = defaults[Pref.selectedModelID]
        return (defaults[Pref.port], modelID.map(ModelCatalog.shared.requestName(for:)) ?? "default")
    }

    private struct BusyChange {
        let busy: Bool
        let conversation: Int
        let number: Int
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

    private func autoCompactIfNeeded(epoch: Int) {
        let threshold = UserDefaults.standard[Pref.autoCompactThreshold]
        guard threshold > 0, chat.messages.count > threshold else { return }
        Task {
            // Still that chat, still idle: the task runs later still.
            guard chat.conversationEpoch == epoch, !chat.isBusy else { return }
            await compact()
        }
    }

    /// Compacts the current session with the selected model's settings --
    /// read here, not from a view, so it works with no chat on screen.
    func compact() async {
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
