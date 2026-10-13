import Foundation

/// The reflection pass's pure parts (adr/0024): the prompts, reading the
/// model's replies, where a quote came from, and how a batch's outcome is
/// written. The app runs the calls (MemoryReflector).
public enum MemoryReflection {
    // MARK: Operations

    public struct Operation: Equatable, Sendable {
        public enum Action: String, Sendable { case add, confirm, update, supersede, forget }
        public var action: Action
        public var id: String?
        /// "user" or "project" (add only).
        public var scope: String?
        public var topic: String?
        public var kind: MemoryKind?
        public var text: String?
        public var observed: String?
        public var quote: String

        public init(action: Action, id: String? = nil, scope: String? = nil, topic: String? = nil, kind: MemoryKind? = nil,
                    text: String? = nil, observed: String? = nil, quote: String) {
            self.action = action
            self.id = id
            self.scope = scope
            self.topic = topic
            self.kind = kind
            self.text = text
            self.observed = observed
            self.quote = quote
        }
    }

    /// At most this many operations of a pass are used.
    public static let maxOperations = 12

    /// The JSON object in a reply: the reply itself, or its first `{` to
    /// its last `}` (a model wrapping it in prose or a code fence).
    static func object(_ reply: String) -> [String: Any]? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [trimmed] + [trimmed.firstIndex(of: "{").flatMap { start in
            trimmed.lastIndex(of: "}").map { String(trimmed[start...$0]) }
        }].compactMap { $0 }
        for text in candidates {
            if case .success(let parsed) = LenientJSON.parse(text), let object = parsed.value as? [String: Any] { return object }
        }
        return nil
    }

    /// The operations in a reflect reply; nil when it can't be read. Ones
    /// missing what they need are left out.
    public static func parseOperations(_ reply: String) -> [Operation]? {
        guard let object = object(reply), let ops = object["ops"] as? [Any] else { return nil }
        var result: [Operation] = []
        for case let op as [String: Any] in ops {
            guard let action = (op["op"] as? String).flatMap(Operation.Action.init(rawValue:)),
                  let quote = (op["quote"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty else { continue }
            let text = (op["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = op["id"] as? String
            switch action {
            case .add: guard text?.isEmpty == false else { continue }
            case .update, .supersede: guard id != nil, text?.isEmpty == false else { continue }
            case .confirm, .forget: guard id != nil else { continue }
            }
            result.append(Operation(
                action: action, id: id, scope: op["scope"] as? String, topic: op["topic"] as? String,
                kind: (op["kind"] as? String).flatMap(MemoryKind.init(rawValue:)), text: text,
                observed: (op["observed"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), quote: quote))
            if result.count == maxOperations { break }
        }
        return result
    }

    // MARK: Prompts

    /// One note as the model sees it among the candidates.
    static func candidateLine(_ note: MemoryNote) -> String {
        let scope = note.subject == .user ? "user" : "project"
        let observed = note.observed.map { " (observed: \($0))" } ?? ""
        return "\(note.id) [\(note.kind.rawValue), \(note.topic), \(scope)] \(note.text)\(observed)"
    }

    /// The reflect call: the batch, the notes it may touch, the topics.
    public static func reflectMessages(batch: MemoryBatch, candidates: [MemoryNote], topics: [String], language: String,
                                       kinds: Set<MemoryKind>, inProject: Bool) -> [[String: Any]] {
        let kindList = MemoryKind.allCases.filter(kinds.contains).map(\.rawValue).joined(separator: ", ")
        let scopeLine = inProject
            ? "- scope: \"project\" for facts about the work in this chat's project, \"user\" for the person (tone, language, habits, hardware).\n"
            : "- scope is always \"user\".\n"
        let system = """
        You read what a user wrote in a chat and keep short notes about them for their later chats. Reply with ONE JSON object: {"ops": [...]}.

        Each op is one of:
        {"op":"add","scope":"user","topic":"...","kind":"...","text":"...","observed":"...","quote":"..."}
        {"op":"confirm","id":"...","quote":"..."}: an existing note the user said again
        {"op":"update","id":"...","text":"...","quote":"..."}: the same thing, said better or more precisely
        {"op":"supersede","id":"...","text":"...","quote":"..."}: the user now wants the opposite of a note
        {"op":"forget","id":"...","quote":"..."}: the user asked to forget a note, or said it's no longer true

        - Only what the user says about themselves, their work, or how they want answers. Durable things only: not moods, passing states, or one-off tasks.
        - "quote": the user's own words, copied exactly, a few words to one sentence.
        - "text": one short statement, under 160 characters, written in \(language) whatever the chat's language.
        - When an existing note says the same thing, confirm or update it instead of adding.
        - kind, one of \(kindList): preference = how they want things; correction = they corrected the assistant; fact = about them or their work; observation = something they did that may mean something ("observed": what happened; "text": what it may mean).
        \(scopeLine)- topic: one of \(topics.joined(separator: ", ")), or a new short English key.
        - Never links, file paths, commands, or secrets.
        If nothing is worth keeping, reply {"ops": []}.
        """
        var user = "Existing notes:\n"
        user += candidates.isEmpty ? "(none)\n" : candidates.map(candidateLine).joined(separator: "\n") + "\n"
        user += "\nThe user's messages, oldest first. \"Before\" is the start of the assistant's answer before it, for context only: never quote it.\n"
        for message in batch.messages {
            user += "\n#\(message.seq)\n"
            if let before = message.before, !before.isEmpty { user += "Before: \(before)\n" }
            user += "User: \(message.text)\n"
        }
        return [["role": "system", "content": system], ["role": "user", "content": user]]
    }

    public enum Verdict: String, Sendable { case yes, no, unclear }

    /// A claim for the verify call: what it says, about whom, and the
    /// whole message its quote is in.
    public struct Claim: Equatable, Sendable {
        public var statement: String
        public var aboutProject: Bool
        public var message: String
        public var quote: String
        public var before: String?

        public init(statement: String, aboutProject: Bool, message: String, quote: String, before: String?) {
            self.statement = statement
            self.aboutProject = aboutProject
            self.message = message
            self.quote = quote
            self.before = before
        }
    }

    /// The quote marked in its message (⟦…⟧), found as `source` found it.
    static func marked(_ message: String, quote: String) -> String {
        if let range = message.range(of: quote, options: [.caseInsensitive]) {
            return message.replacingCharacters(in: range, with: "⟦\(message[range])⟧")
        }
        return message + "\n⟦\(quote)⟧"
    }

    public static func verifyMessages(_ claims: [Claim]) -> [[String: Any]] {
        let system = """
        For each claim, decide whether the user, speaking for themselves, says it in their message. Their quote is marked ⟦like this⟧. \
        A request to translate or rewrite something, an example, a hypothetical, someone else's words, or a negation does not support the claim. \
        Reply with ONE JSON object: {"verdicts": ["yes" | "no" | "unclear", ...]}, one per claim, in order.
        """
        var user = ""
        for (i, claim) in claims.enumerated() {
            user += "Claim \(i + 1) (about \(claim.aboutProject ? "the user's project" : "the user")): \(claim.statement)\n"
            if let before = claim.before, !before.isEmpty { user += "Assistant before it: \(before)\n" }
            user += "User's message: \(marked(claim.message, quote: claim.quote))\n\n"
        }
        return [["role": "system", "content": system], ["role": "user", "content": user]]
    }

    /// The verdicts, one per claim; nil when the reply can't be read or
    /// has another count.
    public static func parseVerdicts(_ reply: String, count: Int) -> [Verdict]? {
        guard let list = object(reply)?["verdicts"] as? [Any], list.count == count else { return nil }
        return list.map { ($0 as? String).flatMap { Verdict(rawValue: $0.lowercased()) } ?? .unclear }
    }

    public enum Relation: String, Sendable { case same, opposite, narrower, different }

    public static func classifyMessages(_ pairs: [(new: String, old: String)]) -> [[String: Any]] {
        let system = """
        For each pair, compare the NEW note with the OLD one. Answer "same" (they say the same thing, maybe in other words or another language), \
        "opposite" (the new one contradicts or replaces the old one), "narrower" (the new one is a more specific case, and both can be true), \
        or "different" (they are about different things). Reply with ONE JSON object: {"relations": [...]}, one per pair, in order.
        """
        let user = pairs.enumerated().map { i, pair in "Pair \(i + 1)\nNEW: \(pair.new)\nOLD: \(pair.old)" }.joined(separator: "\n\n")
        return [["role": "system", "content": system], ["role": "user", "content": user]]
    }

    public static func parseRelations(_ reply: String, count: Int) -> [Relation]? {
        guard let list = object(reply)?["relations"] as? [Any], list.count == count else { return nil }
        return list.map { ($0 as? String).flatMap { Relation(rawValue: $0.lowercased()) } ?? .different }
    }

    // MARK: Provenance

    /// Longer than this, a paragraph counts as pasted, not typed.
    public static let pasteLength = 1_500

    /// What of a message the user typed: without code fences, quoted lines
    /// (`>`), and paragraphs long enough to be pasted.
    public static func typedText(_ text: String) -> String {
        var kept: [String] = []
        var inFence = false
        var paragraph: [String] = []
        func flush() {
            let joined = paragraph.joined(separator: "\n")
            if !joined.isEmpty, joined.count <= pasteLength { kept.append(joined) }
            paragraph = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                inFence.toggle()
                continue
            }
            if inFence || trimmed.hasPrefix(">") { continue }
            if trimmed.isEmpty { flush() } else { paragraph.append(line) }
        }
        flush()
        return kept.joined(separator: "\n\n")
    }

    /// The message of `batch` whose typed text holds `quote` (case and
    /// spaces folded); nil when none does: then it isn't the user's words.
    public static func source(of quote: String, in batch: MemoryBatch) -> MemoryBatchMessage? {
        let q = MemoryText.normalizedQuote(quote)
        guard q.count >= 3 else { return nil }
        return batch.messages.first { MemoryText.normalizedQuote(typedText($0.text)).contains(q) }
    }

    // MARK: Vectors

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}

/// One change a reflection pass resolved to, written with its batch.
public enum MemoryChange: Equatable, Sendable {
    case add(subject: MemorySubject, topic: String, kind: MemoryKind, text: String, observed: String?,
             confidence: MemoryConfidence, evidence: MemoryEvidence)
    case confirm(id: String, evidence: MemoryEvidence)
    case update(id: String, text: String, evidence: MemoryEvidence)
    case supersede(id: String, text: String, evidence: MemoryEvidence)
    case forget(id: String, vector: [Float]?)
}

extension MemoryFile {
    /// Evidence kept per note, newest last.
    public static let maxEvidence = 5

    /// A batch's outcome: its changes, and the batch leaving the queue, in
    /// one write. Each change is checked again here (the store may have
    /// moved on while the pass ran): a note that's gone or pinned isn't
    /// changed, a change of a note the user touched since the pass began
    /// (`since`: the generation then) is dropped, as is anything from a
    /// chat that opted out meanwhile. Returns the ids of the notes added
    /// or changed.
    @discardableResult
    public mutating func commit(batch id: Int, changes: [MemoryChange], since: Int, settings: MemorySettings, now: Date) -> [String] {
        guard let batch = queue.first(where: { $0.id == id }) else { return [] }
        queue.removeAll { $0.id == id }
        var touched: [String] = []
        if !optedOut.contains(batch.chat) {
            for change in changes {
                if let note = apply(change, since: since, settings: settings, now: now) { touched.append(note) }
            }
        }
        _ = bumpGeneration()
        return touched
    }

    /// A pass that failed for now: tried again later.
    public mutating func deferBatch(_ id: Int) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[i].attempts += 1
    }

    public mutating func dropBatch(_ id: Int) {
        queue.removeAll { $0.id == id }
    }

    private mutating func apply(_ change: MemoryChange, since: Int, settings: MemorySettings, now: Date) -> String? {
        func index(_ id: String) -> Int? {
            guard let i = notes.firstIndex(where: { $0.id == id }), !notes[i].pinned, notes[i].changed <= since else { return nil }
            return i
        }
        func addEvidence(_ i: Int, _ evidence: MemoryEvidence) {
            notes[i].evidence.removeAll { $0.chat == evidence.chat && $0.seq == evidence.seq }
            notes[i].evidence.append(evidence)
            notes[i].evidence = Array(notes[i].evidence.suffix(Self.maxEvidence))
        }
        switch change {
        case let .add(subject, topic, kind, text, observed, confidence, evidence):
            guard settings.kinds.contains(kind), MemoryText.problem(text) == nil,
                  !tombstones.contains(where: { $0.subject == subject && $0.blocks(quote: evidence.quote) }) else { return nil }
            guard let id = add(subject: subject, topic: topic, kind: kind, text: text, observed: observed, now: now,
                               reviewed: false, confidence: confidence) else { return nil }
            let i = notes.firstIndex { $0.id == id }!
            notes[i].evidence = [evidence]
            return id
        case let .confirm(id, evidence):
            guard let i = index(id) else { return nil }
            addEvidence(i, evidence)
            notes[i].confirmed = now
            // Back from expired: said again.
            if notes[i].expired != nil { notes[i].expired = nil; notes[i].changed = generation + 1 }
            if settings.kinds.contains(.preference) { promoteIfConfirmed(i) }
            return id
        case let .update(id, text, evidence), let .supersede(id, text, evidence):
            guard let i = index(id), MemoryText.problem(text) == nil else { return nil }
            if notes[i].text != text {
                notes[i].history.append(MemoryHistoryEntry(text: notes[i].text, date: now))
                notes[i].history = Array(notes[i].history.suffix(3))
                notes[i].text = text
            }
            if case .supersede = change {
                // The user's own words now: what they said.
                notes[i].confidence = .stated
                notes[i].evidence = []
            }
            addEvidence(i, evidence)
            notes[i].confirmed = now
            notes[i].expired = nil
            // Written by the model now, not as the user reviewed it.
            notes[i].reviewed = false
            notes[i].changed = generation + 1
            return id
        case let .forget(id, vector):
            guard index(id) != nil else { return nil }
            forget(id, vector: vector, now: now)
            return nil
        }
    }

    /// An observation said again in another chat on another day becomes
    /// a preference (still inferred: a guess the model is told is one).
    private mutating func promoteIfConfirmed(_ i: Int) {
        guard notes[i].kind == .observation else { return }
        let chats = Set(notes[i].evidence.map(\.chat))
        let days = Set(notes[i].evidence.map { Calendar(identifier: .gregorian).startOfDay(for: $0.date) })
        guard chats.count >= 2, days.count >= 2 else { return }
        notes[i].kind = .preference
        notes[i].changed = generation + 1
    }

    mutating func bumpGeneration() -> Int {
        generation += 1
        return generation
    }
}

/// The notes' embeddings (memory/vectors.json): a cache, rebuilt from the
/// notes' texts when lost or when the embedder changes (`model`).
public struct MemoryVectors: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Of the text it's the embedding of: a changed note is embedded again.
        public var textHash: String
        /// Float32, little-endian.
        public var data: Data

        public var vector: [Float] {
            data.withUnsafeBytes { raw in raw.bindMemory(to: Float.self).map { Float(bitPattern: UInt32(littleEndian: $0.bitPattern)) } }
        }

        public init(textHash: String, vector: [Float]) {
            self.textHash = textHash
            var d = Data(capacity: vector.count * 4)
            for v in vector { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
            data = d
        }
    }

    /// The embedder's vector set (EmbedderEntry.vectorSetModel).
    public var model: String
    public var entries: [String: Entry] = [:]

    public init(model: String) { self.model = model }

    public static func textHash(_ text: String) -> String { MemoryTombstone.hash(text) }

    /// The note's vector when it's of its current text.
    public func vector(for note: MemoryNote) -> [Float]? {
        guard let entry = entries[note.id], entry.textHash == Self.textHash(note.text) else { return nil }
        return entry.vector
    }

    /// The notes with no vector of their current text.
    public func missing(_ notes: [MemoryNote]) -> [MemoryNote] { notes.filter { vector(for: $0) == nil } }

    /// Only the notes there are.
    public mutating func prune(to notes: [MemoryNote]) {
        let ids = Set(notes.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
    }
}
