import AppKit
import Foundation
import LLMTrayCore

/// Folder access (adr/0014): the feature's switch, the one service over the
/// grants, pending plans and journal, and what Settings shows of them. Off
/// until turned on in Settings; off, no folder tool is declared.
@MainActor
final class FolderAccessManager: ObservableObject {
    static let shared = FolderAccessManager()

    @Published private(set) var isEnabled: Bool
    /// Standing grants, for Settings (refreshed on changes).
    @Published private(set) var standingGrants: [FolderGrant] = []
    /// The journal's newest plans, for Settings.
    @Published private(set) var journalRecords: [JournalRecord] = []
    /// What the launch's recovery found of interrupted plans.
    @Published private(set) var recoveries: [ChangeUndo.Recovery] = []
    /// A plan is being executed or undone somewhere: one at a time.
    @Published private(set) var isChanging = false
    /// Bumped whenever grants change: chat menus read them again.
    @Published private(set) var grantsRevision = 0

    let service: FolderToolService
    private var recovered = false

    private init() {
        isEnabled = UserDefaults.standard[Pref.folderToolsEnabled]
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let grants = FolderGrants(storeURL: base.appendingPathComponent("LLMTray/folder_grants.json"))
        service = FolderToolService(grants: grants, denylist: FolderDenylist.standard(),
                                    journal: ChangeJournal(directory: ChangeJournal.defaultDirectory))
    }

    /// At launch: interrupted plans put right, when the feature is on.
    func start() {
        guard isEnabled else { return }
        refresh()
        recover()
    }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        UserDefaults.standard[Pref.folderToolsEnabled] = on
        if on {
            start()
        } else {
            // Off means off: no plan waits for approval, no prompt for an answer.
            for chat in ChatTabs.shared.tabs { chat.folderAccessTurnedOff() }
        }
    }

    func refresh() {
        standingGrants = service.grants.standingGrants()
        grantsRevision += 1
        let journal = service.journal
        Task.detached {
            let records = journal.records(limit: 30)
            await MainActor.run { FolderAccessManager.shared.journalRecords = records }
        }
    }

    /// As the one change in progress: no approval or undo runs beside it.
    private func recover() {
        guard !recovered else { return }
        recovered = true
        let service = self.service
        Task {
            guard let found = await change({ service.recoverInterrupted() }) else {
                recovered = false   // something else ran: next time
                return
            }
            recoveries = found
        }
    }

    func revoke(_ grant: FolderGrant) throws {
        try service.grants.revoke(grant.id)
        refresh()
    }

    /// A folder the user picks in an open panel, checked for being
    /// grantable; the error says why not.
    func pickFolder(message: String) -> Result<FolderRoot, Error>? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = NSLocalizedString("Allow", comment: "open panel button: allow folder access")
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return .success(try service.makeRoot(url.path))
        } catch {
            return .failure(error)
        }
    }

    /// A grant the user starts (Settings, the chat's folder menu).
    func userGrant(_ root: FolderRoot, level: FolderAccessLevel, choice: GrantChoice, chat: FolderChat?) throws {
        try service.userGrant(root, level: level, choice: choice, chat: chat)
        refresh()
    }

    func endChat(_ chatID: String) {
        service.endChat(chatID)
        grantsRevision += 1
    }

    /// Runs `work` off the main thread as the one change in progress; nil
    /// when another is running.
    func change<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        guard !isChanging else { return nil }
        isChanging = true
        defer {
            isChanging = false
            refresh()
        }
        return await Task.detached { work() }.value
    }

    func undo(_ planID: UUID) async -> ChangeUndo.Report? {
        let service = self.service
        return await change { service.undo(planID) }
    }

    static func display(_ path: String) -> String { FolderToolText.display(path, home: NSHomeDirectory()) }

    /// An error as the user reads it: the known ones in their language.
    static func message(_ error: Error) -> String {
        switch error {
        case ChangePlanError.stale, ChangePlanError.notThePlanReviewed:
            return NSLocalizedString("The plan changed since you looked at it: review it again.", comment: "folder plan error")
        case ChangePlanError.nothingPending:
            return NSLocalizedString("There's no plan waiting any more.", comment: "folder plan error")
        case ChangePlanError.invalidated:
            return NSLocalizedString("Some items changed on disk since they were proposed: untick them, or ask again.", comment: "folder plan error")
        case ChangePlanError.missingDependency:
            return NSLocalizedString("An item needs the new folder it goes into: tick that folder too.", comment: "folder plan error")
        case FolderGrants.GrantError.temporaryChat, ChangePlanError.temporaryChat:
            return NSLocalizedString("Temporary chats can only look in folders, for that chat only.", comment: "folder grant error")
        case FolderAccessError.notGrantable, FolderAccessError.notFound, FolderAccessError.symlink:
            return NSLocalizedString("System and private places (the home folder itself, Library, Applications, keys) are never shared.", comment: "folder grant error")
        default:
            return "\(error)"
        }
    }

    /// A grant's lifetime, for Settings and the chat's menu.
    static func lifetimeText(_ grant: FolderGrant) -> String {
        switch grant.lifetime {
        case .once: return NSLocalizedString("this call only", comment: "folder grant lifetime")
        case .chat: return NSLocalizedString("for this chat", comment: "folder grant lifetime")
        case .always: return NSLocalizedString("always", comment: "folder grant lifetime")
        case .until(let date):
            return String(format: NSLocalizedString("until %@", comment: "folder grant lifetime: a time"),
                          date.formatted(date: .omitted, time: .shortened))
        }
    }

    static func levelText(_ level: FolderAccessLevel) -> String {
        level == .change ? NSLocalizedString("read and change", comment: "folder grant level")
            : NSLocalizedString("read", comment: "folder grant level")
    }
}

/// The inline card asking the user about a folder: a call waits for it
/// (like a Creator mode draft), Stop or another chat answers nil. The user
/// can also open one themselves (Allow Folder…): then nothing waits.
@MainActor
final class FolderAccessPrompt: ObservableObject, Identifiable {
    let id = UUID()
    let request: FolderGrantRequest
    let choices: [GrantChoice]
    /// The model's call asked (it waits); false: the user did.
    let forCall: Bool
    private var continuation: CheckedContinuation<GrantChoice?, Never>?
    /// The user's own grant: what the answer does.
    var onAnswer: ((GrantChoice) -> Void)?
    /// Any answer, Cancel included: the card goes (a user's own card).
    var onDone: (() -> Void)?
    @Published var error: String?

    init(request: FolderGrantRequest, choices: [GrantChoice], forCall: Bool) {
        self.request = request
        self.choices = choices
        self.forCall = forCall
    }

    func decide() async -> GrantChoice? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<GrantChoice?, Never>) in
                continuation = c
                if Task.isCancelled { resolve(nil) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(nil) }
        }
    }

    func resolve(_ choice: GrantChoice?) {
        error = nil
        if let choice { onAnswer?(choice) }
        continuation?.resume(returning: choice)
        continuation = nil
        // Not while its grant failed (the card says why); Cancel always closes it.
        if choice == nil || error == nil { onDone?() }
    }
}

/// The pending plan's card: review (ticks, warnings), running, the result
/// with Undo.
@MainActor
final class FolderPlanModel: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case review
        case running(done: Int, total: Int)
        case finished(PlanOutcome, planID: UUID)
        case undoing
        case undone(ChangeUndo.Report)
    }

    let id = UUID()
    let chatID: String
    @Published private(set) var review: PlanReview
    @Published private(set) var phase: Phase = .review
    /// Why the last approval was refused (stale, changed since...).
    @Published var message: String?
    @Published var expanded = false
    /// The run or its undo ended: a plan proposed meanwhile can show.
    var onSettled: (() -> Void)?
    private var service: FolderToolService { FolderAccessManager.shared.service }

    init(review: PlanReview, chatID: String) {
        self.review = review
        self.chatID = chatID
        checkItems()
    }

    var isReviewing: Bool { phase == .review }

    /// Running or undoing: the card stays until it's done.
    var isBusy: Bool {
        switch phase {
        case .running, .undoing: return true
        case .review, .finished, .undone: return false
        }
    }

    /// A newer revision of the pending plan (the model added to it).
    func update(_ plan: ChangePlan) {
        guard phase == .review else { return }
        review = PlanReview(plan: plan, previous: review, invalid: review.invalid)
        message = nil
        checkItems()
    }

    func set(_ item: Int, selected: Bool) { review.set(item, selected: selected) }
    func setAll(_ on: Bool) { review.setAll(on) }

    /// Which items no longer match: off the main thread.
    private func checkItems() {
        let plan = review.plan
        let service = self.service
        Task { [weak self] in
            let bad = await Task.detached { service.invalidItems(plan) }.value
            guard let self, self.review.plan.id == plan.id, self.review.plan.revision == plan.revision else { return }
            self.review.invalid = bad
        }
    }

    func cancel() {
        service.plans.cancel(chatID: chatID)
    }

    /// Approves the ticked items of the plan as reviewed, then runs them.
    func approve() {
        guard phase == .review, !review.approvable.isEmpty else { return }
        // Turned off in Settings meanwhile: nothing runs.
        guard FolderAccessManager.shared.isEnabled else {
            message = NSLocalizedString("Folder access is off in Settings.", comment: "")
            return
        }
        let review = self.review
        let service = self.service
        message = nil
        phase = .running(done: 0, total: review.approvable.count)
        // Held until the run ends (a weak capture here is refused by the
        // older compiler CI builds with).
        let progress: @Sendable (Int, Int) -> Void = { done, total in
            Task { @MainActor in
                if case .running = self.phase { self.phase = .running(done: done, total: total) }
            }
        }
        Task { [weak self] in
            let outcome: Result<(PlanOutcome, UUID), Error>? = await FolderAccessManager.shared.change {
                do {
                    let approved = try service.approve(review)
                    let report = service.execute(approved, progress: progress)
                    return .success((PlanOutcome(report), approved.plan.id))
                } catch {
                    return .failure(error)
                }
            }
            guard let self else { return }
            switch outcome {
            case nil:
                self.phase = .review
                self.message = NSLocalizedString("Another folder change is running: try again when it's done.", comment: "")
            case .failure(let error)?:
                self.phase = .review
                self.message = FolderAccessManager.message(error)
                if let plan = service.plans.pending(chatID: self.chatID) {
                    self.review = PlanReview(plan: plan, previous: self.review)
                    self.checkItems()
                }
            case .success(let (result, planID))?:
                self.phase = .finished(result, planID: planID)
                self.onSettled?()
            }
        }
    }

    func undo() {
        guard case .finished(let outcome, let planID) = phase else { return }
        phase = .undoing
        message = nil
        Task { [weak self] in
            let report = await FolderAccessManager.shared.undo(planID)
            guard let self else { return }
            if let report {
                self.phase = .undone(report)
                self.onSettled?()
            } else {
                self.phase = .finished(outcome, planID: planID)
                self.message = NSLocalizedString("Another folder change is running: try again when it's done.", comment: "")
            }
        }
    }

    // MARK: Wording

    /// "move 47 files into 6 folders, trash 3", in the user's language.
    static func summary(_ c: PlanReview.Counts) -> String {
        var parts: [String] = []
        if c.folders > 0 { parts.append(String(format: NSLocalizedString("make %lld folders", comment: "plan summary part"), c.folders)) }
        if c.moves > 0 {
            parts.append(String(format: c.movesAreFiles
                                ? NSLocalizedString("move %1$lld files into %2$lld folders", comment: "plan summary part")
                                : NSLocalizedString("move %1$lld items into %2$lld folders", comment: "plan summary part"),
                                c.moves, c.destinations))
        }
        if c.renames > 0 { parts.append(String(format: NSLocalizedString("rename %lld", comment: "plan summary part"), c.renames)) }
        if c.trashes > 0 { parts.append(String(format: NSLocalizedString("trash %lld", comment: "plan summary part"), c.trashes)) }
        return parts.isEmpty ? NSLocalizedString("no changes", comment: "plan summary") : parts.joined(separator: ", ")
    }

    static func describe(_ item: PlanItem) -> String {
        let from = item.source.map { FolderAccessManager.display($0.location.displayPath) } ?? ""
        let to = item.destination.map { FolderAccessManager.display($0.location.displayPath) } ?? ""
        switch item.kind {
        case .makeDir: return String(format: NSLocalizedString("New folder %@", comment: "plan item"), to)
        case .trash: return String(format: NSLocalizedString("Move %@ to the Trash", comment: "plan item"), from)
        case .move:
            if let s = item.source, let d = item.destination, s.location.parentComponents == d.location.parentComponents,
               s.location.root == d.location.root {
                return String(format: NSLocalizedString("Rename %1$@ to %2$@", comment: "plan item"), from, d.location.name)
            }
            return String(format: NSLocalizedString("Move %1$@ to %2$@", comment: "plan item"), from, to)
        }
    }

    static func warning(_ w: PlanReview.Warning) -> String {
        switch w {
        case .hardLink: return NSLocalizedString("Has other names (a hard link): they keep the file.", comment: "plan warning")
        case .fileProvider(let trash):
            return trash ? NSLocalizedString("In iCloud Drive or another cloud: moving it to the Trash removes it from your other devices too.", comment: "plan warning")
                : NSLocalizedString("Managed by iCloud Drive or another cloud provider.", comment: "plan warning")
        case .package: return NSLocalizedString("A package: moved as one item.", comment: "plan warning")
        case .symlink: return NSLocalizedString("A symbolic link: the link itself, not what it points to.", comment: "plan warning")
        case .alias: return NSLocalizedString("An alias: the alias itself, not what it points to.", comment: "plan warning")
        case .nameTaken: return NSLocalizedString("The name is taken there: this change will fail rather than overwrite.", comment: "plan warning")
        case .trashRestore: return NSLocalizedString("To put it back, use Undo in LLMTray: Finder's Put Back doesn't know its folder.", comment: "plan warning")
        }
    }
}

/// Runs a folder tool's synchronous work off the main thread; Stop (the
/// tool round's cancellation) reaches it through `isCancelled`.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return set }
    func cancel() { lock.lock(); set = true; lock.unlock() }
}

private func offMain(_ work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) async -> FolderToolAnswer) async -> FolderToolAnswer {
    let flag = CancelFlag()
    return await withTaskCancellationHandler {
        await Task.detached { await work { flag.isSet } }.value
    } onCancel: {
        flag.cancel()
    }
}

extension FolderToolAnswer {
    var toolResult: ToolResult {
        switch self {
        case .text(let t): return .text(t)
        case .refused(let t): return .refused(t)
        }
    }
}

/// `files` (adr/0014): looks in granted folders; asks for a grant when a
/// path has none. Declared while the feature is on and the request has room
/// for file text.
@MainActor
final class FilesTool: ChatTool {
    let name = FolderTools.filesName
    var schema: ToolSchema? { FolderTools.filesSchema }
    var definition: [String: Any] { FolderTools.filesDefinition }
    var folderAccess: FolderToolAccess { .read }

    func isOffered(_ settings: ChatSettings) -> Bool { settings.folders != nil }

    func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        guard let chat = context.settings.folders else {
            return .text("\(name) isn't available in this chat. Answer without it.")
        }
        let request = FolderTools.filesRequest(arguments)
        let budget = context.projectTextBytes ?? ProjectTextBudget.bytes(forTokens: ProjectTextBudget.hardCapTokens)
        guard budget >= ProjectTextBudget.bytes(forTokens: ProjectTextBudget.minimumTokens) else {
            return .text(ProjectTextBudget.noRoomText)
        }
        let service = FolderAccessManager.shared.service
        let ask = context.askFolderAccess ?? { _ in nil }
        let key = context.callKey
        let answer = await offMain { isCancelled in
            await service.files(request, chat: chat, callKey: key, byteBudget: budget, ask: ask, isCancelled: isCancelled)
        }
        return answer.toolResult
    }
}

/// `change_files` (adr/0014): adds to the chat's pending plan, never
/// executes. Declared in saved chats only, and not after file or folder text
/// in the turn.
@MainActor
final class ChangeFilesTool: ChatTool {
    let name = FolderTools.changeName
    var schema: ToolSchema? { FolderTools.changeSchema }
    var definition: [String: Any] { FolderTools.changeDefinition }
    var folderAccess: FolderToolAccess { .change }

    func isOffered(_ settings: ChatSettings) -> Bool { settings.folders.map { !$0.temporary } ?? false }

    func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        guard let chat = context.settings.folders, !chat.temporary else {
            return .text("\(name) isn't available in this chat: temporary chats can only look at files.")
        }
        let ops: [FolderTools.RawOp]
        switch FolderTools.changeOps(arguments) {
        case .failure(let error): return .text(error.message)
        case .success(let o): ops = o
        }
        let service = FolderAccessManager.shared.service
        let ask = context.askFolderAccess ?? { _ in nil }
        let key = context.callKey
        let answer = await offMain { isCancelled in
            await service.propose(ops, chat: chat, callKey: key, ask: ask, isCancelled: isCancelled)
        }
        return answer.toolResult
    }
}
