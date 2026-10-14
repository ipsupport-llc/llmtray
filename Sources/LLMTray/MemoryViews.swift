import SwiftUI
import LLMTrayCore

/// Settings › Memory (adr/0024): the notes chats get, and how long they last.
struct MemoryPane: View {
    @ObservedObject private var memory = MemoryManager.shared
    @ObservedObject private var library = ChatLibraryStore.shared
    @ObservedObject private var reflector = MemoryReflector.shared
    @ObservedObject private var embedders = ProjectIndexer.shared.embedders
    @AppStorage(Pref.memoryLanguage.name) private var language = Pref.memoryLanguage.defaultValue
    @State private var downloadError: String?
    @AppStorage(Pref.memoryEnabled.name) private var enabled = Pref.memoryEnabled.defaultValue
    @AppStorage(Pref.memoryKinds.name) private var kindsRaw = Pref.memoryKinds.defaultValue
    @AppStorage(Pref.memoryBudgetTokens.name) private var budget = Pref.memoryBudgetTokens.defaultValue
    @AppStorage(Pref.memoryMaxActive.name) private var maxActive = Pref.memoryMaxActive.defaultValue
    @AppStorage(Pref.memoryDeleteExpiredAfterDays.name) private var deleteAfter = Pref.memoryDeleteExpiredAfterDays.defaultValue
    @AppStorage(Pref.memoryProjects.name) private var projects = Pref.memoryProjects.defaultValue
    @AppStorage(Pref.memoryShareLearned.name) private var shareLearned = Pref.memoryShareLearned.defaultValue
    @AppStorage(Pref.memoryFactChats.name) private var factChats = Pref.memoryFactChats.defaultValue
    @AppStorage(Pref.memoryModel.name) private var learningModel = Pref.memoryModel.defaultValue
    @AppStorage(Pref.memorySwitchIdleMinutes.name) private var switchIdleMinutes = Pref.memorySwitchIdleMinutes.defaultValue
    @ObservedObject private var catalog = ModelCatalog.shared
    @AppStorage(Pref.memoryIdleMinutes.name) private var idleMinutes = Pref.memoryIdleMinutes.defaultValue
    @AppStorage(Pref.memoryForgetDeletedChats.name) private var forgetDeletedChats = Pref.memoryForgetDeletedChats.defaultValue
    @AppStorage(Pref.memoryHalfLifeFact.name) private var halfLifeFact = Pref.memoryHalfLifeFact.defaultValue
    @AppStorage(Pref.memoryHalfLifePreference.name) private var halfLifePreference = Pref.memoryHalfLifePreference.defaultValue
    @AppStorage(Pref.memoryHalfLifeCorrection.name) private var halfLifeCorrection = Pref.memoryHalfLifeCorrection.defaultValue
    @AppStorage(Pref.memoryHalfLifeObservation.name) private var halfLifeObservation = Pref.memoryHalfLifeObservation.defaultValue
    @State private var draft: MemoryNoteDraft?
    @State private var confirmForgetAll = false
    /// Memory on again with something put aside: read what was said meanwhile?
    @State private var askResume = false
    @State private var confirmLearnPast = false
    @State private var confirmForgetLearned = false
    /// What "Learn from Past Chats Now" did, shown under it.
    @State private var learnPastResult: String?
    @State private var about: [MemoryAboutField: String] = [:]
    @State private var aboutError: String?

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
                aboutSection
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
                        SettingLabel(title: "Remember in projects", help: "A project's chats learn and get notes about their project. Off: nothing is learned in a project's chats and no project note is sent.")
                    }
                    Picker(selection: $shareLearned) {
                        Text("Stays in its project").tag(false)
                        Text("Shared by all chats").tag(true)
                    } label: {
                        SettingLabel(title: "Learned from chats", help: "Stays in its project: a project's chats see what was learned in that project, chats outside projects what was learned outside them. Shared by all chats: every chat sees everything learned anywhere (a project's notes only while Remember in projects is on). What you write yourself (About you, notes for all chats) is seen everywhere either way.")
                    }
                    Stepper(value: $budget, in: 50...4000, step: 50) {
                        SettingLabel(title: "Room in each chat: \(budget) tokens", help: "The most the notes take in a chat's prompt. Pinned notes and your stated preferences go first, then the rest by how recent they are.")
                    }
                }
                Section("Learning") {
                    if memory.file.hasPaused {
                        // Unanswered: nothing is read or met until it is.
                        HStack {
                            Text("Memory was off. Read what was said meanwhile?").font(.caption)
                            Spacer()
                            Button("Read It Too") { memory.change { $0.resumeAll(readMeanwhile: true) } }
                            Button("Only From Now On") { memory.change { $0.resumeAll(readMeanwhile: false) } }
                        }
                    }
                    learningStatus
                    Picker(selection: $learningModel) {
                        Text("The chat's own model").tag("")
                        ForEach(learningModels, id: \.path) { model in
                            Text(model.displayName).tag(model.path)
                        }
                    } label: {
                        SettingLabel(title: "Reads chats with", help: "The chat's own model: each chat is read by the model that answered in it -- a chat in Russian with Gemma isn't read by an English-only coder you loaded later. One model: every chat is read by it, so all notes are written alike. Either way a chat waits until its model is loaded and free; nothing is loaded for it unless you allow that below.")
                    }
                    if let warning = languageWarning {
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                    Picker(selection: $switchIdleMinutes) {
                        Text("Never").tag(0)
                        ForEach([30, 60, 120, 240], id: \.self) { Text("After \($0) idle minutes").tag($0) }
                    } label: {
                        SettingLabel(title: "Load it itself", help: "When chats wait for a model that isn't loaded, memory may load it once LLMTray has been idle this long (no chat, app or picture at work). The next request for your usual model loads that one back, which takes a moment.")
                    }
                    Picker(selection: $language) {
                        Text("Same as LLMTray").tag("auto")
                        ForEach(Self.languages, id: \.self) { code in
                            Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                        }
                    } label: {
                        SettingLabel(title: "Notes in", help: "Notes are written in this language whatever language the chat is in, so one thing doesn't become two notes in two languages.")
                    }
                    Stepper(value: $idleMinutes, in: 1...240) {
                        SettingLabel(title: "Read a chat after \(idleMinutes) quiet minutes", help: "What you wrote in a chat is read for notes once it has been quiet this long, when you leave it, or when LLMTray quits -- in the background, only while the model has nothing else to do. Only your own words count, never the answers, files or web pages. Temporary chats and chats marked \"Don't Remember\" are never read.")
                    }
                    Toggle(isOn: $forgetDeletedChats) {
                        SettingLabel(title: "Deleting a chat forgets what it taught", help: "Notes learned only from a deleted chat go with it, unless you edited, pinned or approved them.")
                    }
                    HStack {
                        SettingLabel(title: "Past chats", help: "Memory reads a chat only from the first message after it met it. This reads every saved chat from its start too -- what you wrote before memory was on -- in the background, while the model is free. Chats marked \"Don't Remember\" are skipped.")
                        Spacer()
                        Button("Learn from Past Chats Now") { confirmLearnPast = true }
                            .disabled(memory.unreadable || memory.file.hasPaused)
                    }
                    HStack {
                        SettingLabel(title: "Start over", help: "Forgets every learned note you haven't written, edited, pinned or approved, and what's waiting to be read. Then your chats can be read again with the current rules -- not ones marked \"Don't Remember\", nor, while memory was off, before you answer whether to read what was said meanwhile.")
                        Spacer()
                        Button("Forget What Was Learned…") { confirmForgetLearned = true }
                            .disabled(memory.unreadable || memory.file.unreviewedCount == 0 && memory.file.queue.isEmpty)
                    }
                    Stepper(value: $factChats, in: 1...5) {
                        SettingLabel(title: factChats == 1 ? "Use a learned fact at once" : "Use a learned fact once \(factChats) chats show it",
                                     help: "A fact or observation learned from one chat waits until another chat shows it too (or you approve it): one question isn't who you are. What you ask for -- preferences, corrections -- is used at once.")
                    }
                    if let learnPastResult {
                        Text(learnPastResult).font(.caption).foregroundStyle(.secondary)
                    }
                    if !memory.file.queue.isEmpty {
                        Text("\(memory.file.queue.count) parts of chats wait to be read.")
                            .font(.caption).foregroundStyle(.secondary)
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
        // Off: chats are met anew when it's on again, so nothing said
        // meanwhile is read.
        // Off: watermarks put aside. On again: the user picks whether what
        // was said meanwhile is read.
        .onChange(of: enabled) { _, on in
            if on {
                if memory.file.hasPaused { askResume = true }
            } else if !memory.change({ $0.pauseAll() }) {
                // Not put aside on disk: stays on (the error shows above).
                enabled = true
            }
        }
        .confirmationDialog("Read what was said while memory was off?", isPresented: $askResume) {
            Button("Read It Too") { memory.change { $0.resumeAll(readMeanwhile: true) } }
            Button("Only From Now On") { memory.change { $0.resumeAll(readMeanwhile: false) } }
        } message: {
            Text("Memory can learn from what you wrote in your chats while it was off, or only from what you write from now on.")
        }
        .confirmationDialog("Forget what was learned?", isPresented: $confirmForgetLearned) {
            Button("Forget and Read All Chats Again") {
                if memory.forgetLearned(readAgain: true) { learnFromPastChats() }
            }
            Button("Only Forget", role: .destructive) { memory.forgetLearned(readAgain: false) }
        } message: {
            Text("\(memory.file.unreviewedCount) learned notes you haven't approved go. Notes you wrote, edited, pinned or approved stay.")
        }
        .confirmationDialog("Learn from all your past chats?", isPresented: $confirmLearnPast) {
            Button("Read Them") { learnFromPastChats() }
        } message: {
            Text("Every saved chat is read from its start for notes, using what you wrote there. It runs in the background and can take a while.")
        }
        .onAppear(perform: loadAbout)
        .onChange(of: learningModel) { _, _ in reflector.poke(after: 2) }
        .onChange(of: switchIdleMinutes) { _, _ in reflector.poke(after: 2) }
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

    /// Every saved chat queued from its start; what it did, under the button.
    private func learnFromPastChats() {
        let (queued, waiting) = memory.learnFromPastChats()
        var lines: [String] = []
        if queued > 0 {
            lines.append(String(format: NSLocalizedString("%d chats queued; reading starts now if the model is free.", comment: ""), queued))
        }
        if waiting > 0 {
            lines.append(String(format: NSLocalizedString("%d chats are answering: theirs is queued once they're done.", comment: ""), waiting))
        }
        learnPastResult = lines.isEmpty
            ? NSLocalizedString("Nothing left to read: every chat was read from its start.", comment: "")
            : lines.joined(separator: " ")
        reflector.poke(after: 1)
    }

    /// Chat models big enough to write good notes (about 3B parameters and up).
    private var learningModels: [LocalModel] {
        catalog.models.filter { (catalog.sizes[$0.path] ?? .max) >= 1_500_000_000 || $0.path == learningModel }
    }

    /// The model set for memory doesn't say it speaks the notes' language.
    private var languageWarning: String? {
        guard !learningModel.isEmpty,
              let readme = try? String(contentsOfFile: learningModel + "/README.md", encoding: .utf8),
              let languages = ModelCardLanguages.parse(readme: readme) else { return nil }
        let code = MemoryReflector.languageCode()
        guard !ModelCardLanguages.covers(languages, code) else { return nil }
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        return String(format: NSLocalizedString("This model's card doesn't list %@: it may read chats in it poorly and write worse notes.", comment: ""), name)
    }

    /// The app's languages, for the notes' language.
    static let languages: [String] = {
        let codes = Bundle.main.localizations.filter { $0 != "Base" }.map { String($0.prefix(2)) }
        return Array(Set(codes.isEmpty ? ["en"] : codes)).sorted()
    }()

    /// What learning does now, and the embedding model it needs.
    @ViewBuilder private var learningStatus: some View {
        let ready = FeatureSetup.shared.isProjectFilesEmbedderReady
        if !ready {
            VStack(alignment: .leading, spacing: 6) {
                if let entry = FeatureSetup.shared.projectFilesEmbedder {
                    Text(String(format: NSLocalizedString("Learning from chats needs %@ (%@), an embedding model that tells which notes say the same thing in other words or another language. It's downloaded to this computer once, shared with project files.", comment: ""),
                                entry.displayName, ModelCatalog.format(FeatureSetup.downloadBytes(entry))))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(embedders.isBusy ? "Downloading…" : "Download") {
                        downloadError = nil
                        Task {
                            if let error = await FeatureSetup.shared.downloadProjectFilesEmbedder() {
                                downloadError = error.localizedDescription
                            } else {
                                await ProjectIndexer.shared.embedderChanged()
                                reflector.poke(after: 1)
                            }
                        }
                    }
                    .disabled(embedders.isBusy)
                }
                if let downloadError {
                    Text(downloadError).font(.caption).foregroundStyle(.red)
                }
            }
        } else {
            switch reflector.status {
            case .reading:
                Text("Reading a chat…").font(.caption).foregroundStyle(.secondary)
            case .waiting(let reason) where !memory.file.queue.isEmpty:
                Text(reason).font(.caption).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }

    private func halfLifeStepper(_ title: LocalizedStringKey, _ value: Binding<Int>) -> some View {
        Stepper(value: value, in: 1...3650, step: value.wrappedValue < 30 ? 1 : 15) {
            SettingLabel(title: title, help: "A note counts for half as much after this long without being confirmed, and expires after about three times as long. Pinned notes never expire.")
        }
    }

    private func loadAbout() {
        about = Dictionary(uniqueKeysWithValues: MemoryAboutField.allCases.map { ($0, memory.file.about($0).map($0.value(of:)) ?? "") })
    }

    private func aboutBinding(_ field: MemoryAboutField) -> Binding<String> {
        Binding(get: { about[field] ?? "" }, set: { about[field] = $0 })
    }

    private func saveAbout() {
        aboutError = nil
        let now = Date()
        var refused: [MemoryAboutField] = []
        memory.change { file in
            for field in MemoryAboutField.allCases where !file.setAbout(field, about[field] ?? "", now: now) { refused.append(field) }
        }
        if !refused.isEmpty {
            aboutError = NSLocalizedString("Some of it can't be kept: at most 160 characters each, no links, file paths or keys.", comment: "")
        }
        loadAbout()
    }

    /// Fields the user fills in if they want: pinned notes, sent first.
    private var aboutSection: some View {
        Section("About you") {
            Text("Only if you want: chats get it first, it never expires, and learning never changes it. It stays on this computer.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Name or how to call you", text: aboutBinding(.name)).onSubmit(saveAbout)
            TextField("Where you are: a city, or an address", text: aboutBinding(.location)).onSubmit(saveAbout)
            TextField("What you do", text: aboutBinding(.work)).onSubmit(saveAbout)
            TextField("Anything else chats should know", text: aboutBinding(.other), axis: .vertical)
                .lineLimit(1...3).onSubmit(saveAbout)
            HStack {
                if let aboutError { Text(aboutError).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Save", action: saveAbout)
                    .disabled(MemoryAboutField.allCases.allSatisfy { (about[$0] ?? "") == (memory.file.about($0).map($0.value(of:)) ?? "") })
            }
        }
    }

    /// The notes listed: About you's are edited in their own section.
    private var activeNotes: [MemoryNote] {
        memory.file.notes.filter { $0.isActive && !memory.file.isAbout($0) }
    }
    private var expiredNotes: [MemoryNote] { memory.file.notes.filter { !$0.isActive } }

    /// Where they're seen: every chat, chats outside projects, each project's.
    private var groups: [(subject: MemorySubject, title: String, notes: [MemoryNote])] {
        let user = activeNotes.filter { $0.subject == .user }
        let general = activeNotes.filter { $0.subject == .general }
        var result: [(MemorySubject, String, [MemoryNote])] = user.isEmpty ? [] : [(.user, NSLocalizedString("All chats", comment: "memory notes group"), user)]
        if !general.isEmpty {
            result.append((.general, NSLocalizedString("Chats outside projects", comment: "memory notes group"), general))
        }
        var byProject: [UUID: [MemoryNote]] = [:]
        for note in activeNotes {
            if case .project(let id) = note.subject { byProject[id, default: []].append(note) }
        }
        for (id, notes) in byProject.sorted(by: { projectName($0.key) < projectName($1.key) }) {
            result.append((.project(id), String(format: NSLocalizedString("Chats of project %@", comment: "a memory note's visibility"), projectName(id)), notes))
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
                        memory.forget(note.id)
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
                if !memory.settings.isEstablished(note) {
                    Text("Not sent yet: waits for another chat to show it, or your approval.")
                        .font(.caption).foregroundStyle(.orange)
                }
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
                Button("Forget", role: .destructive) { memory.forget(note.id) }
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
                file.edit(id, text: d.text, topic: d.topic, kind: d.kind, subject: d.subject, now: now)
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
            Picker("Seen in", selection: $draft.subject) {
                Text("All chats").tag(MemorySubject.user)
                Text("Chats outside projects").tag(MemorySubject.general)
                ForEach(projects) { project in
                    Text(String(format: NSLocalizedString("Chats of project %@", comment: "a memory note's visibility"), project.name))
                        .tag(MemorySubject.project(project.id))
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
                            Button("Forget") { memory.forget(note.id) }
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
