import Combine
import Foundation
import LLMTrayCore

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
        guard running == nil else { return }
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running == nil else { return }
                self.running = Task { @MainActor in
                    await self.runQueue()
                    self.running = nil
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
            status = .reading
            let outcome = await reflect(batch, embedder: embedder, modelPath: model)
            switch outcome {
            case .done:
                continue
            case .later(let reason):
                status = .waiting(reason)
                memory.change { $0.deferBatch(batch.id) }
                poke(after: min(30 * 60, 120 * Double(batch.attempts + 1)))
                return
            case .failed(let reason):
                NSLog("LLMTray memory: batch %d not read: %@", batch.id, reason)
                if batch.attempts + 1 >= Self.maxAttempts {
                    memory.change { $0.dropBatch(batch.id) }
                } else {
                    memory.change { $0.deferBatch(batch.id) }
                    poke(after: 300)
                    status = .idle
                    return
                }
            }
        }
        status = .idle
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
        let touchable = memory.file.notes.filter { note in
            note.isActive && (note.subject == .user || project.map { note.subject == .project($0) } == true)
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
                                                          inProject: project != nil),
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
                subject = op.scope == "project" ? project.map(MemorySubject.project) ?? .user : .user
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
                                   claim: MemoryReflection.Claim(statement: statement, aboutProject: subject != .user,
                                                                 message: message.text, quote: op.quote, before: message.before)))
        }
        guard !pending.isEmpty else {
            memory.change { $0.commit(batch: batch.id, changes: [], since: since, settings: settings, now: Date()) }
            return .done
        }

        // Verify: only claims the user, speaking for themselves, makes.
        switch await ask(MemoryReflection.verifyMessages(pending.map(\.claim)), maxTokens: 40 + 12 * pending.count, modelPath: modelPath) {
        case .success(let reply):
            guard let verdicts = MemoryReflection.parseVerdicts(reply, count: pending.count) else { return .failed("unreadable verify reply") }
            pending = zip(pending, verdicts).filter { $0.1 == .yes }.map(\.0)
        case .failure(let error):
            return error.outcome
        }

        // New and changed texts' vectors: a forgotten note's words aren't
        // learned again; a new note close to an old one is compared with it.
        let newTexts = pending.compactMap { p -> String? in p.op.action == .confirm || p.op.action == .forget ? nil : p.op.text }
        let newVectors: [String: [Float]]
        do {
            newVectors = Dictionary(zip(newTexts, try await embed(newTexts, kind: .document, with: embedder)), uniquingKeysWith: { a, _ in a })
        } catch {
            return .later(String(format: NSLocalizedString("The embedding model failed: %@", comment: "memory status"), error.localizedDescription))
        }
        let tombstones = memory.file.tombstones
        pending.removeAll { p in
            guard p.op.action == .add, let v = p.op.text.flatMap({ newVectors[$0] }) else { return false }
            return tombstones.contains { $0.subject == p.subject && $0.vector.map { MemoryReflection.cosine($0, v) >= Self.tombstoneFloor } == true }
        }

        // Adds against the notes they're close to (active or expired).
        var pairs: [(new: String, old: String)] = []
        var pairOwners: [(pendingIndex: Int, noteID: String)] = []
        for (i, p) in pending.enumerated() where p.op.action == .add {
            guard let text = p.op.text, let v = newVectors[text] else { continue }
            let close = memory.file.notes
                .filter { $0.subject == p.subject }
                .compactMap { note in vectors.vector(for: note).map { (note, MemoryReflection.cosine($0, v)) } }
                .filter { $0.1 >= Self.reconcileFloor }
                .sorted { $0.1 > $1.1 }
                .prefix(3)
            for (note, _) in close {
                pairs.append((new: text, old: note.text))
                pairOwners.append((i, note.id))
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
            switch p.op.action {
            case .add:
                guard let text = p.op.text, let kind = p.op.kind else { continue }
                let mine = pairOwners.indices.filter { pairOwners[$0].pendingIndex == i }
                if let same = mine.first(where: { relations[$0] == .same }) {
                    changes.append(.confirm(id: pairOwners[same].noteID, evidence: evidence))
                } else if let opposite = mine.first(where: { relations[$0] == .opposite }) {
                    changes.append(.supersede(id: pairOwners[opposite].noteID, text: text, evidence: evidence))
                } else {
                    changes.append(.add(subject: p.subject, topic: p.op.topic ?? "general", kind: kind, text: text,
                                        observed: kind == .observation ? p.op.observed : nil,
                                        confidence: kind == .observation ? .inferred : .stated, evidence: evidence))
                }
            case .confirm:
                changes.append(.confirm(id: p.op.id!, evidence: evidence))
            case .update:
                changes.append(.update(id: p.op.id!, text: p.op.text!, evidence: evidence))
            case .supersede:
                changes.append(.supersede(id: p.op.id!, text: p.op.text!, evidence: evidence))
            case .forget:
                let note = shown[p.op.id!]
                changes.append(.forget(id: p.op.id!, vector: note.flatMap { vectors.vector(for: $0) }))
            }
        }

        // One write: the notes, and the batch out of the queue.
        var touched: [String] = []
        guard memory.change({ touched = $0.commit(batch: batch.id, changes: changes, since: since, settings: settings, now: Date()) }) else {
            return .later(NSLocalizedString("The notes couldn't be saved.", comment: "memory status"))
        }
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

    static func languageName() -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: languageCode()) ?? "English"
    }
}
