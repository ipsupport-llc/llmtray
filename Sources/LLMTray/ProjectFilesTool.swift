import Foundation
import LLMTrayCore

/// project_files (adr/0012, "The chat side"): the chat's one project tool,
/// declared by what the chat's project has at the turn's start
/// (ProjectFilesMode) -- nothing without files or with the feature off, the
/// listing alone while nothing is searchable, else search, read and the
/// listing. Its work is LLMTrayCore's `ProjectFilesService` over the
/// indexer's registry and the embedder's shared runner. Its `pin` keeps a
/// file whole in the project's requests (adr/0012, "Pinned files"); a
/// temporary chat has no project, so it never gets here.
@MainActor
final class ProjectFilesTool: ChatTool {
    let name = ProjectFiles.toolName
    var schema: ToolSchema? { ProjectFiles.schema }
    var definition: [String: Any] { ProjectFiles.definition(for: .all) ?? [:] }
    /// File text, the listing included (the trust barrier), and the
    /// budget's no-room rule.
    var projectAccess: ProjectToolAccess { .fileText }

    private var indexer: ProjectIndexer { .shared }

    func mode(_ settings: ChatSettings) -> ProjectFilesMode {
        ProjectFilesMode(featureOn: indexer.isEnabled, project: settings.project)
    }

    func isOffered(_ settings: ChatSettings) -> Bool { mode(settings) != .none }

    /// The turn's mode; not declared at all once no room is left for file
    /// text -- the request only grows within a turn, so even the listing
    /// would find none (a call anyway gets the no-room answer).
    func definition(for settings: ChatSettings, fileTextAllowed: Bool) -> [String: Any]? {
        fileTextAllowed ? ProjectFiles.definition(for: mode(settings)) : nil
    }

    func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        guard let project = context.settings.project, let chat = context.chat else {
            return .text("\(name) isn't available in this chat. Answer without it.")
        }
        guard indexer.isEnabled else { return .text("Project files have been turned off in Settings. Answer without them.") }
        let request: ProjectFiles.Request
        switch ProjectFiles.request(arguments) {
        case .failure(let error): return .text(error.message)
        case .success(let r): request = r
        }
        // A tool's text this turn can't pin a file (unpinning is fine).
        if case .pin(_, true) = request, !context.pinAllowed { return .refused(ToolTrust.pinRefusal) }
        let answer = await indexer.filesService.run(
            request, project: project.id,
            byteBudget: context.projectTextBytes ?? ProjectTextBudget.bytes(forTokens: ProjectTextBudget.hardCapTokens),
            fileTextAllowed: context.fileTextAllowed,
            // A pin is for the project's chats, with this chat's model's room.
            pinLimitTokens: ProjectIndexer.pinLimit(for: context.settings).tokens,
            stillOwned: { ChatLibraryStore.shared.library.chat(chat, isIn: project.id) })
        switch answer {
        case .output(let output): return .projectText(output)
        case .text(let text): return .text(text)
        case .refused(let text): return .refused(text)
        }
    }
}
