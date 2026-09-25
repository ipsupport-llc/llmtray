import Foundation

/// What the chat sidebar knows about the saved chats beyond the chats
/// themselves: pins and projects. Kept apart from the session files, which
/// ChatClient rewrites whole after every turn -- a pin set in between would
/// be lost.
public struct ChatLibrary: Codable, Equatable {
    public struct Project: Codable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var createdAt: Date

        public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
        }

        private enum CodingKeys: String, CodingKey { case id, name, createdAt }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        }
    }

    public var projects: [Project] = []
    /// Pinned chats, most recently pinned first.
    public var pinned: [UUID] = []
    /// A chat's project; chats in none aren't listed.
    public var projectOfChat: [UUID: UUID] = [:]

    public init() {}

    // Written by hand: a field added later mustn't make an older file fail
    // to decode (every pin and project would be dropped with it), and a
    // chat's project is written as a JSON object, not a flat array.
    private enum CodingKeys: String, CodingKey { case projects, pinned, projectOfChat }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Element by element: one bad entry drops itself, not the file.
        projects = ((try? c.decodeIfPresent([Lossy<Project>].self, forKey: .projects)) ?? nil)?.compactMap(\.value) ?? []
        pinned = ((try? c.decodeIfPresent([Lossy<UUID>].self, forKey: .pinned)) ?? nil)?.compactMap(\.value) ?? []
        var byChat: [(String, String)] = []
        if let object = try? c.decodeIfPresent([String: String].self, forKey: .projectOfChat) {
            byChat = object.map { ($0.key, $0.value) }
        } else if let flat = try? c.decodeIfPresent([String].self, forKey: .projectOfChat) {
            // The pairs a [UUID: UUID] encodes as by default (an early build).
            byChat = stride(from: 0, to: flat.count - 1, by: 2).map { (flat[$0], flat[$0 + 1]) }
        }
        projectOfChat = [:]
        for (chat, project) in byChat {
            if let chat = UUID(uuidString: chat), let project = UUID(uuidString: project) { projectOfChat[chat] = project }
        }
    }

    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projects, forKey: .projects)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(Dictionary(uniqueKeysWithValues: projectOfChat.map { ($0.uuidString, $1.uuidString) }), forKey: .projectOfChat)
    }

    public func isPinned(_ chat: UUID) -> Bool { pinned.contains(chat) }

    public mutating func setPinned(_ chat: UUID, _ pin: Bool) {
        pinned.removeAll { $0 == chat }
        if pin { pinned.insert(chat, at: 0) }
    }

    /// nil takes it out of its project.
    public mutating func move(_ chat: UUID, to project: UUID?) {
        projectOfChat[chat] = project
    }

    @discardableResult
    public mutating func addProject(named name: String) -> Project {
        let project = Project(name: name)
        projects.append(project)
        return project
    }

    public mutating func renameProject(_ id: UUID, to name: String) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].name = name
    }

    /// Its chats stay, back among the recents.
    public mutating func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        projectOfChat = projectOfChat.filter { $0.value != id }
    }

    /// A deleted chat leaves no pin or project entry behind.
    public mutating func forget(_ chat: UUID) {
        pinned.removeAll { $0 == chat }
        projectOfChat[chat] = nil
    }

    /// Entries for chats that no longer exist are dropped (deleted in
    /// Finder, say); a project pointing nowhere is let go too.
    public mutating func prune(existing chats: Set<UUID>) {
        pinned.removeAll { !chats.contains($0) }
        let projectIDs = Set(projects.map(\.id))
        projectOfChat = projectOfChat.filter { chats.contains($0.key) && projectIDs.contains($0.value) }
    }
}

/// One saved chat as the sidebar lists it.
public struct ChatSummary: Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var updatedAt: Date
    /// Lowercased title and message text, for search.
    public var searchText: String

    public init(id: UUID, title: String, updatedAt: Date, searchText: String) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.searchText = searchText
    }

    /// Every word of the query, in any order, anywhere in the chat.
    public func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { searchText.contains($0) }
    }
}

/// The sidebar's recents, by how long ago they were last used.
public enum ChatAge: Int, CaseIterable, Comparable {
    case today, yesterday, previous7Days, previous30Days, older

    public static func < (a: ChatAge, b: ChatAge) -> Bool { a.rawValue < b.rawValue }

    public static func of(_ date: Date, now: Date, calendar: Calendar = .current) -> ChatAge {
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday { return .today }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 0
        switch days {
        case ...1: return .yesterday
        case ...7: return .previous7Days
        case ...30: return .previous30Days
        default: return .older
        }
    }

    /// Newest first within each group, groups in order, empty ones left out.
    public static func group(_ chats: [ChatSummary], now: Date, calendar: Calendar = .current) -> [(ChatAge, [ChatSummary])] {
        let byAge = Dictionary(grouping: chats) { of($0.updatedAt, now: now, calendar: calendar) }
        return allCases.compactMap { age in
            byAge[age].map { (age, $0.sorted { $0.updatedAt > $1.updatedAt }) }
        }
    }
}

/// A title the model suggested, cleaned up: its first line, no quotes or
/// "Title:" prefix, no trailing period, at most `maxLength` characters. nil
/// when nothing usable is left.
public func cleanedChatTitle(_ raw: String, maxLength: Int = 60) -> String? {
    var line = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    for prefix in ["title:", "заголовок:", "название:"] where line.lowercased().hasPrefix(prefix) {
        line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
    line = line.replacingOccurrences(of: "**", with: "")
    let quotes = CharacterSet(charactersIn: "\"'`«»“”‘’")
    line = line.trimmingCharacters(in: quotes.union(.whitespaces))
    while line.hasSuffix(".") { line.removeLast() }
    line = line.trimmingCharacters(in: quotes.union(.whitespaces))
    guard !line.isEmpty else { return nil }
    if line.count > maxLength {
        line = String(line.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
    return line
}
