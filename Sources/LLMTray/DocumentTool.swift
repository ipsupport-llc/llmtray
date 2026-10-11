import AppKit
import Foundation
import LLMTrayCore

/// `make_document` (adr/0020): the model's Markdown and chart numbers to a
/// PDF laid out by the app. Opt-in (Settings > Files), saved chats only (a
/// temporary chat writes nothing, and printing writes a file), one per turn.
/// Trust kind ordinary: it sends nothing anywhere, changes no file, and its
/// output goes further only by the user's click.
@MainActor
final class MakeDocumentTool: ChatTool {
    static let toolName = DocumentSpec.schema.name
    let name = MakeDocumentTool.toolName
    var schema: ToolSchema? { DocumentSpec.schema }
    var definition: [String: Any] { DocumentSpec.schema.definition }
    /// Made one this turn: the next call is refused (and the tool isn't
    /// declared again while the turn's list may narrow).
    private(set) var madeThisTurn = false

    func isOffered(_ settings: ChatSettings) -> Bool { settings.documentsSession != nil }

    func startTurn() { madeThisTurn = false }

    func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        guard context.settings.documentsSession != nil else {
            return .text(UserDefaults.standard[Pref.documentsEnabled]
                ? "\(name) isn't available in a temporary chat: it writes nothing. The user can make documents in a saved chat."
                : "\(name) isn't available: making documents is turned off in Settings. Answer without it.")
        }
        guard !madeThisTurn else {
            return .refused("\(name): a document was already made in this turn. Do not call it again; say if it should change.")
        }
        let spec: DocumentSpec
        switch DocumentSpec.read(arguments) {
        case .success(let s): spec = s
        case .failure(let e): return .text(e.text)
        }
        let source = DocumentSource(arguments: Self.argumentsJSON(arguments), project: context.settings.project?.id)
        let pictures = await DocumentPictures.load(for: spec.content, project: context.settings.project?.id, chat: context.chat)
        switch await DocumentRenderer.render(spec, source: source, pictures: pictures) {
        case .success(let made):
            madeThisTurn = true
            var text = "Made the PDF \"\(made.title)\" (\(made.pages) page\(made.pages == 1 ? "" : "s")). "
                + "The user sees it in the chat and can open, save or share it. Don't repeat its content unless asked."
            let notes = spec.notes + made.notes
            if !notes.isEmpty { text += " Left out: " + notes.joined(separator: " ") }
            return .generatedDocument(made, text: text)
        case .failure(let error):
            return .text("\(name): \(error.text)")
        }
    }

    static func argumentsJSON(_ values: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The parent side of `LLMTray --render-document`: a fresh job folder, the
/// child under supervision (60 s, a memory limit, a small stdout), the PDF
/// and its thumbnail read back. Nothing goes into the chat's folder here:
/// `install` writes them there on the main actor, in the same step that
/// puts the card in the message -- a save in between could otherwise sweep
/// files no message lists yet, and a result dropped (another chat, Stop)
/// leaves nothing behind.
enum DocumentRenderer {
    struct Made {
        var pdf: Data
        var thumbnail: Data?
        var title: String
        var pages: Int
        var source: DocumentSource
        var notes: [String]
    }

    /// The thumbnail's size at most (the child makes it 400 px).
    static let maxThumbnailBytes = 512 * 1024

    /// Writes a made document into `folder` under the first free name
    /// (`O_EXCL`), its thumbnail beside it; the card's metadata.
    static func install(_ made: Made, in folder: URL) throws -> DocumentRef {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (fd, name) = try DocumentFileName.create(in: folder, title: made.title)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: made.pdf)
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            throw error
        }
        var thumbnail: String?
        if let thumb = made.thumbnail, thumb.count <= maxThumbnailBytes {
            let thumbName = "\(UUID().uuidString).thumb.png"
            if (try? thumb.write(to: folder.appendingPathComponent(thumbName), options: .withoutOverwriting)) != nil {
                thumbnail = thumbName
            }
        }
        return DocumentRef(id: UUID(), filename: name, thumbnail: thumbnail, title: made.title, pages: made.pages, source: made.source)
    }

    enum Failure: Error {
        case tooLarge
        case render(String)
        case write(String)

        var text: String {
            switch self {
            case .tooLarge: return "the document is too large to lay out (over 8 MB of page). Shorten it."
            case .render(let why): return "the document couldn't be made (\(why)). Tell the user."
            case .write(let why): return "the PDF couldn't be saved (\(why)). Tell the user."
            }
        }
    }

    /// `pictures`: the project pictures the content names, decoded already
    /// (DocumentPictures), by id.
    static func render(_ spec: DocumentSpec, source: DocumentSource, pictures: [String: PictureDecoding.Result] = [:]) async -> Result<Made, Failure> {
        // A picture's file in the job folder is its key: "<id>.jpg|png".
        let keys = Dictionary(uniqueKeysWithValues: pictures.map { ($0.key, $0.key + ($0.value.isJPEG ? ".jpg" : ".png")) })
        let (job, notes, tooLarge) = DocumentJob.make(spec, pictureKeys: keys)
        guard !tooLarge else { return .failure(.tooLarge) }
        guard let executable = Bundle.main.executablePath else { return .failure(.render("no executable")) }
        let jobDir = FileManager.default.temporaryDirectory.appendingPathComponent("llmtray-document-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: jobDir) }
        do {
            try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(job).write(to: jobDir.appendingPathComponent(DocumentJob.fileName))
            for (id, picture) in pictures { try picture.data.write(to: jobDir.appendingPathComponent(keys[id]!)) }
        } catch {
            return .failure(.render(error.localizedDescription))
        }
        let line = LineBox()
        let supervision = ProcessRunner.Supervision(
            timeout: DocumentJob.Limits.seconds, maxStdoutBytes: 4096,
            maxFootprintBytes: UInt64(DocumentJob.Limits.memoryBytes), jetsamLimitBytes: DocumentJob.Limits.memoryBytes)
        let exit: ProcessRunner.SupervisedExit
        do {
            exit = try await ProcessRunner.runSupervised(
                executable, ["--render-document", jobDir.path, "--parent", String(getpid())],
                supervision: supervision, onLine: { line.set($0); return true })
        } catch {
            return .failure(.render(error.localizedDescription))
        }
        if let limit = exit.limit {
            return .failure(.render(limit == .timeout ? "it took over a minute" : limit == .memory ? "it needed too much memory" : "\(limit.rawValue)"))
        }
        guard let data = line.value.data(using: .utf8),
              let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.render("the renderer stopped"))
        }
        if let error = answer["error"] as? String { return .failure(.render(error)) }
        guard let pages = answer["pages"] as? Int, pages > 0 else { return .failure(.render("no pages")) }
        let pdf = jobDir.appendingPathComponent(DocumentJob.output)
        guard let bytes = try? Data(contentsOf: pdf), bytes.count <= DocumentJob.Limits.pdfBytes else {
            return .failure(.render("no PDF"))
        }
        let thumbURL = jobDir.appendingPathComponent(DocumentJob.thumbnail)
        let thumbSize = (try? FileManager.default.attributesOfItem(atPath: thumbURL.path)[.size] as? Int) ?? Int.max
        let thumb = thumbSize <= maxThumbnailBytes ? try? Data(contentsOf: thumbURL) : nil
        return .success(Made(pdf: bytes, thumbnail: thumb, title: spec.title, pages: pages, source: source, notes: notes))
    }

    /// The child's one line (the supervising thread writes, the caller reads after).
    final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var line = ""
        func set(_ value: String) { lock.lock(); if line.isEmpty { line = value }; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return line }
    }
}

/// `load_tools` (adr/0020): loads an on-demand tool group into this chat.
/// Declared, with the same enum, in every request of a chat with an
/// on-demand group switched on -- also after loading, so the list changes
/// once. Ordinary trust; after outside text in the turn the group waits for
/// the user's next message (a file can't hand the model a new tool).
@MainActor
final class LoadToolsTool: ChatTool {
    let name = "load_tools"
    weak var toolbox: ChatToolbox?
    var definition: [String: Any] { ToolGroups.loaderSchema(groups: ToolGroups.all).definition }
    var schema: ToolSchema? { ToolGroups.loaderSchema(groups: ToolGroups.all) }

    func isOffered(_ settings: ChatSettings) -> Bool { !(toolbox?.onDemandGroups(settings).isEmpty ?? true) }

    func definition(for settings: ChatSettings) -> [String: Any]? {
        let groups = toolbox?.onDemandGroups(settings) ?? []
        return groups.isEmpty ? nil : ToolGroups.loaderSchema(groups: groups).definition
    }

    func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        let offered = toolbox?.onDemandGroups(context.settings) ?? []
        guard let name = arguments["group"] as? String, let group = offered.first(where: { $0.name == name }) else {
            let names = offered.map(\.name).joined(separator: ", ")
            return .text(names.isEmpty ? "load_tools: no tools can be loaded in this chat." : "load_tools: \"group\" must be one of \(names).")
        }
        if context.settings.loadedToolGroups.contains(group.name) {
            return .text("load_tools: \(group.name) is already loaded; its tools (\(group.tools.joined(separator: ", "))) are available.")
        }
        if context.untrustedTextThisTurn {
            return .loadedTools(group.name, pending: true, text: "load_tools: \(group.name) will be available from the user's next message "
                + "(it can't be loaded after file or web text in the same turn). Tell the user to ask again.")
        }
        return .loadedTools(group.name, pending: false, text: "load_tools: \(group.name) is loaded; \(group.tools.joined(separator: ", ")) "
            + "can be called from the next step. Call it now if the user's request needs it.")
    }
}

/// The project pictures a document names (adr/0020, "Project pictures"):
/// only the chat's project's, only while the chat is still in it (checked
/// before and after), each decoded in the child to 2400 px without
/// metadata, all of a document's together at most 60 MB.
@MainActor
enum DocumentPictures {
    static let maxTotalBytes = 60 * 1024 * 1024

    static func load(for content: String, project: UUID?, chat: UUID?) async -> [String: PictureDecoding.Result] {
        let refs = Array(DocumentJob.pictureRefs(content).prefix(DocumentSpec.Limits.pictures))
        guard !refs.isEmpty, let project, let chat, stillIn(project, chat) else { return [:] }
        var out: [String: PictureDecoding.Result] = [:]
        var total = 0
        for id in refs {
            guard let url = await ProjectIndexer.shared.pictureFile(id, in: project) else { continue }
            guard case .success(let decoded) = await PictureDecoding.decode(url, side: 2400) else { continue }
            guard total + decoded.data.count <= maxTotalBytes else { break }
            total += decoded.data.count
            out[id] = decoded
        }
        // Moved out meanwhile: none of them.
        return stillIn(project, chat) ? out : [:]
    }

    static func stillIn(_ project: UUID, _ chat: UUID) -> Bool {
        ChatLibraryStore.shared.library.projectContext(forChat: chat)?.id == project
    }
}
