import AppKit
import LLMTrayCore
import SwiftUI

// The folder tools' UI (adr/0014): the grant prompt and the plan review as
// cards in the chat, the chat's folder menu, Settings > Folders.

/// "Allow the chat to read ~/Downloads?" with the lifetimes; a call waits
/// for the answer.
struct FolderPromptCard: View {
    @ObservedObject var prompt: FolderAccessPrompt

    private var path: String { FolderAccessManager.display(prompt.request.root.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(prompt.request.level == .change ? LocalizedStringKey("Folder changes") : LocalizedStringKey("Folder access"),
                  systemImage: prompt.request.level == .change ? "folder.badge.gearshape" : "folder")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            if prompt.request.level == .change {
                Text("Let the chat propose changes in \(path)?")
                    .font(.system(size: 12, weight: .medium))
                Text("Making folders, moving, renaming and moving to the Trash -- each plan is shown to you first, and nothing changes until you approve it.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                Text("Let the chat look in \(path)?")
                    .font(.system(size: 12, weight: .medium))
                Text("Names, sizes and dates, and short excerpts of files it asks about. Private places inside (keys, Library) stay hidden.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            if let error = prompt.error {
                Text(error).font(.system(size: 11)).foregroundColor(.red)
            }
            HStack(spacing: 6) {
                ForEach(prompt.choices.filter { $0 != .deny }, id: \.self) { choice in
                    Button { prompt.resolve(choice) } label: { Self.title(choice) }
                }
                Spacer()
                if prompt.choices.contains(.deny) {
                    Button("Deny") { prompt.resolve(.deny) }
                } else {
                    Button("Cancel") { prompt.resolve(nil) }
                }
            }
            .font(.system(size: 11))
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: 560, alignment: .leading)
    }

    static func title(_ choice: GrantChoice) -> Text {
        switch choice {
        case .once: return Text("Allow Once")
        case .hour: return Text("For an Hour")
        case .chat: return Text("For This Chat")
        case .always: return Text("Always")
        case .deny: return Text("Deny")
        }
    }
}

/// The pending plan: its summary, the items with ticks and warnings,
/// Approve / Cancel; then its progress, its result and Undo.
struct FolderPlanCard: View {
    @ObservedObject var model: FolderPlanModel
    @ObservedObject private var manager = FolderAccessManager.shared
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Folder changes", systemImage: "folder.badge.gearshape")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            switch model.phase {
            case .review: review
            case .running(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text(String(format: NSLocalizedString("Changing files: %1$lld of %2$lld…", comment: ""), done, total))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            case .finished(let outcome, _): finished(outcome)
            case .undoing:
                ProgressView().controlSize(.small)
                Text("Undoing…").font(.system(size: 11)).foregroundColor(.secondary)
            case .undone(let report): undone(report)
            }
            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundColor(.red)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder
    private var review: some View {
        let r = model.review
        Text(FolderPlanModel.summary(r.counts).capitalizedFirst)
            .font(.system(size: 12, weight: .medium))
        let warned = r.items.filter { !PlanReview.warnings($0).filter { $0 != .trashRestore }.isEmpty || r.invalid[$0.id] != nil }.count
        if warned > 0 {
            Text(String(format: NSLocalizedString("%lld need a look: see the list.", comment: "plan review"), warned))
                .font(.system(size: 11)).foregroundColor(.orange)
        }
        if !r.added.isEmpty {
            Text(String(format: NSLocalizedString("%lld new since you opened the list: unticked until you tick them.", comment: "plan review"), r.added.count))
                .font(.system(size: 11)).foregroundColor(.orange)
        }
        if r.counts.trashes > 0 {
            Text("Items go to the Trash, not deleted. To put them back, use Undo here or in Settings: Finder's Put Back doesn't know their folder.")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
        DisclosureGroup(isExpanded: $model.expanded) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button("Select All") { model.setAll(true) }
                    Button("Select None") { model.setAll(false) }
                }
                .buttonStyle(.link)
                .font(.system(size: 10))
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(r.items) { item in row(item, review: r) }
                    }
                }
                .frame(maxHeight: 240)
            }
        } label: {
            Text(String(format: NSLocalizedString("%1$lld of %2$lld changes selected", comment: "plan review"),
                        r.approvable.count, r.items.count))
                .font(.system(size: 11))
        }
        HStack {
            Spacer()
            Button("Cancel") {
                model.cancel()
                dismiss()
            }
            // No Return shortcut: approving is always a deliberate click.
            Button("Approve Selected") { model.approve() }
                .disabled(r.approvable.isEmpty || manager.isChanging)
        }
        .font(.system(size: 11))
    }

    private func row(_ item: PlanItem, review r: PlanReview) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Toggle(isOn: Binding(get: { r.isSelected(item.id) }, set: { model.set(item.id, selected: $0) })) {
                Text(FolderPlanModel.describe(item)).font(.system(size: 11)).lineLimit(2).truncationMode(.middle)
            }
            .toggleStyle(.checkbox)
            .disabled(r.invalid[item.id] != nil)
            Group {
                if let why = r.invalid[item.id] {
                    Text(String(format: NSLocalizedString("Changed since it was proposed: %@", comment: "plan item"), why))
                        .foregroundColor(.red)
                }
                ForEach(Array(PlanReview.warnings(item).enumerated()), id: \.offset) { _, w in
                    Text(FolderPlanModel.warning(w)).foregroundColor(w == .trashRestore ? .secondary : .orange)
                }
            }
            .font(.system(size: 10))
            .padding(.leading, 20)
        }
    }

    @ViewBuilder
    private func finished(_ o: PlanOutcome) -> some View {
        Text(String(format: NSLocalizedString("Done: %lld changes made.", comment: "plan result"), o.done))
            .font(.system(size: 12, weight: .medium))
        if o.failed > 0 || o.uncertain > 0 || o.notRun > 0 {
            Text(String(format: NSLocalizedString("Stopped at a problem: %1$lld failed, %2$lld unsure, %3$lld not run. Nothing past it was changed.", comment: "plan result"),
                        o.failed, o.uncertain, o.notRun))
                .font(.system(size: 11)).foregroundColor(.orange)
            if let problem = o.problem {
                Text(problem).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(4)
            }
            if o.uncertain > 0 {
                Text("An unsure item may or may not have changed: look at it in Finder. Settings > Folders keeps the journal.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        HStack {
            Spacer()
            Button("Close", action: dismiss)
            if o.done > 0 {
                Button("Undo") { model.undo() }.disabled(manager.isChanging)
            }
        }
        .font(.system(size: 11))
    }

    @ViewBuilder
    private func undone(_ report: ChangeUndo.Report) -> some View {
        Text(String(format: NSLocalizedString("Undone: %lld changes reversed.", comment: "plan result"), report.undone.count))
            .font(.system(size: 12, weight: .medium))
        if let stopped = report.stopped {
            Text(String(format: NSLocalizedString("Stopped: %@", comment: "undo result"), stopped.reason ?? ""))
                .font(.system(size: 11)).foregroundColor(.orange)
        }
        let left = report.remaining.filter(\.reversible).count
        if left > 0 {
            Text(String(format: NSLocalizedString("%lld can still be undone from Settings > Folders.", comment: "undo result"), left))
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
        HStack {
            Spacer()
            Button("Close", action: dismiss)
        }
        .font(.system(size: 11))
    }
}

extension String {
    /// "Move 3 files" from "move 3 files".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The chat's folder menu (beside the attachments): Allow Folder…, and the
/// folders this chat may use, each revocable.
struct ChatFolderMenu: View {
    @EnvironmentObject var chat: ChatClient
    @ObservedObject private var manager = FolderAccessManager.shared

    var body: some View {
        Menu {
            Button("Allow Folder to Look In…") { chat.allowFolder(level: .read) }
            if chat.currentSessionID != nil {
                Button("Allow Folder to Change…") { chat.allowFolder(level: .change) }
            }
            let folders = chat.accessibleFolders
            if !folders.isEmpty {
                Divider()
                Section("This chat may use") {
                    ForEach(folders) { grant in
                        let title = FolderAccessManager.display(grant.root.path) + " — " + FolderAccessManager.levelText(grant.level)
                            + ", " + FolderAccessManager.lifetimeText(grant)
                        Menu(title) {
                            Button("Revoke") { try? manager.revoke(grant) }
                        }
                    }
                }
            }
            Divider()
            Button("Folder Settings…") {
                NotificationCenter.default.post(name: .showSettings, object: nil, userInfo: ["pane": SettingsPane.folders.rawValue])
            }
        } label: {
            Image(systemName: "folder")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Folders the chat may use")
        .accessibilityLabel(Text("Folders"))
        // Read again when grants change.
        .id(manager.grantsRevision)
    }
}

// MARK: - Settings

/// Settings > Files: Project files (its own section), then folder access --
/// its opt-in, the standing grants with Revoke, Allow Folder…, the journal
/// with Undo, what recovery found.
struct FoldersPane: View {
    @ObservedObject private var manager = FolderAccessManager.shared
    @State private var level: FolderAccessLevel = .read
    @State private var always = false
    @State private var error: String?
    @State private var undoNote: String?

    var body: some View {
        Form {
            ProjectFilesSection()
            Section("Folder access") {
                Toggle(isOn: Binding(get: { manager.isEnabled }, set: { manager.setEnabled($0) })) {
                    SettingLabel(title: "Let chats work in folders", help: "The chat model can look in folders you allow (names, sizes, dates, short excerpts) and propose changes there -- new folders, moves, renames, moving to the Trash. Every change is a plan you approve first, and can be undone.")
                }
                if manager.isEnabled {
                    Text("A chat asks before it looks in a folder, and shows every change as a plan to approve. Private places (Library, keys, the home folder itself) are never shared.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if manager.isEnabled {
                grantsSection
                journalSection
                if !manager.recoveries.isEmpty { recoverySection }
            }
        }
        .formStyle(.grouped)
        .onAppear { manager.refresh() }
    }

    private var grantsSection: some View {
        Section("Allowed folders") {
            if manager.standingGrants.isEmpty {
                Text("None yet. Grants for one chat or one request aren't listed here: they end with it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(manager.standingGrants) { grant in
                LabeledContent {
                    Button("Revoke") {
                        do { try manager.revoke(grant) } catch { self.error = FolderAccessManager.message(error) }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: FolderAccessManager.display(grant.root.path))
                        Text(verbatim: "\(FolderAccessManager.levelText(grant.level)) · \(FolderAccessManager.lifetimeText(grant))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            // One row each: labelled pickers in an HStack overflow a grouped Form.
            Picker("Access", selection: $level) {
                Text("Look in").tag(FolderAccessLevel.read)
                Text("Look in and propose changes").tag(FolderAccessLevel.change)
            }
            Picker("For", selection: $always) {
                Text("An hour").tag(false)
                Text("Always").tag(true)
            }
            HStack {
                Spacer()
                Button("Allow Folder…", action: allowFolder)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func allowFolder() {
        error = nil
        let message = NSLocalizedString("Choose a folder chats may use.", comment: "")
        switch manager.pickFolder(message: message) {
        case nil: return
        case .failure(let e)?:
            error = String(format: NSLocalizedString("That folder can't be shared with the chat: %@", comment: ""), FolderAccessManager.message(e))
        case .success(let root)?:
            do {
                try manager.userGrant(root, level: level, choice: always ? .always : .hour, chat: nil)
            } catch {
                self.error = FolderAccessManager.message(error)
            }
        }
    }

    /// The newest plan of each chat that still has something done: the one
    /// Undo is offered for.
    private var undoable: Set<UUID> {
        var seen = Set<String>()
        var out = Set<UUID>()
        for record in manager.journalRecords where !seen.contains(record.chatID) {
            seen.insert(record.chatID)
            if record.items.contains(where: { if case .done = $0.state { return true }; return false }) { out.insert(record.planID) }
        }
        return out
    }

    private var journalSection: some View {
        Section("Recent changes") {
            if manager.journalRecords.isEmpty {
                Text("No folder changes yet.").font(.caption).foregroundStyle(.secondary)
            }
            let undoable = self.undoable
            ForEach(manager.journalRecords, id: \.planID) { record in
                LabeledContent {
                    if undoable.contains(record.planID) {
                        Button("Undo") { undo(record.planID) }.disabled(manager.isChanging)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: record.started.formatted(date: .abbreviated, time: .shortened))
                        Text(Self.describe(record)).font(.caption).foregroundStyle(record.isIncomplete ? .orange : .secondary)
                    }
                }
            }
            if let undoNote {
                Text(undoNote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func describe(_ r: JournalRecord) -> String {
        var done = 0, failed = 0, undone = 0, open = 0
        for item in r.items {
            switch item.state {
            case .done: done += 1
            case .failed: failed += 1
            case .undone: undone += 1
            case .incomplete, .uncertain, .undoIncomplete: open += 1
            }
        }
        var s = String(format: NSLocalizedString("%1$lld done, %2$lld undone, %3$lld failed", comment: "journal entry"), done, undone, failed)
        if open > 0 || r.isIncomplete {
            s += " · " + String(format: NSLocalizedString("%lld interrupted: look at them in Finder", comment: "journal entry"), open)
        }
        return s
    }

    private func undo(_ planID: UUID) {
        undoNote = nil
        Task {
            guard let report = await manager.undo(planID) else { return }
            var note = String(format: NSLocalizedString("Undone: %lld changes reversed.", comment: "plan result"), report.undone.count)
            if let stopped = report.stopped {
                note += " " + String(format: NSLocalizedString("Stopped: %@", comment: "undo result"), stopped.reason ?? "")
            }
            undoNote = note
        }
    }

    private var recoverySection: some View {
        Section("Found after an interruption") {
            ForEach(manager.recoveries, id: \.planID) { r in
                VStack(alignment: .leading, spacing: 2) {
                    if !r.restored.isEmpty {
                        Text(String(format: NSLocalizedString("%lld items put back under their names.", comment: "recovery"), r.restored.count))
                    }
                    ForEach(r.needsLook.keys.sorted(), id: \.self) { id in
                        Text(verbatim: r.needsLook[id] ?? "").font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(r.leftBehind.keys.sorted(), id: \.self) { id in
                        Text(verbatim: r.leftBehind[id] ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
