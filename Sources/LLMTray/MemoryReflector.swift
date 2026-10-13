import Combine
import Foundation
import LLMTrayCore
import NaturalLanguage

/// Memory's reflection pass (adr/0024): reads the queue of what chats
/// said, a batch at a time, while the model has nothing else to do, and
/// writes what it learned. Each batch: the notes it may touch (by meaning,
/// the embedder), a reflect call, the quotes checked against what the user
/// typed, a verify call on the whole messages, a classify call for new
/// notes close to old ones, then one write with the batch leaving the
/// queue. Model calls are background work (BackgroundModelWork): any
/// request to the model preempts them, and the batch is tried again later.
@MainActor
final class MemoryReflector: ObservableObject {
    static let shared = MemoryReflector()

    enum Status: Equatable {
        case idle
        case reading
        /// Why it waits: no embedder, the model busy or not loaded.
        case waiting(String)
    }

    @Published private(set) var status: Status = .idle

    private weak var server: ServerManager?
    private var running: Task<Void, Never>?
    private var scheduled: DispatchWorkItem?
    /// A look asked for while a pass ran: scheduled when it ends.
    private var lookAfterRun: Double?
    private var watches: Set<AnyCancellable> = []

    /// Notes a reflect call is shown, by meaning, and more of their topics.
    static let candidatesByMeaning = 12
    static let candidatesAtMost = 24
    /// Below this, a note is no candidate for a batch.
    static let candidateFloor: Float = 0.35
    /// A new note this close to an old one is compared with it (classify).
    static let reconcileFloor: Float = 0.6
    /// This close to a forgotten note's text: not learned again.
    static let tombstoneFloor: Float = 0.92
    /// A batch failing this often (not just put off) is dropped.
    static let maxAttempts = 3

    private init() {}

    func attach(_ server: ServerManager) {
        self.server = server
        // The model free again, or something queued: a look soon.
        server.$activeRequestCount.removeDuplicates().filter { $0 == 0 }
            .sink { [weak self] _ in self?.poke(after: 20) }
            .store(in: &watches)
        MemoryManager.shared.$file.map(\.queue.count).removeDuplicates()
            .sink { [weak self] count in if count > 0 { self?.poke(after: 5) } }
            .store(in: &watches)
        poke(after: 30)
    }

    /// A look at the queue in `seconds`, unless one runs or comes sooner.
    func poke(after seconds: Double) {
        guard running == nil else {
            lookAfterRun = min(lookAfterRun ?? seconds, seconds)
            return
        }
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running == nil else { return }
                self.lookAfterRun = nil
                self.running = Task { @MainActor in
                    await self.runQueue()
                    self.running = nil
                    if let next = self.lookAfterRun {
                        self.lookAfterRun = nil
                        self.poke(after: next)
                    }
                }
            }
        }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private enum Outcome {
        case done
        /// Not now (the model busy, cut off, not loaded): the batch stays.
        case later(String)
        /// This batch didn't work out (an unreadable reply): counted.
        case failed(String)
        /// The notes file couldn't be written: everything waits.
        case stored(String)
    }

    private func runQueue() async {
        let memory = MemoryManager.shared
        while let batch = memory.file.queue.first {
            guard memory.isEnabled, !memory.unreadable, !memory.settings.kinds.isEmpty else {
                status = .idle
                return
            }
            guard let embedder = readyEmbedder() else {
                status = .waiting(NSLocalizedString("Learning needs the embedding model (Settings › Memory).", comment: "memory status"))
                return
            }
            guard let server, case .running = server.state, server.activeRequestCount == 0, let model = server.loadedModelPath else {
                status = .waiting(NSLocalizedString("Waits for the model to be free.", comment: "memory status"))
                poke(after: 120)
                return
            }
            guard !GenerationQueue.shared.hasInteractiveDemand else {
                status = .waiting(NSLocalizedString("Waits for a picture or song to finish.", comment: "memory status"))
                poke(after: 120)
                return
            }
            status = .reading
            let outcome = await reflect(batch, embedder: embedder, modelPath: model)
            // Every queue write checked: one that doesn't reach the disk
            // stops the loop (else the same batch would be read again now).
            let saving = NSLocalizedString("The notes couldn't be saved.", comment: "memory status")
            switch outcome {
            case .done:
                continue
            case .later(let reason):
                status = .waiting(reason)
                guard memory.change({ $0.deferBatch(batch.id) }) else { return waitForStorage(saving) }
                poke(after: min(30 * 60, 120 * Double(batch.attempts + 1)))
                return
            case .stored(let reason):
                return waitForStorage(reason)
            case .failed(let reason):
                NSLog("LLMTray memory: batch %d not read: %@", batch.id, reason)
                var failures = 0
                guard memory.change({ failures = $0.failBatch(batch.id) }) else { return waitForStorage(saving) }
                if failures >= Self.maxAttempts {
                    guard memory.change({ $0.dropBatch(batch.id) }) else { return waitForStorage(saving) }
                    continue
                }
                poke(after: 300)
                status = .idle
                return
            }
        }
        status = .idle
    }

    private func waitForStorage(_ reason: String) {
        status = .waiting(reason)
        poke(after: 300)
    }

    // MARK: Embedder

    private struct Embedder {
        let entry: EmbedderEntry
        let runner: EmbedRunner
    }

    /// The embedding model, installed; nil when it isn't (memory needs it).
    private func readyEmbedder() -> Embedder? {
        let embedders = ProjectIndexer.shared.embedders
        guard let entry = try? embedders.defaultEntry(), embedders.isReady(entry) else { return nil }
        return Embedder(entry: entry, runner: embedders.makeRunner(entry))
    }

    private func embed(_ texts: [String], kind: EmbedRunnerMessage.Kind, with embedder: Embedder) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var vectors: [[Float]] = []
        for range in embedder.runner.documentBatches(texts) {
            // A picture or song asking for the GPU meanwhile: stop here.
            if GenerationQueue.shared.hasInteractiveDemand {
                embedder.runner.setPaused(true)
                throw EmbedRunner.Failure.paused
            }
            let result = try await embedder.runner.embed(Array(texts[range]), kind: kind, timeout: 60)
            vectors += (0..<result.count).map(result.floats)
        }
        guard vectors.count == texts.count else { throw EmbedRunner.Failure.protocolViolation("vector count") }
        return vectors
    }

    // MARK: Vectors

    static var vectorsPath: String { MemoryManager.directory + "/vectors.json" }

    private func loadVectors(model: String) -> MemoryVectors {
        guard let data = FileManager.default.contents(atPath: Self.vectorsPath),
              let vectors = try? JSONDecoder().decode(MemoryVectors.self, from: data), vectors.model == model else {
            // Another embedder: tombstones' vectors are of the old one.
            MemoryManager.shared.change { $0.dropTombstoneVectors() }
            return MemoryVectors(model: model)
        }
        return vectors
    }

    /// A note's embedding as last stored, of its current text.
    static func storedVector(for note: MemoryNote) -> [Float]? {
        guard let data = FileManager.default.contents(atPath: vectorsPath),
              let vectors = try? JSONDecoder().decode(MemoryVectors.self, from: data) else { return nil }
        return vectors.vector(for: note)
    }

    private func saveVectors(_ vectors: MemoryVectors) {
        guard let data = try? JSONEncoder().encode(vectors) else { return }
        try? FileManager.default.createDirectory(atPath: MemoryManager.directory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: Self.vectorsPath), options: .atomic)
    }

    // MARK: The pass

    private func reflect(_ batch: MemoryBatch, embedder: Embedder, modelPath: String) async -> Outcome {
        let memory = MemoryManager.shared
        let settings = memory.settings
        let since = memory.file.generation
        // The runner was started for this pass: stopped after it, unless
        // project files keep it.
        defer {
            if !(ProjectIndexer.shared.isEnabled && ProjectIndexer.shared.isEmbedderReady) { embedder.runner.stop() }
        }
        // Paused while a picture or song wants the GPU, whoever owns it.
        embedder.runner.setPaused(GenerationQueue.shared.hasInteractiveDemand)
        guard !embedder.runner.isPaused else { return .later(NSLocalizedString("Waits for a picture or song to finish.", comment: "memory status")) }

        // Every note's vector of its current text; the batch's messages'.
        var vectors = loadVectors(model: embedder.entry.vectorSetModel)
        let messageVectors: [[Float]]
        do {
            try await embedder.runner.start()
            let missing = vectors.missing(memory.file.notes)
            for (note, vector) in zip(missing, try await embed(missing.map(\.text), kind: .document, with: embedder)) {
                vectors.entries[note.id] = MemoryVectors.Entry(textHash: MemoryVectors.textHash(note.text), vector: vector)
            }
            vectors.prune(to: memory.file.notes)
            saveVectors(vectors)
            messageVectors = try await embed(batch.messages.map { String(MemoryReflection.typedText($0.text).prefix(2000)) },
                                             kind: .query, with: embedder)
        } catch EmbedRunner.Failure.paused {
            return .later(NSLocalizedString("Waits for a picture or song to finish.", comment: "memory status"))
        } catch {
            return .later(String(format: NSLocalizedString("The embedding model failed: %@", comment: "memory status"), error.localizedDescription))
        }

        // The notes this batch may touch: by meaning, then their topics.
        let project = settings.projectMemory ? batch.project : nil
        // Where what this chat teaches goes: the model's choice when
        // learning is shared, else this chat's own place (nil: project
        // notes off, nothing learned in a project's chats).
        let fixedSubject = settings.shareLearned ? nil : settings.learnedSubject(project: batch.project)
        guard settings.learns(inProject: batch.project), settings.shareLearned || fixedSubject != nil else {
            return commit(batch, changes: [], since: since, vectors: vectors, newVectors: [:])
        }
        // The notes it may change: kept apart, only its own place's; shared,
        // every one this chat sees. Never pinned ones (the user's alone).
        let touchable = memory.file.notes.filter { note in
            !note.pinned && (fixedSubject.map { note.subject == $0 } ?? true) && settings.allows(note, project: batch.project)
        }
        func score(_ note: MemoryNote) -> Float {
            guard let v = vectors.vector(for: note) else { return 0 }
            return messageVectors.map { MemoryReflection.cosine(v, $0) }.max() ?? 0
        }
        let ranked = touchable.map { ($0, score($0)) }.filter { $0.1 >= Self.candidateFloor }.sorted { $0.1 > $1.1 }
        var candidates: [MemoryNote] = ranked.prefix(Self.candidatesByMeaning).map { $0.0 }
        let topics = Set(candidates.map(\.topic))
        for note in touchable where topics.contains(note.topic) && !candidates.contains(where: { $0.id == note.id }) {
            guard candidates.count < Self.candidatesAtMost else { break }
            candidates.append(note)
        }
        let shown = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })

        // Reflect.
        let topicList = Array(Set(MemoryTopics.builtIn + memory.file.notes.map(\.topic))).sorted()
        let reflectReply: String
        switch await ask(MemoryReflection.reflectMessages(batch: batch, candidates: candidates, topics: topicList,
                                                          language: Self.languageName(), kinds: settings.kinds,
                                                          inProject: settings.shareLearned && project != nil),
                         maxTokens: 1500, modelPath: modelPath) {
        case .success(let reply): reflectReply = reply
        case .failure(let error): return error.outcome
        }
        guard let operations = MemoryReflection.parseOperations(reflectReply) else { return .failed("unreadable reflect reply") }

        // What survives the code's checks: the user's own words, ids it was
        // shown, kinds that are on, texts a note may hold.
        struct Pending {
            var op: MemoryReflection.Operation
            var message: MemoryBatchMessage
            var subject: MemorySubject
            var claim: MemoryReflection.Claim
        }
        var pending: [Pending] = []
        for op in operations {
            guard let message = MemoryReflection.source(of: op.quote, in: batch) else { continue }
            let note = op.id.flatMap { shown[$0] }
            let subject: MemorySubject
            let statement: String
            switch op.action {
            case .add:
                guard let kind = op.kind, settings.kinds.contains(kind), let text = op.text, MemoryText.problem(text) == nil else { continue }
                subject = fixedSubject ?? (op.scope == "project" ? project.map(MemorySubject.project) ?? .user : .user)
                statement = kind == .observation ? (op.observed ?? text) : text
            case .confirm:
                guard let note else { continue }
                subject = note.subject
                statement = note.text
            case .update, .supersede:
                guard let note, let text = op.text, MemoryText.problem(text) == nil else { continue }
                subject = note.subject
                statement = text
            case .forget:
                guard let note else { continue }
                subject = note.subject
                statement = "The user asks to forget this, or says it is no longer true: \(note.text)"
            }
            pending.append(Pending(op: op, message: message, subject: subject,
                                   claim: MemoryReflection.Claim(statement: statement, aboutProject: { if case .project = subject { return true } else { return false } }(),
                                                                 message: message.text, quote: op.quote, before: message.before)))
        }
        guard !pending.isEmpty else {
            return commit(batch, changes: [], since: since, vectors: vectors, newVectors: [:])
        }

        // Verify: only claims the user, speaking for themselves, makes.
        switch await ask(MemoryReflection.verifyMessages(pending.map(\.claim)), maxTokens: 40 + 12 * pending.count, modelPath: modelPath) {
        case .success(let reply):
            guard let verdicts = MemoryReflection.parseVerdicts(reply, count: pending.count) else { return .failed("unreadable verify reply") }
            pending = zip(pending, verdicts).filter { $0.1 == .yes }.map(\.0)
        case .failure(let error):
            return error.outcome
        }

        // New and changed texts' vectors.
        let newTexts = Array(Set(pending.compactMap { p -> String? in p.op.action == .confirm || p.op.action == .forget ? nil : p.op.text }))
        let newVectors: [String: [Float]]
        do {
            newVectors = Dictionary(zip(newTexts, try await embed(newTexts, kind: .document, with: embedder)), uniquingKeysWith: { a, _ in a })
        } catch {
            return .later(String(format: NSLocalizedString("The embedding model failed: %@", comment: "memory status"), error.localizedDescription))
        }

        // Reconcile against a working set: every new or changed text with
        // the notes close to it (active or expired, not its own) and the
        // batch's earlier additions; the model says how each pair relates.
        enum Target { case note(MemoryNote), earlierAdd(Int) }
        var pairs: [(new: String, old: String)] = []
        var owners: [(item: Int, target: Target)] = []
        for (i, p) in pending.enumerated() where [.add, .update, .supersede].contains(p.op.action) {
            guard let text = p.op.text, let v = newVectors[text] else { continue }
            // An update: only notes the batch may change (a pinned one, or a
            // kind that's off, would turn it into a merge that can't be
            // made). An add: pinned ones too -- "My name is …" next to About
            // you's Name is the same, and confirming a pinned note writes
            // nothing.
            // An add is also compared with every note this chat sees (About
            // you's included): the same as one it may not change confirms it,
            // and the write drops that -- nothing new, no duplicate.
            let close = memory.file.notes
                .filter { note in
                    guard note.id != p.op.id, settings.kinds.contains(note.kind) || memory.file.isAbout(note) else { return false }
                    if p.op.action == .add { return note.subject == p.subject || settings.allows(note, project: batch.project) }
                    return note.subject == p.subject && !note.pinned
                }
                .compactMap { note in vectors.vector(for: note).map { (note, MemoryReflection.cosine($0, v)) } }
                .filter { $0.1 >= Self.reconcileFloor }
                .sorted { $0.1 > $1.1 }
                .prefix(3)
            for (note, _) in close {
                pairs.append((new: text, old: note.text))
                owners.append((i, .note(note)))
            }
            guard p.op.action == .add else { continue }
            for j in 0..<i where pending[j].op.action == .add && pending[j].subject == p.subject {
                guard let earlier = pending[j].op.text, let w = newVectors[earlier], MemoryReflection.cosine(v, w) >= Self.reconcileFloor else { continue }
                pairs.append((new: text, old: earlier))
                owners.append((i, .earlierAdd(j)))
            }
        }
        var relations: [MemoryReflection.Relation] = []
        if !pairs.isEmpty {
            switch await ask(MemoryReflection.classifyMessages(pairs), maxTokens: 40 + 12 * pairs.count, modelPath: modelPath) {
            case .success(let reply):
                guard let parsed = MemoryReflection.parseRelations(reply, count: pairs.count) else { return .failed("unreadable classify reply") }
                relations = parsed
            case .failure(let error):
                return error.outcome
            }
        }

        // The changes, in the reflect call's order.
        var changes: [MemoryChange] = []
        for (i, p) in pending.enumerated() {
            let evidence = MemoryEvidence(chat: batch.chat, seq: p.message.seq, date: p.message.date, quote: p.op.quote)
            let mine = owners.indices.filter { owners[$0].item == i }
            func related(_ relation: MemoryReflection.Relation) -> Target? {
                mine.first { relations[$0] == relation }.map { owners[$0].target }
            }
            let text = p.op.text ?? ""
            let vector = newVectors[text]
            let wrongLanguage = Self.isWrongLanguage(text)
            switch p.op.action {
            case .add:
                guard let kind = p.op.kind else { continue }
                if case .note(let note)? = related(.same) {
                    changes.append(.confirm(id: note.id, evidence: evidence))
                } else if case .earlierAdd? = related(.same) {
                    // Said twice in this batch: the first stands.
                    continue
                } else if case .note(let note)? = related(.opposite), !note.pinned, fixedSubject.map({ note.subject == $0 }) ?? true {
                    changes.append(.supersede(id: note.id, text: text, evidence: evidence, vector: vector, wrongLanguage: wrongLanguage))
                } else {
                    // New -- also when it contradicts a note this chat may
                    // not change (the user's, another place's): its own place
                    // gets its own note.
                    changes.append(.add(subject: p.subject, topic: MemoryTopics.learned(p.op.topic), kind: kind, text: text,
                                        observed: kind == .observation ? p.op.observed : nil,
                                        confidence: kind == .observation ? .inferred : .stated, evidence: evidence,
                                        vector: vector, wrongLanguage: wrongLanguage))
                }
            case .confirm:
                changes.append(.confirm(id: p.op.id!, evidence: evidence))
            case .update, .supersede:
                let id = p.op.id!
                if p.op.action == .update, case .note(let other)? = related(.same), let mine = shown[id] {
                    // Now the same as another note: the two become one.
                    let (keep, drop) = mine.created <= other.created ? (mine.id, other.id) : (other.id, mine.id)
                    changes.append(.merge(keep: keep, drop: drop, source: id, text: text, evidence: evidence,
                                          vector: vector, wrongLanguage: wrongLanguage))
                } else if p.op.action == .update {
                    changes.append(.update(id: id, text: text, evidence: evidence, vector: vector, wrongLanguage: wrongLanguage))
                } else {
                    changes.append(.supersede(id: id, text: text, evidence: evidence, vector: vector, wrongLanguage: wrongLanguage))
                }
            case .forget:
                let note = shown[p.op.id!]
                changes.append(.forget(id: p.op.id!, vector: note.flatMap { vectors.vector(for: $0) }))
            }
        }
        return commit(batch, changes: changes, since: since, vectors: vectors, newVectors: newVectors)
    }

    /// One write: the changes (checked again against the store, the
    /// settings and the projects as they are now, tombstones included), and
    /// the batch out of the queue. The vectors are a cache written after.
    private func commit(_ batch: MemoryBatch, changes: [MemoryChange], since: Int, vectors: MemoryVectors,
                        newVectors: [String: [Float]]) -> Outcome {
        let memory = MemoryManager.shared
        let settings = memory.settings
        let projects = Set(ChatLibraryStore.shared.library.projects.map(\.id))
        var touched: [String] = []
        guard memory.change({ touched = $0.commit(batch: batch.id, changes: changes, since: since, settings: settings,
                                                  liveProjects: projects, now: Date()) }) else {
            return .stored(NSLocalizedString("The notes couldn't be saved.", comment: "memory status"))
        }
        var vectors = vectors
        for id in touched {
            guard let note = memory.file.note(id), let v = newVectors[note.text] else { continue }
            vectors.entries[id] = MemoryVectors.Entry(textHash: MemoryVectors.textHash(note.text), vector: v)
        }
        vectors.prune(to: memory.file.notes)
        saveVectors(vectors)
        NSLog("LLMTray memory: batch %d read: %d change(s)", batch.id, touched.count)
        return .done
    }

    /// One background call to the loaded model: its answer, or why not now.
    private func ask(_ messages: [[String: Any]], maxTokens: Int, modelPath: String) async -> Result<String, OutcomeError> {
        let style = ModelDiscovery.thinkingStyle(forModelPath: modelPath)
        var fields = Thinking.requestFields(style: style, effort: .off)
        fields["temperature"] = 0.2
        let outcome = await BackgroundModelWork.complete(port: UserDefaults.standard[Pref.port], modelAlias: nil, messages: messages,
                                                         maxTokens: maxTokens, fields: fields)
        switch outcome {
        case .done(let text): return .success(text)
        case .busy, .preempted: return .failure(OutcomeError(.later(NSLocalizedString("Waits for the model to be free.", comment: "memory status"))))
        case .notLoaded: return .failure(OutcomeError(.later(NSLocalizedString("Waits for the model to be loaded.", comment: "memory status"))))
        case .failed(let reason): return .failure(OutcomeError(.failed(reason)))
        }
    }

    private struct OutcomeError: Error {
        let outcome: Outcome
        init(_ outcome: Outcome) { self.outcome = outcome }
    }

    // MARK: Language

    /// The notes' language: the setting, else the app's.
    static func languageCode() -> String {
        let set = UserDefaults.standard[Pref.memoryLanguage]
        if set != "auto", !set.isEmpty { return set }
        return Bundle.main.preferredLocalizations.first.map { String($0.prefix(2)) } ?? "en"
    }

    /// A text long enough to tell, confidently in another language than
    /// memory's: marked for the tidy-up to rewrite.
    static func isWrongLanguage(_ text: String) -> Bool {
        guard text.count >= 40 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first, probability >= 0.8 else { return false }
        return !language.rawValue.hasPrefix(languageCode())
    }

    static func languageName() -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: languageCode()) ?? "English"
    }
}
