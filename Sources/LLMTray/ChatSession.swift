import Foundation

extension Notification.Name {
    // Posted by ChatSessionStore.save()/delete() -- ContentView's History
    // menu reads its session list into @State (not a live disk scan on
    // every render), since a plain `Menu`'s content closure isn't
    // guaranteed to re-run just because the menu is reopened, especially
    // for nested submenus (confirmed live: a deleted session kept showing
    // up in the list until relaunch without this).
    static let sessionsDidChange = Notification.Name("LLMTray.sessionsDidChange")
}

/// The persisted subset of a ChatMessage -- deliberately narrower than the
/// in-memory struct. toolCalls/toolCallID are dropped: OpenAI tool-calling
/// wire plumbing, meaningless after a restart (there's no live pending
/// call to resume), and "tool" role messages are filtered out entirely
/// when saving (see ChatClient.persistCurrentSession) -- a resumed session
/// is a plain readable user/assistant transcript. Generated images ARE
/// persisted (as sibling files, see ChatSessionStore.imagesDir) -- unlike
/// a temporary chat's images, which still never touch disk at all.
struct PersistedMessage: Codable {
    var role: String
    var content: String
    var reasoning: String
    var isSummary: Bool
    // Filenames (not full paths) under this session's imagesDir, in the
    // same order as the original ChatMessage.images.
    var imageFilenames: [String]
    // Same index alignment as imageFilenames -- see ChatMessage.imageDurations.
    var imageDurations: [Double]
    // Same index alignment -- see ChatMessage.imagePrompts.
    var imagePrompts: [String]
    // See ChatMessage.sources.
    var sources: [String]

    enum CodingKeys: String, CodingKey {
        case role, content, reasoning, isSummary, imageFilenames, imageDurations, imagePrompts, sources
    }

    init(
        role: String, content: String, reasoning: String, isSummary: Bool,
        imageFilenames: [String] = [], imageDurations: [Double] = [], imagePrompts: [String] = [], sources: [String] = []
    ) {
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.isSummary = isSummary
        self.imageFilenames = imageFilenames
        self.imageDurations = imageDurations
        self.imagePrompts = imagePrompts
        self.sources = sources
    }

    // Custom init (rather than relying on synthesis) so that session files
    // written before imageFilenames/imageDurations/imagePrompts existed
    // (v0.5.0/v0.5.1) still decode instead of the whole session silently
    // vanishing from the list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        reasoning = try c.decode(String.self, forKey: .reasoning)
        isSummary = try c.decode(Bool.self, forKey: .isSummary)
        imageFilenames = try c.decodeIfPresent([String].self, forKey: .imageFilenames) ?? []
        imageDurations = try c.decodeIfPresent([Double].self, forKey: .imageDurations) ?? []
        imagePrompts = try c.decodeIfPresent([String].self, forKey: .imagePrompts) ?? []
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
    }
}

struct ChatSessionFile: Codable, Identifiable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [PersistedMessage]
}

/// One JSON file per session under Application Support/LLMTray/sessions/ --
/// human-inspectable "logs" per the feature's own goal, and simple enough
/// that a session list is just "read every file in this directory." Each
/// session's generated images live alongside it in a sibling
/// "<uuid>-images/" directory (see imagesDir) rather than inline/base64 in
/// the JSON, so the log itself stays small and readable.
enum ChatSessionStore {
    static var sessionsDir: String {
        RuntimePaths.externalRuntimeDir + "/sessions"
    }

    private static func path(for id: UUID) -> String {
        sessionsDir + "/\(id.uuidString).json"
    }

    static func imagesDir(for id: UUID) -> String {
        sessionsDir + "/\(id.uuidString)-images"
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func save(_ file: ChatSessionFile) {
        try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: URL(fileURLWithPath: path(for: file.id)))
        NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
    }

    static func load(id: UUID) -> ChatSessionFile? {
        guard let data = FileManager.default.contents(atPath: path(for: id)) else { return nil }
        return try? decoder.decode(ChatSessionFile.self, from: data)
    }

    /// Newest first. Reads every file fully rather than keeping a separate
    /// lightweight index -- session files are small text, and this is only
    /// called when the user opens the history menu, not on every keystroke.
    static func list() -> [ChatSessionFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> ChatSessionFile? in
                guard let data = FileManager.default.contents(atPath: sessionsDir + "/" + name) else { return nil }
                return try? decoder.decode(ChatSessionFile.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func delete(id: UUID) {
        try? FileManager.default.removeItem(atPath: path(for: id))
        try? FileManager.default.removeItem(atPath: imagesDir(for: id))
        NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
    }
}
