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

/// Where a note is seen: every chat (`user`: the user wrote it, or
/// learning is shared), chats outside projects (`general`), or one
/// project's chats (by id, never by its name, which can change).
public enum MemorySubject: Hashable, Sendable, Codable {
    case user
    case general
    case project(UUID)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "user" {
            self = .user
        } else if raw == "general" {
            self = .general
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
        case .general: try c.encode("general")
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
    /// Written in another language than memory's (the tidy-up rewrites it).
    public var wrongLanguage: Bool?

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
    /// What's learned is seen everywhere, and learning keeps facts about
    /// the user apart from a project's. Off: a project's chats learn and
    /// see only their own; chats outside projects, theirs; what the user
    /// wrote for all chats is seen everywhere either way.
    public var shareLearned: Bool
    /// A learned fact or observation is sent once this many chats showed
    /// it: one question isn't who the user is. What the user wrote,
    /// approved or pinned, and what they asked for (preferences,
    /// corrections), go at once.
    public var factChats: Int
    /// Hours a mood read from the user's last messages reaches new chats;
    /// 0: moods aren't read.
    public var moodHours: Int

    public static let defaultHalfLives: [MemoryKind: Double] = [.observation: 30, .fact: 90, .preference: 180, .correction: 180]

    public init(enabled: Bool = false, kinds: Set<MemoryKind> = Set(MemoryKind.allCases), budgetTokens: Int = 300,
                maxActive: Int = 300, halfLifeDays: [MemoryKind: Double] = MemorySettings.defaultHalfLives,
                deleteExpiredAfterDays: Int = 30, projectMemory: Bool = true, shareLearned: Bool = false, factChats: Int = 2,
                moodHours: Int = 3) {
        self.enabled = enabled
        self.kinds = kinds
        self.budgetTokens = budgetTokens
        self.maxActive = maxActive
        self.halfLifeDays = halfLifeDays
        self.deleteExpiredAfterDays = deleteExpiredAfterDays
        self.projectMemory = projectMemory
        self.shareLearned = shareLearned
        self.factChats = max(1, factChats)
        self.moodHours = max(0, moodHours)
    }

    public func halfLife(_ kind: MemoryKind) -> Double {
        max(1, halfLifeDays[kind] ?? Self.defaultHalfLives[kind] ?? 90)
    }

    /// Whether `note` may go into a chat in `project` (nil: none).
    /// `candidates`: one not yet established counts too (reading a chat:
    /// it's what a second chat confirms).
    public func allows(_ note: MemoryNote, project: UUID?, candidates: Bool = false) -> Bool {
        guard enabled, note.isActive, kinds.contains(note.kind), candidates || isEstablished(note) else { return false }
        switch note.subject {
        // What the user wrote or approved is seen everywhere; a note learned
        // while learning was shared, only where learning is kept apart now
        // allows it: outside projects.
        case .user: return shareLearned || note.reviewed || project == nil
        case .general: return shareLearned || project == nil
        case .project(let id): return projectMemory && (shareLearned || id == project)
        }
    }

    /// Whether `note` is past being a candidate (see `factChats`).
    public func isEstablished(_ note: MemoryNote) -> Bool {
        if note.reviewed || note.pinned { return true }
        // What the user asked for, not one read from what they did (an
        // observation seen again becomes an inferred preference).
        if note.confidence == .stated, note.kind == .preference || note.kind == .correction { return true }
        return Set(note.evidence.map(\.chat)).count >= factChats
    }

    /// Where what a chat in `project` teaches is seen, when the model
    /// doesn't choose (learning not shared); nil: nothing is learned there
    /// (project notes off).
    public func learnedSubject(project: UUID?) -> MemorySubject? {
        guard let project else { return .general }
        return projectMemory ? .project(project) : nil
    }

    /// Whether a chat in `project` may learn at all: not in a project's
    /// chats with project notes off, shared or not.
    public func learns(inProject project: UUID?) -> Bool {
        project == nil || projectMemory
    }

    /// The settings a chat's block depends on, beyond its notes: a change
    /// (sharing turned on, a kind back on, a bigger budget) makes a new one.
    public var fingerprint: String {
        let k = MemoryKind.allCases.filter(kinds.contains).map(\.rawValue).joined(separator: ",")
        return "share:\(shareLearned)|projects:\(projectMemory)|kinds:\(k)|budget:\(budgetTokens)|facts:\(factChats)|mood:\(moodHours)"
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
            projectMemory: defaults[Pref.memoryProjects], shareLearned: defaults[Pref.memoryShareLearned],
            factChats: defaults[Pref.memoryFactChats], moodHours: defaults[Pref.memoryMoodHours])
    }

    /// Stores which kinds are on.
    public static func storeKinds(_ kinds: Set<MemoryKind>, defaults: UserDefaults) {
        defaults[Pref.memoryKinds] = MemoryKind.allCases.filter(kinds.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// What the user tells about themselves in Settings › Memory › About you:
/// each a pinned note (sent first, never expires, never changed by
/// reflection), filed under its own topic.
public enum MemoryAboutField: String, CaseIterable, Sendable {
    case name, location, work, other

    public var topic: String { "about-" + rawValue }

    /// How the note reads: a label, then the user's words.
    public var label: String {
        switch self {
        case .name: return "Name"
        case .location: return "Location"
        case .work: return "Work"
        case .other: return "About them"
        }
    }

    public func text(_ value: String) -> String { "\(label): \(value)" }

    /// The user's words back out of a note.
    public func value(of note: MemoryNote) -> String {
        let prefix = label + ": "
        return note.text.hasPrefix(prefix) ? String(note.text.dropFirst(prefix.count)) : note.text
    }
}

extension MemoryFile {
    public func about(_ field: MemoryAboutField) -> MemoryNote? {
        notes.first { $0.subject == .user && $0.topic == field.topic && $0.pinned }
    }

    /// Whether `note` is one of About you's.
    public func isAbout(_ note: MemoryNote) -> Bool {
        MemoryAboutField.allCases.contains { about($0)?.id == note.id }
    }

    /// Sets (or, empty, removes) an About you field. False when the text
    /// can't be a note.
    @discardableResult
    public mutating func setAbout(_ field: MemoryAboutField, _ value: String, now: Date) -> Bool {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Typed with its label ("Name: Roman"): not "Name: Name: Roman".
        if value.lowercased().hasPrefix(field.label.lowercased() + ":") {
            value = String(value.dropFirst(field.label.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        let existing = about(field)
        guard !value.isEmpty else {
            if let existing { forget(existing.id, now: now) }
            return true
        }
        let text = field.text(value)
        guard MemoryText.problem(text) == nil else { return false }
        if let existing {
            guard existing.text != text else { return true }
            return edit(existing.id, text: text, now: now)
        }
        guard let id = add(subject: .user, topic: field.topic, kind: .fact, text: text, now: now) else { return false }
        setPinned(id, true, now: now)
        return true
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

    /// A topic for a learned note: About you's are the user's alone.
    public static func learned(_ topic: String?) -> String {
        let key = normalized(topic ?? "general")
        return key.hasPrefix("about-") ? "general" : key
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

    /// Topics never learned from chats, whatever the model says: only the
    /// user writes these (About you). Word starts, in the languages notes
    /// are most often written in -- narrow ones, so work words ("diagnostics",
    /// "technical debt", "caching policy") don't match.
    static let sensitiveStems = [
        // health
        "diagnosed", "diagnosis", "disease", "illness", "depression", "depressed", "anxiety", "therapist", "therapy",
        "medication", "pregnan",
        "диагноз", "болезн", "болит", "депресси", "тревожност", "терапевт", "лекарств", "беремен",
        "хвороб", "депресі",
        // drugs, alcohol
        "drug", "lsd", "cocaine", "heroin", "cannabis", "marijuana", "psychedel", "alcohol", "drunk",
        "наркот", "лсд", "кокаин", "психодел", "алкогол", "пьян", "п'ян",
        // sex
        "sex", "porn", "секс", "порн",
        // religion, politics
        "religion", "religious", "political", "politics", "религи", "церков", "политическ", "релігі", "політичн",
        // money, law
        "salary", "lawsuit", "arrested", "criminal", "зарплат", "арестов", "преступлен", "судим", "злочин",
    ]

    /// One-off asks phrased as facts ("User asked for …"): a question isn't
    /// who someone is.
    static let oneOffPattern = #"^(the )?(user )?(asked|asks|is asking|requested|requests|wanted to know|wants to know|is looking for|looked for)\b"#
        + #"|^(пользователь )?(спросил|спрашивает|попросил|просит|интересовался|ищет)"#

    /// Whether a learned note's `text` is on a topic never learned. What
    /// the user writes themselves isn't checked.
    public static func sensitive(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && $0 != "'" }
        return words.contains { word in sensitiveStems.contains { word.hasPrefix($0) } }
    }

    /// Whether `text` is a one-off ask written up as a fact ("User asked
    /// for …"). Not for preferences: "Requests short answers" is one.
    public static func oneOff(_ text: String) -> Bool {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).range(of: oneOffPattern, options: .regularExpression) != nil
    }

    /// Whether a learned fact or observation's `text` must not be kept.
    public static func unlearnable(_ text: String) -> Bool { sensitive(text) || oneOff(text) }

    /// Topics an observation may be under: how the user wants to be
    /// answered, never a guess at why they asked something.
    public static let observationTopics: Set<String> = ["tone", "answer-length", "formatting", "reply-language", "code-style"]
}

/// The user's mood as their last messages showed it (adr/0024, "Mood"):
/// what was seen and how to answer now; it reaches new chats for
/// MemorySettings.moodHours from the message, then it's gone.
public struct MemoryMood: Codable, Equatable, Sendable {
    /// What the messages show ("Angry: the linker fails again").
    public var observed: String
    /// How to answer now ("Brief, straight to the fix").
    public var text: String
    /// The message's: the mood counts from when it was said.
    public var date: Date
    public var chat: UUID
    public var quote: String

    public init(observed: String, text: String, date: Date, chat: UUID, quote: String) {
        self.observed = observed
        self.text = text
        self.date = date
        self.chat = chat
        self.quote = quote
    }

    public func until(hours: Int) -> Date { date.addingTimeInterval(Double(hours) * 3600) }
    public func isFresh(now: Date, hours: Int) -> Bool { hours > 0 && until(hours: hours) > now }
}

extension MemoryFile {
    /// A mood read from a chat: kept when it's newer than the one there.
    public mutating func setMood(_ new: MemoryMood) {
        guard mood.map({ new.date > $0.date }) ?? true else { return }
        mood = new
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
    /// Per chat, the seq memory met it at: messages up to it were never
    /// read, nor is the answer to one taken as context.
    public var metFrom: [String: Int] = [:]
    /// Watermarks put aside while memory was off or the chat opted out:
    /// remembered again, the user picks whether what was said meanwhile is
    /// read (they come back) or not (they go, and the chat is met anew).
    public var pausedWatermarks: [String: Int] = [:]
    /// Per chat, the seqs read (queued) before it was met anew ("only from
    /// now on"): "Learn from past chats" doesn't read them again.
    public var readBefore: [String: [ClosedRange<Int>]] = [:]
    /// Chats marked "Don't remember this chat".
    public var optedOut: Set<UUID> = []
    /// Forgotten notes, so they aren't learned again from the same words.
    public var tombstones: [MemoryTombstone] = []
    public var nextBatchID = 1
    /// The user's mood as their last messages showed it: short-lived, not a
    /// note (MemorySettings.moodHours).
    public var mood: MemoryMood?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case version, generation, nextID, notes, queue, watermarks, metFrom, pausedWatermarks, readBefore, optedOut, tombstones, nextBatchID, mood
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
        metFrom = try c.decodeIfPresent([String: Int].self, forKey: .metFrom) ?? [:]
        pausedWatermarks = try c.decodeIfPresent([String: Int].self, forKey: .pausedWatermarks) ?? [:]
        readBefore = try c.decodeIfPresent([String: [ClosedRange<Int>]].self, forKey: .readBefore) ?? [:]
        // A watermark from before metFrom: met there, as far as is known.
        for (chat, mark) in watermarks where metFrom[chat] == nil { metFrom[chat] = mark }
        optedOut = try c.decodeIfPresent(Set<UUID>.self, forKey: .optedOut) ?? []
        tombstones = try c.decodeIfPresent([MemoryTombstone].self, forKey: .tombstones) ?? []
        nextBatchID = try c.decodeIfPresent(Int.self, forKey: .nextBatchID) ?? 1
        mood = try c.decodeIfPresent(MemoryMood.self, forKey: .mood)
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
    /// `subject`: where it's seen -- every chat (the user), or one project's.
    public mutating func edit(_ id: String, text: String, topic: String? = nil, kind: MemoryKind? = nil,
                              subject: MemorySubject? = nil, now: Date) -> Bool {
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
        if let subject { notes[i].subject = subject }
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

    /// Memory turned off: every watermark is put aside; nothing is read or
    /// met until it's on again and the user has chosen (`resume`). What's
    /// queued stays.
    public mutating func pauseAll() {
        for (chat, mark) in watermarks {
            // What's queued stays and is still read.
            if let id = UUID(uuidString: chat) { noteRead(id, queuedToo: true) }
            pausedWatermarks[chat] = min(pausedWatermarks[chat] ?? mark, mark)
        }
        watermarks = [:]
    }

    /// Whether anything was put aside by memory being off (a choice to ask
    /// for); a chat that's opted out waits for its own "Remember".
    public var hasPaused: Bool {
        pausedWatermarks.keys.contains { key in UUID(uuidString: key).map { !optedOut.contains($0) } ?? false }
    }
    public func isPaused(_ chat: UUID) -> Bool { pausedWatermarks[chat.uuidString] != nil }

    /// On again: what was said meanwhile is read too (`readMeanwhile`), or
    /// not -- then those chats are met anew from their next message.
    /// Only chats not opted out.
    public mutating func resumeAll(readMeanwhile: Bool) {
        for (chat, mark) in pausedWatermarks {
            guard let id = UUID(uuidString: chat), !optedOut.contains(id) else { continue }
            resume(chat, mark: mark, readMeanwhile: readMeanwhile)
        }
    }

    private mutating func resume(_ chat: String, mark: Int, readMeanwhile: Bool) {
        pausedWatermarks.removeValue(forKey: chat)
        if readMeanwhile {
            watermarks[chat] = min(watermarks[chat] ?? mark, mark)
        } else {
            watermarks.removeValue(forKey: chat)
            if let from = metFrom.removeValue(forKey: chat), mark > from {
                addRead(Array((from + 1)...mark), to: chat)
            }
        }
    }

    /// The embedder changed: tombstones' vectors are of the old one (their
    /// quote hashes still hold).
    public mutating func dropTombstoneVectors() {
        guard tombstones.contains(where: { $0.vector != nil }) else { return }
        for i in tombstones.indices { tombstones[i].vector = nil }
    }

    /// Where memory met a chat (see `metFrom`); nil: not met.
    public func met(_ chat: UUID) -> Int? { metFrom[chat.uuidString] }

    /// Everything: notes, what's queued, tombstones. The watermarks stay,
    /// so what was already said isn't learned again; the opt-outs stay.
    public mutating func forgetAll() {
        notes = []
        queue = []
        tombstones = []
        mood = nil
        _ = bump()
    }

    /// Learned notes the user never wrote, edited, pinned or approved.
    public var unreviewedCount: Int { notes.filter { !$0.reviewed && !$0.pinned }.count }

    /// "Forget What Was Learned": every learned note the user never wrote,
    /// edited, pinned or approved goes, with the queue -- no tombstones, so
    /// better rules may learn them again. `readAgain`: where memory read
    /// each chat goes too, so "Learn from past chats" reads them all anew.
    /// Opt-outs, tombstones and the choice waiting after memory was off stay.
    public mutating func forgetUnreviewed(readAgain: Bool) {
        notes.removeAll { !$0.reviewed && !$0.pinned }
        queue = []
        mood = nil
        if readAgain {
            watermarks = [:]
            metFrom = [:]
            readBefore = [:]
        }
        _ = bump()
    }

    // MARK: Chats

    /// A chat's watermark: user messages after it aren't queued yet; nil:
    /// a chat memory hasn't met.
    public func watermark(_ chat: UUID) -> Int? { watermarks[chat.uuidString] }

    /// A chat memory meets for the first time: learned from `seq` on (0: a
    /// new chat, from its start; an older chat opened again: from now).
    /// Not an opted-out one.
    public mutating func meet(_ chat: UUID, from seq: Int) {
        guard watermarks[chat.uuidString] == nil, !optedOut.contains(chat), pausedWatermarks[chat.uuidString] == nil else { return }
        watermarks[chat.uuidString] = seq
        metFrom[chat.uuidString] = seq
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
        appendBatches(fresh, chat: chat, project: project, now: now)
        watermarks[chat.uuidString] = last.seq
        return true
    }

    /// "Learn from past chats now": what a chat said before memory met it
    /// (all of it, for a chat memory never met) is queued too, and the
    /// chat is met from its start. What was queued or read already isn't
    /// again; what's after the watermark is left to `enqueue`. Nothing for
    /// an opted-out chat, or one put aside while memory was off (the user
    /// chooses for those first). True when anything was queued.
    @discardableResult
    public mutating func enqueuePast(chat: UUID, project: UUID?, messages: [MemoryBatchMessage], now: Date) -> Bool {
        let key = chat.uuidString
        guard !optedOut.contains(chat), pausedWatermarks[key] == nil else { return false }
        let past = messages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted { $0.seq < $1.seq }
        let upTo: Int
        if let met = metFrom[key] {
            upTo = met
        } else {
            guard let last = past.last else { return false }
            upTo = last.seq
            watermarks[key] = upTo
        }
        metFrom[key] = 0
        let read = readBefore.removeValue(forKey: key) ?? []
        let unread = past.filter { m in m.seq <= upTo && !read.contains { $0.contains(m.seq) } }
        guard !unread.isEmpty else { return false }
        appendBatches(unread, chat: chat, project: project, now: now)
        return true
    }

    /// Keeps which of a chat's messages were read since memory met it (and
    /// those `queuedToo`, still to be read) before its watermark goes, so
    /// "Learn from past chats" doesn't read them again.
    private mutating func noteRead(_ chat: UUID, queuedToo: Bool) {
        let key = chat.uuidString
        guard let mark = watermarks[key] else { return }
        let from = metFrom[key] ?? mark
        let queued = Set(queue.filter { $0.chat == chat }.flatMap { $0.messages.map(\.seq) })
        var seqs = Set(mark > from ? Array((from + 1)...mark) : [])
        if queuedToo { seqs.formUnion(queued) } else { seqs.subtract(queued) }
        addRead(Array(seqs), to: key)
    }

    private mutating func addRead(_ seqs: [Int], to key: String) {
        let all = Set(seqs + (readBefore[key] ?? []).flatMap { Array($0) }).sorted()
        var ranges: [ClosedRange<Int>] = []
        for seq in all {
            if let last = ranges.last, last.upperBound + 1 == seq {
                ranges[ranges.count - 1] = last.lowerBound...seq
            } else {
                ranges.append(seq...seq)
            }
        }
        readBefore[key] = ranges.isEmpty ? nil : ranges
    }

    /// `messages` (in order) as batches of at most `MemoryBatch.maxBytes`.
    private mutating func appendBatches(_ messages: [MemoryBatchMessage], chat: UUID, project: UUID?, now: Date) {
        var batch: [MemoryBatchMessage] = []
        var bytes = 0
        func flush() {
            guard !batch.isEmpty else { return }
            queue.append(MemoryBatch(id: nextBatchID, chat: chat, project: project, created: now, messages: batch))
            nextBatchID += 1
            batch = []
            bytes = 0
        }
        for message in messages {
            let size = message.text.utf8.count + (message.before?.utf8.count ?? 0)
            if bytes + size > MemoryBatch.maxBytes { flush() }
            batch.append(message.clipped)
            bytes += min(size, MemoryBatch.maxBytes)
        }
        flush()
    }

    /// "Don't remember this chat": nothing more is learned from it, and
    /// what's queued from it goes. Its watermark goes too: remembered
    /// again, memory meets it anew at its next message, so nothing said
    /// meanwhile is ever read.
    /// `readMeanwhile` (remembered again): what was said while it was out
    /// is read too, or only what comes from now on.
    public mutating func setOptedOut(_ chat: UUID, _ out: Bool, readMeanwhile: Bool = false) {
        let key = chat.uuidString
        if out {
            // What's queued goes (below), so it doesn't count as read --
            // nor if a pause counted it.
            noteRead(chat, queuedToo: false)
            let dropped = Set(queue.filter { $0.chat == chat }.flatMap { $0.messages.map(\.seq) })
            if !dropped.isEmpty, let read = readBefore[key] {
                readBefore[key] = nil
                addRead(read.flatMap { Array($0) }.filter { !dropped.contains($0) }, to: key)
            }
            optedOut.insert(chat)
            // Put aside from before what was queued, which goes: read again
            // only if the user asks for it when remembering the chat.
            let queuedFrom = queue.filter { $0.chat == chat }.flatMap { $0.messages.map(\.seq) }.min().map { $0 - 1 }
            if let mark = [watermarks[key], queuedFrom, pausedWatermarks[key]].compactMap({ $0 }).min() {
                pausedWatermarks[key] = mark
            }
            queue.removeAll { $0.chat == chat }
            watermarks.removeValue(forKey: key)
        } else {
            optedOut.remove(chat)
            if let mark = pausedWatermarks[key] { resume(key, mark: mark, readMeanwhile: readMeanwhile) }
        }
    }

    /// A chat deleted, or the user forgetting what was learned from it:
    /// its queue and evidence go; a note left with no evidence goes too
    /// unless the user reviewed it. `keepState` keeps its watermark and
    /// opt-out (the chat is still there); `keepNotes` leaves the notes and
    /// their evidence alone (a deleted chat, the setting off).
    public mutating func forgetLearned(fromChat chat: UUID, keepState: Bool, keepNotes: Bool = false, now: Date = Date()) {
        var changed = false
        if mood?.chat == chat {
            mood = nil
            changed = true
        }
        let before = queue.count
        queue.removeAll { $0.chat == chat }
        if queue.count != before { changed = true }
        if !keepState {
            if watermarks.removeValue(forKey: chat.uuidString) != nil { changed = true }
            metFrom.removeValue(forKey: chat.uuidString)
            pausedWatermarks.removeValue(forKey: chat.uuidString)
            readBefore.removeValue(forKey: chat.uuidString)
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
    /// The model it was sent to (its path): by default the one that reads
    /// it for memory too (a chat in Russian with Gemma isn't read by an
    /// English-only coder loaded later). nil: unknown, any model.
    public var model: String?

    /// At most this much of the answer before a message is kept.
    public static let maxBefore = 300

    /// One message of a chat, as memory reads chats.
    public struct Turn: Sendable {
        public var role: String
        public var text: String
        public var isSummary: Bool
        public var seq: Int?
        public var date: Date?
        public var model: String?

        public init(role: String, text: String, isSummary: Bool = false, seq: Int?, date: Date?, model: String?) {
            self.role = role
            self.text = text
            self.isSummary = isSummary
            self.seq = seq
            self.date = date
            self.model = model
        }
    }

    /// A chat's user messages (those with a seq), each with the answer
    /// before it -- unless that answers a message memory never read (at or
    /// before `readFrom`). `date` for a message from before dates were kept.
    public static func reading(_ turns: [Turn], readFrom: Int, date: Date) -> [MemoryBatchMessage] {
        var items: [MemoryBatchMessage] = []
        var lastAnswer: String?
        var previousSeq = 0
        for turn in turns {
            if turn.role == "assistant", !turn.text.isEmpty, !turn.isSummary {
                lastAnswer = previousSeq > readFrom ? turn.text : nil
            } else if turn.role == "user", let seq = turn.seq {
                // The model it was sent to: by default the one that reads it.
                items.append(MemoryBatchMessage(seq: seq, date: turn.date ?? date, text: turn.text, before: lastAnswer, model: turn.model))
                lastAnswer = nil
                previousSeq = seq
            }
        }
        return items
    }

    public init(seq: Int, date: Date, text: String, before: String?, model: String? = nil) {
        self.seq = seq
        self.date = date
        self.text = text
        self.before = before
        self.model = model
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
    /// The model the chat last answered with in it (see MemoryBatchMessage.model).
    public var model: String? { messages.last { $0.model != nil }?.model }

    /// Tries put off (the model busy, cut off): for the backoff.
    public var attempts = 0
    /// Tries that failed (an unreadable reply): dropped after a few.
    public var failures: Int?

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
    /// A new text this close to a forgotten one's isn't learned.
    public static let vectorFloor: Float = 0.92

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
    /// The settings it was chosen under (MemorySettings.fingerprint).
    public var settings: String?
    /// When the mood it carries runs out: then it's chosen again.
    public var moodUntil: Date?

    public init(text: String, noteIDs: [String], generation: Int, project: UUID?, tokens: Int, settings: String? = nil,
                moodUntil: Date? = nil) {
        self.moodUntil = moodUntil
        self.text = text
        self.noteIDs = noteIDs
        self.generation = generation
        self.project = project
        self.tokens = tokens
        self.settings = settings
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
        let user = notes.filter { if case .project = $0.subject { return false } else { return true } }.map(line)
        let project = notes.filter { if case .project = $0.subject { return true } else { return false } }.map(line)
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
        let empty = MemorySnapshot(text: "", noteIDs: [], generation: file.generation, project: project, tokens: 0,
                                   settings: settings.fingerprint)
        let eligible = file.notes.filter { settings.allows($0, project: project) }
        // The mood first (it's what's timely), at most half the room.
        let mood = file.mood.flatMap { $0.isFresh(now: now, hours: settings.moodHours) ? $0 : nil }
        let moodText = mood.map(moodLine).flatMap { tokens($0) <= budget / 2 ? $0 : nil }
        let budget = budget - (moodText.map { tokens($0) + 1 } ?? 0)
        func snapshot(_ chosen: [MemoryNote]) -> MemorySnapshot {
            let text = ((chosen.isEmpty ? [] : [render(chosen)]) + [moodText].compactMap { $0 }).joined(separator: "\n")
            return MemorySnapshot(text: text, noteIDs: chosen.map(\.id), generation: file.generation, project: project,
                                  tokens: text.isEmpty ? 0 : tokens(text), settings: settings.fingerprint,
                                  moodUntil: moodText == nil ? nil : mood?.until(hours: settings.moodHours))
        }
        guard !eligible.isEmpty, budget > 0 else { return moodText == nil ? empty : snapshot([]) }
        func isFirst(_ n: MemoryNote) -> Bool {
            guard !n.pinned else { return true }
            if case .project = n.subject { return false }
            return n.confidence == .stated && (n.kind == .preference || n.kind == .correction)
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
        guard !chosen.isEmpty || moodText != nil else { return empty }
        return snapshot(chosen)
    }

    /// The mood as the model reads it: a guess about now, not a note.
    static func moodLine(_ mood: MemoryMood) -> String {
        "Right now (from the user's last messages, a guess): \(mood.observed). So: \(mood.text)"
    }

    /// Whether a chat's snapshot still holds: memory on, same project,
    /// within the budget as `tokens` counts it now (another model may
    /// count more), and each of its notes still there, eligible and
    /// unchanged since. New notes alone don't make it stale: they reach the
    /// next chat.
    public static func isCurrent(_ snapshot: MemorySnapshot, file: MemoryFile, settings: MemorySettings,
                                 project: UUID?, budget: Int, now: Date = Date(), tokens: (String) -> Int) -> Bool {
        guard settings.enabled, snapshot.project == project, snapshot.settings == settings.fingerprint else { return false }
        // A mood that ran out, was forgotten or replaced leaves the chat.
        if let until = snapshot.moodUntil {
            guard until > now, let mood = file.mood, mood.until(hours: settings.moodHours) == until else { return false }
        }
        guard snapshot.text.isEmpty || tokens(snapshot.text) <= budget else { return false }
        for id in snapshot.noteIDs {
            guard let note = file.note(id), settings.allows(note, project: project),
                  note.changed <= snapshot.generation else { return false }
        }
        return true
    }
}
