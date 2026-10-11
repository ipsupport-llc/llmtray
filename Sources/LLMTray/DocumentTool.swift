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
        guard let session = context.settings.documentsSession else {
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
        switch await DocumentRenderer.render(spec, into: URL(fileURLWithPath: ChatSessionStore.imagesDir(for: session), isDirectory: true), source: source) {
        case .success(let made):
            madeThisTurn = true
            var text = "Made the PDF \"\(made.document.title)\" (\(made.document.pages) page\(made.document.pages == 1 ? "" : "s")). "
                + "The user sees it in the chat and can open, save or share it. Don't repeat its content unless asked."
            let notes = spec.notes + made.notes
            if !notes.isEmpty { text += " Left out: " + notes.joined(separator: " ") }
            return .generatedDocument(made.document, text: text)
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
/// child under supervision (60 s, a memory limit, a small stdout), then the
/// PDF and its thumbnail moved into the chat's folder under a new name.
enum DocumentRenderer {
    struct Made {
        var document: DocumentRef
        var notes: [String]
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

    static func render(_ spec: DocumentSpec, into chatFolder: URL, source: DocumentSource) async -> Result<Made, Failure> {
        let (job, notes, tooLarge) = DocumentJob.make(spec)
        guard !tooLarge else { return .failure(.tooLarge) }
        guard let executable = Bundle.main.executablePath else { return .failure(.render("no executable")) }
        let jobDir = FileManager.default.temporaryDirectory.appendingPathComponent("llmtray-document-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: jobDir) }
        do {
            try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(job).write(to: jobDir.appendingPathComponent(DocumentJob.fileName))
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
        do {
            try FileManager.default.createDirectory(at: chatFolder, withIntermediateDirectories: true)
            let (fd, name) = try DocumentFileName.create(in: chatFolder, title: spec.title)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: bytes)
            try handle.close()
            var thumbnail: String?
            if let thumb = try? Data(contentsOf: jobDir.appendingPathComponent(DocumentJob.thumbnail)) {
                let thumbName = "\(UUID().uuidString).thumb.png"
                if (try? thumb.write(to: chatFolder.appendingPathComponent(thumbName), options: .withoutOverwriting)) != nil {
                    thumbnail = thumbName
                }
            }
            let document = DocumentRef(id: UUID(), filename: name, thumbnail: thumbnail, title: spec.title, pages: pages, source: source)
            return .success(Made(document: document, notes: notes))
        } catch {
            return .failure(.write(error.localizedDescription))
        }
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
