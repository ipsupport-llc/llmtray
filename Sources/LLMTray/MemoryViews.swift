import SwiftUI
import LLMTrayCore

/// Settings › Memory (adr/0024): the notes chats get, and how long they last.
struct MemoryPane: View {
    @ObservedObject private var memory = MemoryManager.shared
    @ObservedObject private var library = ChatLibraryStore.shared
    @AppStorage(Pref.memoryEnabled.name) private var enabled = Pref.memoryEnabled.defaultValue
    @AppStorage(Pref.memoryKinds.name) private var kindsRaw = Pref.memoryKinds.defaultValue
    @AppStorage(Pref.memoryBudgetTokens.name) private var budget = Pref.memoryBudgetTokens.defaultValue
    @AppStorage(Pref.memoryMaxActive.name) private var maxActive = Pref.memoryMaxActive.defaultValue
    @AppStorage(Pref.memoryDeleteExpiredAfterDays.name) private var deleteAfter = Pref.memoryDeleteExpiredAfterDays.defaultValue
    @AppStorage(Pref.memoryProjects.name) private var projects = Pref.memoryProjects.defaultValue
    @AppStorage(Pref.memoryHalfLifeFact.name) private var halfLifeFact = Pref.memoryHalfLifeFact.defaultValue
    @AppStorage(Pref.memoryHalfLifePreference.name) private var halfLifePreference = Pref.memoryHalfLifePreference.defaultValue
    @AppStorage(Pref.memoryHalfLifeCorrection.name) private var halfLifeCorrection = Pref.memoryHalfLifeCorrection.defaultValue
    @AppStorage(Pref.memoryHalfLifeObservation.name) private var halfLifeObservation = Pref.memoryHalfLifeObservation.defaultValue
    @State private var draft: MemoryNoteDraft?
    @State private var confirmForgetAll = false

    private var kinds: Set<MemoryKind> {
        Set(kindsRaw.split(separator: ",").compactMap { MemoryKind(rawValue: String($0)) })
    }

    private func kindBinding(_ kind: MemoryKind) -> Binding<Bool> {
        Binding(get: { kinds.contains(kind) }, set: { on in
            var k = kinds
            if on { k.insert(kind) } else { k.remove(kind) }
            kindsRaw = MemoryKind.allCases.filter(k.contains).map(\.rawValue).joined(separator: ",")
        })
    }

    var body: some View {
        Form {
            Section("Memory") {
                Toggle(isOn: $enabled) {
                    SettingLabel(title: "Remember things between chats", help: "Chats start with short notes about you and your work: how you like answers, what you're working on, what you corrected before. Only the notes that fit the budget go, and only in LLMTray's own chats -- never to apps using the API, never in temporary chats. Everything stays on this computer.")
                }
                if enabled {
                    Text("For now you write the notes yourself. Learning them from your chats comes in a later version.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if memory.unreadable {
                    Text("The notes file can't be read (damaged, or from a newer LLMTray). Nothing is sent or changed until it can.")
                        .font(.caption).foregroundStyle(.red)
                }
                if memory.saveFailed {
                    Text("The last change couldn't be saved.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            if enabled {
                notesSection
                if !expiredNotes.isEmpty { expiredSection }
                Section("What chats get") {
                    Toggle(isOn: kindBinding(.preference)) {
                        SettingLabel(title: "Preferences", help: "How you like things: language, length, tone, formatting.")
                    }
                    Toggle(isOn: kindBinding(.correction)) {
                        SettingLabel(title: "Corrections", help: "What you corrected before, so it isn't repeated.")
                    }
                    Toggle(isOn: kindBinding(.fact)) {
                        SettingLabel(title: "Facts", help: "About you and your work: what you do, what you use.")
                    }
                    Toggle(isOn: kindBinding(.observation)) {
                        SettingLabel(title: "Observations", help: "What you did, kept apart from what it may mean. Sent as a guess.")
                    }
                    Toggle(isOn: $projects) {
                        SettingLabel(title: "Project notes", help: "Notes about a project go to that project's chats.")
                    }
                    Stepper(value: $budget, in: 50...4000, step: 50) {
                        SettingLabel(title: "Room in each chat: \(budget) tokens", help: "The most the notes take in a chat's prompt. Pinned notes and your stated preferences go first, then the rest by how recent they are.")
                    }
                }
                Section("How long notes last") {
                    halfLifeStepper("Preferences: half after \(halfLifePreference) days", $halfLifePreference)
                    halfLifeStepper("Corrections: half after \(halfLifeCorrection) days", $halfLifeCorrection)
                    halfLifeStepper("Facts: half after \(halfLifeFact) days", $halfLifeFact)
                    halfLifeStepper("Observations: half after \(halfLifeObservation) days", $halfLifeObservation)
                    Stepper(value: $maxActive, in: 20...2000, step: 20) {
                        SettingLabel(title: "Keep at most \(maxActive) notes", help: "Over this, the weakest notes (oldest, least certain) expire. Pinned notes are kept.")
                    }
                    Stepper(value: $deleteAfter, in: 0...365, step: 5) {
                        SettingLabel(title: "Delete expired notes after \(deleteAfter) days", help: "An expired note isn't sent any more; you can bring it back until it's deleted.")
                    }
                }
                Section {
                    HStack {
                        Spacer()
                        Button("Forget Everything…", role: .destructive) { confirmForgetAll = true }
                            .disabled(memory.file.notes.isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Expiry follows its settings at once, not at the next chat.
        .onChange(of: [maxActive, deleteAfter, halfLifeFact, halfLifePreference, halfLifeCorrection, halfLifeObservation]) { _, _ in
            memory.sweep()
        }
        .sheet(item: $draft) { d in
            MemoryNoteEditor(draft: d, projects: library.library.projects) { saved in
                save(saved)
                draft = nil
            } onCancel: { draft = nil }
        }
        .confirmationDialog("Forget every note?", isPresented: $confirmForgetAll) {
            Button("Forget Everything", role: .destructive) { memory.change { $0.forgetAll() } }
        } message: {
            Text("Chats won't get them any more. This can't be undone.")
        }
    }

    private func halfLifeStepper(_ title: LocalizedStringKey, _ value: Binding<Int>) -> some View {
        Stepper(value: value, in: 1...3650, step: value.wrappedValue < 30 ? 1 : 15) {
            SettingLabel(title: title, help: "A note counts for half as much after this long without being confirmed, and expires after about three times as long. Pinned notes never expire.")
        }
    }

    private var activeNotes: [MemoryNote] { memory.file.notes.filter(\.isActive) }
    private var expiredNotes: [MemoryNote] { memory.file.notes.filter { !$0.isActive } }

    /// The user's notes first, then each project's.
    private var groups: [(subject: MemorySubject, title: String, notes: [MemoryNote])] {
        let user = activeNotes.filter { $0.subject == .user }
        var result: [(MemorySubject, String, [MemoryNote])] = user.isEmpty ? [] : [(.user, NSLocalizedString("About you", comment: "memory notes group"), user)]
        var byProject: [UUID: [MemoryNote]] = [:]
        for note in activeNotes {
            if case .project(let id) = note.subject { byProject[id, default: []].append(note) }
        }
        for (id, notes) in byProject.sorted(by: { projectName($0.key) < projectName($1.key) }) {
            result.append((.project(id), String(format: NSLocalizedString("Project %@", comment: "memory notes group"), projectName(id)), notes))
        }
        return result
    }

    private func projectName(_ id: UUID) -> String {
        library.library.project(id)?.name ?? NSLocalizedString("A deleted project", comment: "")
    }

    private var notesSection: some View {
        Section("Notes") {
            if activeNotes.isEmpty {
                Text("No notes yet. Add what every chat should know: \"Answer in Russian, briefly\", \"I build an ESP32 speaker\".")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.subject) { group in
                Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(group.notes) { note in noteRow(note) }
            }
            HStack {
                Spacer()
                Button("Add Note…") { draft = MemoryNoteDraft() }
                    .disabled(memory.unreadable)
            }
        }
    }

    private var expiredSection: some View {
        Section("Expired") {
            Text("Not sent any more. Bring one back, or it's deleted later.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(expiredNotes) { note in
                HStack {
                    Text(note.text).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore") { memory.change { $0.restore(note.id, now: Date()) } }
                    Button {
                        memory.change { $0.forget(note.id) }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Forget")
                }
            }
        }
    }

    private func noteRow(_ note: MemoryNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let observed = note.observed {
                    Text("Observed: \(observed)").font(.caption).foregroundStyle(.secondary)
                }
                Text(note.text)
                Text("\(MemoryNoteDraft.kindName(note.kind)) · \(note.topic) · \(note.confirmed.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                memory.change { $0.setPinned(note.id, !note.pinned, now: Date()) }
            } label: {
                Image(systemName: note.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(note.pinned ? "Unpin" : "Pin: always sent first, never expires")
            Menu {
                Button("Edit…") { draft = MemoryNoteDraft(note) }
                if !note.reviewed {
                    Button("Approve") { memory.change { $0.approve(note.id) } }
                }
                Divider()
                Button("Forget", role: .destructive) { memory.change { $0.forget(note.id) } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func save(_ d: MemoryNoteDraft) {
        let now = Date()
        memory.change { file in
            if let id = d.id {
                file.edit(id, text: d.text, topic: d.topic, kind: d.kind, now: now)
            } else {
                file.add(subject: d.subject, topic: d.topic, kind: d.kind, text: d.text, now: now)
            }
        }
    }
}

/// A note being written or edited.
struct MemoryNoteDraft: Identifiable {
    let id: String?
    var text = ""
    var kind: MemoryKind = .preference
    var topic = "general"
    var subject: MemorySubject = .user

    init() { id = nil }

    init(_ note: MemoryNote) {
        id = note.id
        text = note.text
        kind = note.kind
        topic = note.topic
        subject = note.subject
    }

    static func kindName(_ kind: MemoryKind) -> String {
        switch kind {
        case .fact: return NSLocalizedString("Fact", comment: "memory note kind")
        case .preference: return NSLocalizedString("Preference", comment: "memory note kind")
        case .correction: return NSLocalizedString("Correction", comment: "memory note kind")
        case .observation: return NSLocalizedString("Observation", comment: "memory note kind")
        }
    }

    static func problemText(_ problem: MemoryText.Problem) -> String {
        switch problem {
        case .empty: return ""
        case .tooLong: return String(format: NSLocalizedString("At most %d characters: a note is one short statement.", comment: ""), MemoryText.maxLength)
        case .link: return NSLocalizedString("Notes can't hold links.", comment: "")
        case .path: return NSLocalizedString("Notes can't hold file paths.", comment: "")
        case .secret: return NSLocalizedString("This looks like a key or a password: notes can't hold one.", comment: "")
        }
    }
}

extension MemoryNoteDraft: Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.text == b.text && a.kind == b.kind && a.topic == b.topic && a.subject == b.subject
    }
}

/// The sheet for one note.
struct MemoryNoteEditor: View {
    @State var draft: MemoryNoteDraft
    let projects: [ChatLibrary.Project]
    let onSave: (MemoryNoteDraft) -> Void
    let onCancel: () -> Void

    private var problem: MemoryText.Problem? { MemoryText.problem(draft.text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.id == nil ? "New Note" : "Edit Note").font(.headline)
            TextField("Answer in Russian, briefly", text: $draft.text, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("\(draft.text.count) / \(MemoryText.maxLength)")
                    .font(.caption).foregroundStyle(draft.text.count > MemoryText.maxLength ? .red : .secondary)
                if let problem, problem != .empty {
                    Text(MemoryNoteDraft.problemText(problem)).font(.caption).foregroundStyle(.red)
                }
            }
            Picker("Kind", selection: $draft.kind) {
                ForEach([MemoryKind.preference, .correction, .fact, .observation], id: \.self) { kind in
                    Text(MemoryNoteDraft.kindName(kind)).tag(kind)
                }
            }
            Picker("Topic", selection: $draft.topic) {
                ForEach(topics, id: \.self) { Text($0).tag($0) }
            }
            if draft.id == nil {
                Picker("About", selection: $draft.subject) {
                    Text("You").tag(MemorySubject.user)
                    ForEach(projects) { project in
                        Text(String(format: NSLocalizedString("Project %@", comment: "memory notes group"), project.name))
                            .tag(MemorySubject.project(project.id))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// The built-in topics, and the note's own when it has another.
    private var topics: [String] {
        MemoryTopics.builtIn.contains(draft.topic) ? MemoryTopics.builtIn : MemoryTopics.builtIn + [draft.topic]
    }
}

/// "Memory: 4" above the composer: the notes this chat got (adr/0024),
/// each with Forget. A forgotten one leaves the chat from its next message.
struct ChatMemoryChip: View {
    @EnvironmentObject var chat: ChatClient
    @ObservedObject private var memory = MemoryManager.shared
    @State private var shown = false

    var body: some View {
        let snapshot = chat.memorySnapshot
        let notes = (snapshot?.noteIDs ?? []).compactMap { memory.file.note($0) }
        if memory.isEnabled, !notes.isEmpty {
            Button {
                shown.toggle()
            } label: {
                Label(String(format: NSLocalizedString("Memory: %d", comment: "the chat's memory chip: notes it got"), notes.count),
                      systemImage: "brain")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("What this chat knows about you from earlier chats")
            .popover(isPresented: $shown, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This chat knows").font(.headline)
                    ForEach(notes) { note in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.text).fixedSize(horizontal: false, vertical: true)
                                if note.changed > (snapshot?.generation ?? .max) || !note.isActive {
                                    Text("Changed: the chat gets this from its next message")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Forget") { memory.change { $0.forget(note.id) } }
                                .controlSize(.small)
                        }
                    }
                    Divider()
                    Button("Memory Settings…") {
                        shown = false
                        NotificationCenter.default.post(name: .showSettings, object: nil,
                                                        userInfo: ["pane": SettingsPane.memory.rawValue])
                    }
                    .buttonStyle(.link)
                }
                .padding(12)
                .frame(width: 340)
            }
        }
    }
}
