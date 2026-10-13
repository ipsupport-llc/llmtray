import CryptoKit
import Foundation

// Memory between chats (adr/0024): short notes about the user and their
// projects, chosen for a chat within a token budget and aging by kind.
// This file is the store and the choice; nothing here talks to a model.

public enum MemoryKind: String, Codable, CaseIterable, Sendable {
    case fact, preference, correction, observation
}

public enum MemoryConfidence: String, Codable, Sendable {
    /// The user said it (or wrote the note).
    case stated
    /// Read from what the user did: shown to the model as a guess.
    case inferred

    /// Its weight in the ranking.
    var weight: Double { self == .stated ? 1.0 : 0.6 }
}

/// Whom a note is about: the user, or one project (by id, never by its
/// name, which can change).
public enum MemorySubject: Hashable, Sendable, Codable {
    case user
    case project(UUID)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "user" {
            self = .user
        } else if raw.hasPrefix("project:"), let id = UUID(uuidString: String(raw.dropFirst(8))) {
            self = .project(id)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "subject \(raw)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .user: try c.encode("user")
        case .project(let id): try c.encode("project:" + id.uuidString)
        }
    }
}

/// Where a learned note came from: the user's own words in a chat.
public struct MemoryEvidence: Codable, Equatable, Sendable {
    public var chat: UUID
    /// The message's sequence number in the chat; nil when unknown.
    public var seq: Int?
    public var date: Date
    /// At most `MemoryText.maxQuote` characters.
    public var quote: String

    public init(chat: UUID, seq: Int?, date: Date, quote: String) {
        self.chat = chat
        self.seq = seq
        self.date = date
        self.quote = String(quote.prefix(MemoryText.maxQuote))
    }
}

/// A text a note had before it was changed: an audit trail, never sent.
public struct MemoryHistoryEntry: Codable, Equatable, Sendable {
    public var text: String
    public var date: Date
}

public struct MemoryNote: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var subject: MemorySubject
    /// A retrieval category (MemoryTopics); several notes may share one.
    public var topic: String
    public var kind: MemoryKind
    /// The claim (or, for an observation, what it may mean).
    public var text: String
    /// An observation's what happened, apart from its reading in `text`.
    public var observed: String?
    public var evidence: [MemoryEvidence]
    public var created: Date
    /// Last confirmed: its age counts from here.
    public var confirmed: Date
    public var confidence: MemoryConfidence
    /// The user wrote, edited, pinned or approved it.
    public var reviewed: Bool
    /// Never expires; nothing but the user changes it.
    public var pinned: Bool
    /// The last replaced texts, newest last.
    public var history: [MemoryHistoryEntry]
    /// When it expired; nil while active.
    public var expired: Date?
    /// The store's generation at its last change: a chat's snapshot that
    /// holds it is stale once this is newer than the snapshot.
    public var changed: Int

    public var isActive: Bool { expired == nil }
}

/// The user's memory settings (Settings › Memory).
public struct MemorySettings: Equatable, Sendable {
    public var enabled: Bool
    /// The kinds learned and sent to the model.
    public var kinds: Set<MemoryKind>
    /// The memory block's room in a request, in tokens.
    public var budgetTokens: Int
    /// Active notes kept at most; over it, the weakest expire.
    public var maxActive: Int
    /// Days after which a note counts half (it expires below 0.1).
    public var halfLifeDays: [MemoryKind: Double]
    /// Expired notes are deleted this many days after expiring.
    public var deleteExpiredAfterDays: Int
    /// Notes about a chat's project are sent in its chats.
    public var projectMemory: Bool

    public static let defaultHalfLives: [MemoryKind: Double] = [.observation: 30, .fact: 90, .preference: 180, .correction: 180]

    public init(enabled: Bool = false, kinds: Set<MemoryKind> = Set(MemoryKind.allCases), budgetTokens: Int = 300,
                maxActive: Int = 300, halfLifeDays: [MemoryKind: Double] = MemorySettings.defaultHalfLives,
                deleteExpiredAfterDays: Int = 30, projectMemory: Bool = true) {
        self.enabled = enabled
        self.kinds = kinds
        self.budgetTokens = budgetTokens
        self.maxActive = maxActive
        self.halfLifeDays = halfLifeDays
        self.deleteExpiredAfterDays = deleteExpiredAfterDays
        self.projectMemory = projectMemory
    }

    public func halfLife(_ kind: MemoryKind) -> Double {
        max(1, halfLifeDays[kind] ?? Self.defaultHalfLives[kind] ?? 90)
    }

    /// Whether `note` may go into a chat in `project` (nil: none).
    public func allows(_ note: MemoryNote, project: UUID?) -> Bool {
        guard enabled, note.isActive, kinds.contains(note.kind) else { return false }
        switch note.subject {
        case .user: return true
        case .project(let id): return projectMemory && id == project
        }
    }
}

extension MemorySettings {
    public static func halfLifeKey(_ kind: MemoryKind) -> PrefKey<Int> {
        switch kind {
        case .fact: return Pref.memoryHalfLifeFact
        case .preference: return Pref.memoryHalfLifePreference
        case .correction: return Pref.memoryHalfLifeCorrection
        case .observation: return Pref.memoryHalfLifeObservation
        }
    }

    /// The settings as stored (Pref.memory…).
    public init(defaults: UserDefaults) {
        let kinds = Set(defaults[Pref.memoryKinds].split(separator: ",").compactMap { MemoryKind(rawValue: String($0)) })
        self.init(
            enabled: defaults[Pref.memoryEnabled], kinds: kinds,
            budgetTokens: max(0, defaults[Pref.memoryBudgetTokens]), maxActive: max(1, defaults[Pref.memoryMaxActive]),
            halfLifeDays: Dictionary(uniqueKeysWithValues: MemoryKind.allCases.map { ($0, Double(max(1, defaults[Self.halfLifeKey($0)]))) }),
            deleteExpiredAfterDays: max(0, defaults[Pref.memoryDeleteExpiredAfterDays]),
            projectMemory: defaults[Pref.memoryProjects])
    }

    /// Stores which kinds are on.
    public static func storeKinds(_ kinds: Set<MemoryKind>, defaults: UserDefaults) {
        defaults[Pref.memoryKinds] = MemoryKind.allCases.filter(kinds.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// Topics: short English keys a note is filed under, for finding it.
public enum MemoryTopics {
    public static let builtIn = [
        "general", "reply-language", "answer-length", "tone", "formatting", "work",
        "hardware", "os", "tools", "code-style", "documents", "images", "music",
    ]

    /// A topic as stored: lowercase, words joined by "-", at most 40
    /// characters; "general" when nothing is left.
    public static func normalized(_ topic: String) -> String {
        let words = topic.lowercased().split { !$0.isLetter && !$0.isNumber }
        let key = String(words.joined(separator: "-").prefix(40))
        return key.isEmpty ? "general" : key
    }
}

/// What a note may say.
public enum MemoryText {
    public static let maxLength = 160
    public static let maxQuote = 200

    public enum Problem: Equatable, Sendable {
        case empty, tooLong, link, path, secret
    }

    /// A quote as compared: case and runs of whitespace folded.
    public static func normalizedQuote(_ quote: String) -> String {
        quote.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Why `text` can't be a note; nil when it can. A note is about the
    /// person and their work, never a place to keep links, paths or keys.
    public static func problem(_ text: String) -> Problem? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .empty }
        if t.count > maxLength { return .tooLong }
        let lower = t.lowercased()
        if lower.contains("://") || lower.contains("www.") { return .link }
        if t.range(of: #"(^|[\s"'(])(~/|/(Users|Volumes|private|tmp|var|etc|opt|home)/)"#, options: .regularExpression) != nil {
            return .path
        }
        if t.range(of: #"(sk-|hf_|ghp_|gho_|github_pat_|xox[bp]-|AKIA)[A-Za-z0-9_\-]{8,}"#, options: .regularExpression) != nil
            || t.range(of: #"[A-Za-z0-9_\-+/=]{32,}"#, options: .regularExpression) != nil
            || lower.contains("private key") && lower.contains("-----") {
            return .secret
        }
        return nil
    }
}

/// The memory store as it is on disk (memory/notes.json).
public struct MemoryFile: Codable, Equatable, Sendable {
    public var version = 1
    /// Raised by every change; a chat's snapshot remembers the one it saw.
    public var generation = 0
    public var nextID = 1
    public var notes: [MemoryNote] = []
    /// What's still to be learned from (MemoryBatch), oldest first. In the
    /// same file as the notes: a batch's notes and its leaving the queue
    /// are one write.
    public var queue: [MemoryBatch] = []
    /// Per chat (its id), the last user message (its seq) put in the queue.
    public var watermarks: [String: Int] = [:]
    /// Chats marked "Don't remember this chat".
    public var optedOut: Set<UUID> = []
    /// Forgotten notes, so they aren't learned again from the same words.
    public var tombstones: [MemoryTombstone] = []
    public var nextBatchID = 1

    public init() {}

    enum CodingKeys: String, CodingKey {
        case version, generation, nextID, notes, queue, watermarks, optedOut, tombstones, nextBatchID
    }

    // The queue and the rest came after the first notes files.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        generation = try c.decode(Int.self, forKey: .generation)
        nextID = try c.decode(Int.self, forKey: .nextID)
        notes = try c.decode([MemoryNote].self, forKey: .notes)
        queue = try c.decodeIfPresent([MemoryBatch].self, forKey: .queue) ?? []
        watermarks = try c.decodeIfPresent([String: Int].self, forKey: .watermarks) ?? [:]
        optedOut = try c.decodeIfPresent(Set<UUID>.self, forKey: .optedOut) ?? []
        tombstones = try c.decodeIfPresent([MemoryTombstone].self, forKey: .tombstones) ?? []
        nextBatchID = try c.decodeIfPresent(Int.self, forKey: .nextBatchID) ?? 1
    }

    public func note(_ id: String) -> MemoryNote? { notes.first { $0.id == id } }

    private mutating func bump() -> Int {
        generation += 1
        return generation
    }

    /// A note the user wrote (stated, reviewed). Returns its id; nil when
    /// the text can't be a note.
    @discardableResult
    public mutating func add(subject: MemorySubject, topic: String, kind: MemoryKind, text: String,
                             observed: String? = nil, now: Date, reviewed: Bool = true,
                             confidence: MemoryConfidence = .stated) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MemoryText.problem(text) == nil else { return nil }
        let id = "m\(nextID)"
        nextID += 1
        let g = bump()
        notes.append(MemoryNote(
            id: id, subject: subject, topic: MemoryTopics.normalized(topic), kind: kind, text: text,
            observed: observed.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 },
            evidence: [], created: now, confirmed: now, confidence: confidence, reviewed: reviewed,
            pinned: false, history: [], expired: nil, changed: g))
        return id
    }

    /// The user's edit: the old text goes to the history (3 kept). False
    /// when there's no such note or the text can't be a note.
    @discardableResult
    public mutating func edit(_ id: String, text: String, topic: String? = nil, kind: MemoryKind? = nil, now: Date) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MemoryText.problem(text) == nil, let i = notes.firstIndex(where: { $0.id == id }) else { return false }
        let g = bump()
        if notes[i].text != text {
            notes[i].history.append(MemoryHistoryEntry(text: notes[i].text, date: now))
            notes[i].history = Array(notes[i].history.suffix(3))
            notes[i].text = text
        }
        if let topic { notes[i].topic = MemoryTopics.normalized(topic) }
        if let kind { notes[i].kind = kind }
        // What the user wrote is what they say.
        notes[i].reviewed = true
        notes[i].confidence = .stated
        notes[i].confirmed = now
        notes[i].changed = g
        return true
    }

    public mutating func setPinned(_ id: String, _ pinned: Bool, now: Date) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].pinned != pinned else { return }
        notes[i].pinned = pinned
        notes[i].reviewed = true
        // A pinned note is never expired.
        if pinned { notes[i].expired = nil; notes[i].confirmed = now }
        notes[i].changed = bump()
    }

    /// The user approves a learned note as it is.
    public mutating func approve(_ id: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), !notes[i].reviewed else { return }
        notes[i].reviewed = true
        notes[i].changed = bump()
    }

    /// Back from expired, counting its age from now.
    public mutating func restore(_ id: String, now: Date) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].expired != nil else { return }
        notes[i].expired = nil
        notes[i].confirmed = now
        notes[i].changed = bump()
    }

    /// The user forgets a note. One learned from chats leaves a tombstone
    /// (its quotes' hashes, and `vector`, its text's embedding, when
    /// known), so the same words don't teach it again.
    public mutating func forget(_ id: String, vector: [Float]? = nil, now: Date = Date()) {
        guard let note = note(id) else { return }
        notes.removeAll { $0.id == id }
        if !note.evidence.isEmpty || vector != nil {
            tombstones.append(MemoryTombstone(subject: note.subject, quoteHashes: note.evidence.map { MemoryTombstone.hash($0.quote) },
                                              vector: vector, date: now))
            tombstones = Array(tombstones.suffix(MemoryTombstone.maxKept))
        }
        _ = bump()
    }

    /// Every note about a deleted project.
    public mutating func forget(project: UUID) {
        let before = notes.count
        notes.removeAll { $0.subject == .project(project) }
        if notes.count != before { _ = bump() }
    }

    /// Everything: notes, what's queued, tombstones. The watermarks stay,
    /// so what was already said isn't learned again; the opt-outs stay.
    public mutating func forgetAll() {
        notes = []
        queue = []
        tombstones = []
        _ = bump()
    }

    // MARK: Chats

    /// A chat's watermark: user messages after it aren't queued yet; nil:
    /// a chat memory hasn't met.
    public func watermark(_ chat: UUID) -> Int? { watermarks[chat.uuidString] }

    /// A chat memory meets for the first time: learned from `seq` on (0: a
    /// new chat, from its start; an older chat opened again: from now).
    public mutating func meet(_ chat: UUID, from seq: Int) {
        guard watermarks[chat.uuidString] == nil else { return }
        watermarks[chat.uuidString] = seq
    }

    /// Queues `messages` of a chat after its watermark, in batches of at
    /// most `MemoryBatch.maxBytes`, and moves the watermark past them.
    /// Nothing for an opted-out chat, or one memory hasn't met. True when
    /// anything was queued.
    @discardableResult
    public mutating func enqueue(chat: UUID, project: UUID?, messages: [MemoryBatchMessage], now: Date) -> Bool {
        guard !optedOut.contains(chat), let mark = watermark(chat) else { return false }
        let fresh = messages.filter { $0.seq > mark && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.seq < $1.seq }
        guard let last = fresh.last else { return false }
        var batch: [MemoryBatchMessage] = []
        var bytes = 0
        func flush() {
            guard !batch.isEmpty else { return }
            queue.append(MemoryBatch(id: nextBatchID, chat: chat, project: project, created: now, messages: batch))
            nextBatchID += 1
            batch = []
            bytes = 0
        }
        for message in fresh {
            let size = message.text.utf8.count + (message.before?.utf8.count ?? 0)
            if bytes + size > MemoryBatch.maxBytes { flush() }
            batch.append(message.clipped)
            bytes += min(size, MemoryBatch.maxBytes)
        }
        flush()
        watermarks[chat.uuidString] = last.seq
        return true
    }

    /// "Don't remember this chat": nothing more is learned from it, and
    /// what's queued from it goes.
    public mutating func setOptedOut(_ chat: UUID, _ out: Bool) {
        if out {
            optedOut.insert(chat)
            queue.removeAll { $0.chat == chat }
        } else {
            optedOut.remove(chat)
        }
    }

    /// A chat deleted, or the user forgetting what was learned from it:
    /// its queue and evidence go; a note left with no evidence goes too
    /// unless the user reviewed it. `keepState` keeps its watermark and
    /// opt-out (the chat is still there); `keepNotes` leaves the notes and
    /// their evidence alone (a deleted chat, the setting off).
    public mutating func forgetLearned(fromChat chat: UUID, keepState: Bool, keepNotes: Bool = false, now: Date = Date()) {
        var changed = false
        let before = queue.count
        queue.removeAll { $0.chat == chat }
        if queue.count != before { changed = true }
        if !keepState {
            if watermarks.removeValue(forKey: chat.uuidString) != nil { changed = true }
            if optedOut.remove(chat) != nil { changed = true }
        }
        var removed: [String] = []
        for i in notes.indices where !keepNotes && notes[i].evidence.contains(where: { $0.chat == chat }) {
            let whole = notes[i].evidence
            notes[i].evidence.removeAll { $0.chat == chat }
            if notes[i].evidence.isEmpty, !notes[i].reviewed {
                tombstones.append(MemoryTombstone(subject: notes[i].subject, quoteHashes: whole.map { MemoryTombstone.hash($0.quote) },
                                                  vector: nil, date: now))
                removed.append(notes[i].id)
            }
            changed = true
        }
        if !removed.isEmpty {
            notes.removeAll { removed.contains($0.id) }
            tombstones = Array(tombstones.suffix(MemoryTombstone.maxKept))
        }
        // Evidence gone is not a claim changed: a chat's block keeps a
        // note that stays (its `changed` is untouched); a removed one goes.
        guard changed else { return }
        _ = bump()
    }

    /// How much of a note is left: 1 when confirmed now, halving every
    /// half-life of its kind; a pinned one stays 1.
    public static func recency(_ note: MemoryNote, now: Date, settings: MemorySettings) -> Double {
        guard !note.pinned else { return 1 }
        let days = max(0, now.timeIntervalSince(note.confirmed) / 86_400)
        return pow(0.5, days / settings.halfLife(note.kind))
    }

    /// Below this a note expires (about 3.3 half-lives).
    public static let expiryFloor = 0.1

    /// Expiry: notes faded under the floor expire; over `maxActive`, the
    /// weakest unpinned ones expire too; expired ones past the grace period
    /// are deleted. True when anything changed.
    @discardableResult
    public mutating func sweep(now: Date, settings: MemorySettings) -> Bool {
        var expire = Set(notes.indices.filter {
            notes[$0].isActive && !notes[$0].pinned && Self.recency(notes[$0], now: now, settings: settings) < Self.expiryFloor
        })
        let active = notes.indices.filter { notes[$0].isActive && !notes[$0].pinned && !expire.contains($0) }
        let pinnedActive = notes.filter { $0.isActive && $0.pinned }.count
        let over = active.count + pinnedActive - max(0, settings.maxActive)
        if over > 0 {
            let strengths = Dictionary(uniqueKeysWithValues: active.map { ($0, Self.strength(notes[$0], now: now, settings: settings)) })
            expire.formUnion(active.sorted { strengths[$0]! < strengths[$1]! }.prefix(over))
        }
        let grace = Double(max(0, settings.deleteExpiredAfterDays)) * 86_400
        let delete = Set(notes.compactMap { note in
            note.expired.map { now.timeIntervalSince($0) >= grace } == true ? note.id : nil
        })
        guard !expire.isEmpty || !delete.isEmpty else { return false }
        let g = bump()
        for i in expire {
            notes[i].expired = now
            notes[i].changed = g
        }
        notes.removeAll { delete.contains($0.id) }
        return true
    }

    /// A note's standing apart from any chat: weight × recency.
    public static func strength(_ note: MemoryNote, now: Date, settings: MemorySettings) -> Double {
        note.confidence.weight * recency(note, now: now, settings: settings)
    }
}

/// A user message waiting to be learned from: what the user typed, and
/// the start of the answer before it (context only, never evidence).
public struct MemoryBatchMessage: Codable, Equatable, Sendable {
    public var seq: Int
    public var date: Date
    public var text: String
    public var before: String?

    /// At most this much of the answer before a message is kept.
    public static let maxBefore = 300

    public init(seq: Int, date: Date, text: String, before: String?) {
        self.seq = seq
        self.date = date
        self.text = text
        self.before = before
    }

    /// Within a batch: the answer before cut to its start, a very long
    /// message (a paste) to the batch size.
    var clipped: MemoryBatchMessage {
        var m = self
        m.before = before.map { String($0.prefix(Self.maxBefore)) }.flatMap { $0.isEmpty ? nil : $0 }
        if m.text.utf8.count > MemoryBatch.maxBytes {
            m.text = String(decoding: m.text.utf8.prefix(MemoryBatch.maxBytes), as: UTF8.self)
        }
        return m
    }
}

/// User messages of one chat, read together by the reflection pass.
public struct MemoryBatch: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var chat: UUID
    public var project: UUID?
    public var created: Date
    public var messages: [MemoryBatchMessage]
    /// Tries that ended without a result (the model busy, cut off).
    public var attempts = 0

    /// About 3k tokens of Russian: a short prompt, so a foreground request
    /// never waits long behind one (adr/0021, BackgroundRequest).
    public static let maxBytes = 9_000

    public init(id: Int, chat: UUID, project: UUID?, created: Date, messages: [MemoryBatchMessage]) {
        self.id = id
        self.chat = chat
        self.project = project
        self.created = created
        self.messages = messages
    }
}

/// What's left of a forgotten note: enough to recognise it, never its text.
public struct MemoryTombstone: Codable, Equatable, Sendable {
    public var subject: MemorySubject
    /// SHA-256 of each source quote, normalized (MemoryText.normalizedQuote).
    public var quoteHashes: [String]
    /// The text's embedding, when known; dropped when the embedder changes.
    public var vector: [Float]?
    public var date: Date

    public static let maxKept = 500

    public static func hash(_ quote: String) -> String {
        SHA256.hash(data: Data(MemoryText.normalizedQuote(quote).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `quote` is one a forgotten note was learned from.
    public func blocks(quote: String) -> Bool {
        quoteHashes.contains(Self.hash(quote))
    }
}

/// The memory block a chat got, kept with the chat so its system prompt
/// stays the same from one request to the next (the server's prompt cache).
public struct MemorySnapshot: Codable, Equatable, Sendable {
    public var text: String
    public var noteIDs: [String]
    /// The store's generation it was made at.
    public var generation: Int
    /// The chat's project then.
    public var project: UUID?
    /// Its size as estimated then.
    public var tokens: Int

    public init(text: String, noteIDs: [String], generation: Int, project: UUID?, tokens: Int) {
        self.text = text
        self.noteIDs = noteIDs
        self.generation = generation
        self.project = project
        self.tokens = tokens
    }
}

/// Which notes go into a chat, and how they read.
public enum MemorySelection {
    static let header = "What you know about the user from earlier chats. It may be outdated: what the user says now wins."
    static let projectHeader = "About this chat's project:"

    /// One note as the model reads it; an inferred one is marked a guess.
    static func line(_ note: MemoryNote) -> String {
        let guess = note.confidence == .inferred ? " (a guess)" : ""
        if let observed = note.observed, !observed.isEmpty {
            return "- Observed: \(observed); likely: \(note.text)\(guess)"
        }
        return "- \(note.text)\(guess)"
    }

    static func render(_ notes: [MemoryNote]) -> String {
        let user = notes.filter { $0.subject == .user }.map(line)
        let project = notes.filter { $0.subject != .user }.map(line)
        var parts = [header]
        parts += user
        if !project.isEmpty { parts += [projectHeader] + project }
        return parts.joined(separator: "\n")
    }

    /// The most of a model's context memory takes, whatever the budget.
    public static let maxContextShare = 0.05

    /// The budget for a chat: the user's, within `maxContextShare` of the
    /// model's context (`contextTokens`, nil: unknown).
    public static func budget(_ settings: MemorySettings, contextTokens: Int?) -> Int {
        guard let contextTokens, contextTokens > 0 else { return settings.budgetTokens }
        return min(settings.budgetTokens, Int(Double(contextTokens) * maxContextShare))
    }

    /// The block for a chat in `project` (nil: none) within `budget`
    /// tokens as `tokens` counts them; nil with memory off. With no note
    /// eligible or fitting it's empty (no text, no notes): the chat keeps
    /// that, and a note written later reaches the next chat. Pinned notes
    /// and the user's stated preferences and corrections come first (up to
    /// half the budget); the rest by strength. A note that doesn't fit is
    /// skipped, the next tried.
    public static func choose(_ file: MemoryFile, settings: MemorySettings, project: UUID?, budget: Int,
                              now: Date, tokens: (String) -> Int) -> MemorySnapshot? {
        guard settings.enabled else { return nil }
        let empty = MemorySnapshot(text: "", noteIDs: [], generation: file.generation, project: project, tokens: 0)
        let eligible = file.notes.filter { settings.allows($0, project: project) }
        guard !eligible.isEmpty, budget > 0 else { return empty }
        func isFirst(_ n: MemoryNote) -> Bool {
            n.pinned || n.subject == .user && n.confidence == .stated && (n.kind == .preference || n.kind == .correction)
        }
        func byStrength(_ a: MemoryNote, _ b: MemoryNote) -> Bool {
            let sa = MemoryFile.strength(a, now: now, settings: settings)
            let sb = MemoryFile.strength(b, now: now, settings: settings)
            return sa != sb ? sa > sb : a.confirmed > b.confirmed
        }
        let first = eligible.filter(isFirst).sorted { a, b in
            a.pinned != b.pinned ? a.pinned : byStrength(a, b)
        }
        var chosen: [MemoryNote] = []
        func fits(_ candidate: [MemoryNote], within limit: Int) -> Bool {
            tokens(render(candidate)) <= limit
        }
        for note in first where fits(chosen + [note], within: max(budget / 2, 1)) {
            chosen.append(note)
        }
        let rest = eligible.filter { n in !chosen.contains { $0.id == n.id } }.sorted(by: byStrength)
        for note in rest where fits(chosen + [note], within: budget) {
            chosen.append(note)
        }
        guard !chosen.isEmpty else { return empty }
        let text = render(chosen)
        return MemorySnapshot(text: text, noteIDs: chosen.map(\.id), generation: file.generation,
                              project: project, tokens: tokens(text))
    }

    /// Whether a chat's snapshot still holds: memory on, same project,
    /// within the budget as `tokens` counts it now (another model may
    /// count more), and each of its notes still there, eligible and
    /// unchanged since. New notes alone don't make it stale: they reach the
    /// next chat.
    public static func isCurrent(_ snapshot: MemorySnapshot, file: MemoryFile, settings: MemorySettings,
                                 project: UUID?, budget: Int, tokens: (String) -> Int) -> Bool {
        guard settings.enabled, snapshot.project == project else { return false }
        guard snapshot.text.isEmpty || tokens(snapshot.text) <= budget else { return false }
        for id in snapshot.noteIDs {
            guard let note = file.note(id), settings.allows(note, project: project),
                  note.changed <= snapshot.generation else { return false }
        }
        return true
    }
}
