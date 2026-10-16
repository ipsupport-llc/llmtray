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
    @AppStorage(Pref.memoryMoodHours.name) private var moodHours = Pref.memoryMoodHours.defaultValue
    @AppStorage(Pref.memoryModel.name) private var learningModel = Pref.memoryModel.defaultValue
    @AppStorage(Pref.memorySorter.name) private var sorter = Pref.memorySorter.defaultValue
    @AppStorage(Pref.memoryUnfitReaders.name) private var unfitRaw = Pref.memoryUnfitReaders.defaultValue
    private var unfitReaders: [String] { unfitRaw.split(separator: "\n").map(String.init) }
    @AppStorage(Pref.memorySwitchIdleMinutes.name) private var switchIdleMinutes = Pref.memorySwitchIdleMinutes.defaultValue
    @ObservedObject private var catalog = ModelCatalog.shared
    @AppStorage(Pref.memoryIdleMinutes.name) private var idleMinutes = Pref.memoryIdleMinutes.defaultValue
    @AppStorage(Pref.memoryReadRightAway.name) private var readRightAway = Pref.memoryReadRightAway.defaultValue
    @AppStorage(Pref.memoryForgetDeletedChats.name) private var forgetDeletedChats = Pref.memoryForgetDeletedChats.defaultValue
    @AppStorage(Pref.memoryHalfLifeFact.name) private var halfLifeFact = Pref.memoryHalfLifeFact.defaultValue
    @AppStorage(Pref.memoryHalfLifePreference.name) private var halfLifePreference = Pref.memoryHalfLifePreference.defaultValue
    @AppStorage(Pref.memoryHalfLifeCorrection.name) private var halfLifeCorrection = Pref.memoryHalfLifeCorrection.defaultValue
    @AppStorage(Pref.memoryHalfLifeObservation.name) private var halfLifeObservation = Pref.memoryHalfLifeObservation.defaultValue
    @State private var draft: MemoryNoteDraft?
    /// Memory on again with something put aside: read what was said meanwhile?
    @State private var askResume = false
    @State private var confirmRead = false
    @State private var confirmForget = false
    @State private var showAdvanced = false
    @State private var showPreview = false
    /// What the last "Read Past Chats" did, shown by its button.
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
            Section {
                Label {
                    Text("Memory stays on this Mac: notes are kept in a file here and never uploaded or shared. They go only into the prompt of your LLMTray chats -- not to apps using the API, not into temporary chats.")
                        .font(.callout)
                } icon: {
                    Image(systemName: "lock.shield")
                }
                HStack {
                    Text("The exact text a new chat gets, before your first message.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show What Chats Get…") { showPreview = true }
                        .disabled(memory.unreadable || !enabled)
                }
            }
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
                    ForEach(unfitReaders, id: \.self) { path in
                        HStack {
                            Text(String(format: NSLocalizedString("%@ couldn't read chats for memory: another model reads its chats.", comment: "memory: a model unfit to read"),
                                        MemoryReflector.displayName(path)))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Try It Again") {
                                MemoryReflector.setUnfit(path, false)
                                unfitRaw = UserDefaults.standard[Pref.memoryUnfitReaders]
                                reflector.poke(after: 1)
                            }
                        }
                    }
                    if let mood = memory.file.mood, mood.isFresh(now: Date(), hours: moodHours) {
                        HStack {
                            Text(String(format: NSLocalizedString("Now: %@ → %@ (until %@)", comment: "memory mood"), mood.observed, mood.text,
                                        mood.until(hours: moodHours).formatted(date: .omitted, time: .shortened)))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Forget") { memory.change { $0.mood = nil } }
                        }
                    }
                    HStack {
                        Text(learningSummary).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Read Past Chats…") { confirmRead = true }
                            .disabled(memory.unreadable || memory.file.hasPaused)
                    }
                }
                aboutSection
                notesSection
                if !expiredNotes.isEmpty { expiredSection }
                Section {
                    Button {
                        withAnimation { showAdvanced.toggle() }
                    } label: {
                        HStack {
                            SettingLabel(title: "Advanced", help: "What chats get, how chats are read, how long notes last. The defaults suit most people.")
                            Spacer()
                            Image(systemName: showAdvanced ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if showAdvanced {
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
                        Stepper(value: $moodHours, in: 0...24) {
                            SettingLabel(title: moodHours == 0 ? "Your mood: not read" : "Your mood: for \(moodHours) hours",
                            help: "How you seem right now (angry at a failing build, tired, in a hurry), read from your last messages: new chats get it for this long, then it's gone. It's never a note. 0: not read.")
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
                    Section("Reading chats") {
                        Picker(selection: $learningModel) {
                            Text("The chat's own model").tag("")
                            // Not offered as the reader (adr/0025: it misses too
                            // much); kept for a setting made in a test build.
                            if learningModel == AppleSystemModel.id {
                                Text(AppleSystemModel.displayName).tag(AppleSystemModel.id)
                            }
                            ForEach(learningModels, id: \.path) { model in
                                Text(model.displayName).tag(model.path)
                            }
                        } label: {
                            SettingLabel(title: "Reads chats with", help: "The chat's own model: each chat is read by the model that answered in it -- a chat in Russian with Gemma isn't read by an English-only coder you loaded later. One model: every chat is read by it, so all notes are written alike. Either way a chat waits until its model is loaded and free; nothing is loaded for it unless you allow that below.")
                        }
                        if AppleSystemModel.isAvailable || sorter == AppleSystemModel.id {
                            Picker(selection: $sorter) {
                                Text("The model that reads them").tag("")
                                Text(AppleSystemModel.displayName).tag(AppleSystemModel.id)
                            } label: {
                                SettingLabel(title: "Sorts messages with", help: "Before a chat is read, each message is sorted: how you want answers, something about you, your mood, or nothing. Apple (on this Mac): the system's own model sorts on the Neural Engine, before your model is needed -- a part of a chat with nothing to learn is done there, without loading your model or using the GPU; your model reads only what was sorted in.")
                            }
                            if sorter == AppleSystemModel.id, case .unavailable(let why) = AppleSystemModel.availability {
                                Text(why).font(.caption).foregroundStyle(.orange)
                            }
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
                        Picker(selection: $readRightAway) {
                            Text("Right after each answer").tag(true)
                            Text("When the chat is quiet").tag(false)
                        } label: {
                            SettingLabel(title: "Read chats", help: "When what you wrote is read for notes: a few seconds after each answer, or once the chat has been quiet for a while -- and always when you leave it or quit. Either way it runs in the background only while the model has nothing else to do, and any chat, app or coding agent stops it at once. It never pushes your chat out of the model's prompt cache. Only your own words count, never the answers, files or web pages. Temporary chats and chats marked \"Don't Remember\" are never read.")
                        }
                        if !readRightAway {
                            Stepper(value: $idleMinutes, in: 1...240) {
                                SettingLabel(title: "Quiet for \(idleMinutes) minutes", help: "How long a chat stays quiet before it's read.")
                            }
                        }
                        Toggle(isOn: $forgetDeletedChats) {
                            SettingLabel(title: "Deleting a chat forgets what it taught", help: "Notes learned only from a deleted chat go with it, unless you edited, pinned or approved them.")
                        }
                        Stepper(value: $factChats, in: 1...5) {
                            SettingLabel(title: factChats == 1 ? "Use a learned fact at once" : "Use a learned fact once \(factChats) chats show it",
                            help: "A fact or observation learned from one chat waits until another chat shows it too (or you approve it): one question isn't who you are. What you ask for -- preferences, corrections -- is used at once.")
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
                }
                Section {
                    HStack {
                        Spacer()
                        Button("Forget…", role: .destructive) { confirmForget = true }
                            .disabled(memory.unreadable || memory.file.notes.isEmpty && memory.file.queue.isEmpty)
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
        .onAppear(perform: loadAbout)
        .onChange(of: learningModel) { _, _ in reflector.poke(after: 2) }
        .onChange(of: sorter) { _, _ in reflector.poke(after: 2) }
        .onChange(of: switchIdleMinutes) { _, _ in reflector.poke(after: 2) }
        // Expiry follows its settings at once, not at the next chat.
        .onChange(of: [maxActive, deleteAfter, halfLifeFact, halfLifePreference, halfLifeCorrection, halfLifeObservation]) { _, _ in
            memory.sweep()
        }
        .sheet(isPresented: $showPreview) {
            MemoryPreviewSheet(projects: library.library.projects) { showPreview = false }
        }
        .sheet(item: $draft) { d in
            MemoryNoteEditor(draft: d, projects: library.library.projects) { saved in
                save(saved)
                draft = nil
            } onCancel: { draft = nil }
        }
        .confirmationDialog("Read your past chats?", isPresented: $confirmRead) {
            Button("Read What Wasn't Read") { learnFromPastChats() }
            Button("Read Everything Again") { show(memory.readAllAgain()) }
        } message: {
            Text("Saved chats are read for notes in the background, from what you wrote there. Read again, notes already there are confirmed, not doubled. Chats marked \"Don't Remember\" are skipped.")
        }
        .confirmationDialog("Forget what memory knows?", isPresented: $confirmForget) {
            Button("Forget What Was Learned", role: .destructive) {
                if memory.forgetLearned(readAgain: false) { learnPastResult = nil }
            }
            if !memory.file.hasPaused {
                Button("Forget What Was Learned and Read Chats Again", role: .destructive) {
                    if memory.forgetLearned(readAgain: true) { learnFromPastChats() }
                }
            }
            Button("Forget Everything", role: .destructive) {
                if memory.forgetEverything(readAgain: false) {
                    loadAbout()
                    learnPastResult = nil
                }
            }
            if !memory.file.hasPaused {
                Button("Forget Everything and Read Chats Again", role: .destructive) {
                    if memory.forgetEverything(readAgain: true) {
                        loadAbout()
                        learnFromPastChats()
                    }
                }
            }
        } message: {
            Text("What was learned: the notes memory learned that you haven't written, edited, pinned or approved. Everything: every note but About you. Neither can be undone.")
        }
    }

    /// The line by "Read Past Chats…": what's waiting, or what the last
    /// read did, or that memory is up to date.
    private var learningSummary: String {
        if !memory.file.queue.isEmpty {
            return String(format: NSLocalizedString("%d parts of chats wait to be read.", comment: "memory"), memory.file.queue.count)
        }
        return learnPastResult ?? NSLocalizedString("Up to date.", comment: "memory: nothing waits to be read")
    }

    /// Every saved chat queued from its start; what it did, under the button.
    private func learnFromPastChats() {
        show(memory.learnFromPastChats())
    }

    private func show(_ result: (queued: Int, waiting: Int)) {
        let (queued, waiting) = result
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
        if learningModel == AppleSystemModel.id {
            if case .unavailable(let why) = AppleSystemModel.availability { return why }
            let code = MemoryReflector.languageCode()
            guard !ModelCardLanguages.covers(Array(AppleSystemModel.languageCodes), code) else { return nil }
            let name = Locale.current.localizedString(forLanguageCode: code) ?? code
            return String(format: NSLocalizedString("Apple doesn't list %@ for its model: it reads and writes it, but not as well as the languages it lists.", comment: ""), name)
        }
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

/// What a new chat gets from memory, exactly: the block as a chat chooses
/// it, for chats outside projects or in one project.
struct MemoryPreviewSheet: View {
    let projects: [ChatLibrary.Project]
    let onClose: () -> Void
    @ObservedObject private var memory = MemoryManager.shared
    @State private var project: UUID?

    var body: some View {
        let snapshot = memory.preview(project: project)
        VStack(alignment: .leading, spacing: 12) {
            Text("What chats get").font(.headline)
            Picker("Chat", selection: $project) {
                Text("Outside projects").tag(UUID?.none)
                ForEach(projects) { p in Text(p.name).tag(Optional(p.id)) }
            }
            if let snapshot, !snapshot.text.isEmpty {
                ScrollView {
                    Text(snapshot.text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(String(format: NSLocalizedString("About %d tokens, after the profile's system prompt. A model with a small context gets less (memory takes at most 5%% of it). Chats already open keep the block they started with until one of its notes changes.", comment: ""), snapshot.tokens))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Nothing: no note is sent to these chats now.").foregroundStyle(.secondary)
                Text("With notes, it reads like this:").font(.caption).foregroundStyle(.secondary)
                Text("What you know about the user from earlier chats. It may be outdated: what the user says now wins.\n- Answer briefly, in Russian\n- Builds an ESP32-S3 speaker with OTA updates\nRight now (from the user's last messages, a guess): Angry: the linker keeps failing. So: Brief, straight to the fix")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: snapshot?.text.isEmpty == false ? 460 : nil)
    }
}
