import Foundation

/// The persisted subset of a ChatMessage -- deliberately narrower than the
/// in-memory struct. Dropped on purpose:
///   - images: generated pictures stay in-memory-only by design (see
///     ChatMessage's own doc comment) -- a resumed session shows text only,
///     never a cached copy of a generated image.
///   - toolCalls/toolCallID: OpenAI tool-calling wire plumbing, meaningless
///     after a restart (there's no live pending call to resume), and
///     "tool" role messages are filtered out entirely when saving (see
///     ChatClient.persistCurrentSession) -- a resumed session is a plain
///     readable user/assistant transcript.
struct PersistedMessage: Codable {
    var role: String
    var content: String
    var reasoning: String
    var isSummary: Bool
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
/// that a session list is just "read every file in this directory."
enum ChatSessionStore {
    static var sessionsDir: String {
        RuntimePaths.externalRuntimeDir + "/sessions"
    }

    private static func path(for id: UUID) -> String {
        sessionsDir + "/\(id.uuidString).json"
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
    }
}
