import LLMTrayCore
import SwiftUI

/// The status line above a project chat (adr/0012): "Name · N files ·
/// ● Indexed · RAG on", always there in a project's chat -- what its files
/// are doing was only in the Files window before. Indexing shows the ring
/// and its progress, a failure why on hover; clicking opens the files (or,
/// with Project files off, Settings).
struct ProjectChatFilesRow: View {
    let sessionID: UUID
    @ObservedObject private var store = ChatLibraryStore.shared

    var body: some View {
        if let project = store.library.projectContext(forChat: sessionID) {
            VStack(spacing: 0) {
                ProjectChatStatusLine(project: project.id, name: project.name)
                Divider()
            }
        }
    }
}

/// The row's line for one project, and what the last add didn't take.
struct ProjectChatStatusLine: View {
    let project: UUID
    let name: String
    @ObservedObject private var indexer = ProjectIndexer.shared

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if indexer.isEnabled { ProjectFilesWindow.show(project) } else { openFilesSettings() }
            } label: {
                HStack(spacing: 6) {
                    ProjectRingIcon(ring: indexer.ring(for: project))
                    Text(name).lineLimit(1).truncationMode(.tail)
                    // The name truncates first, not the status.
                    status(project).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help(project))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            // A drop on the chat says here what it didn't take.
            if indexer.isEnabled, let note = indexer.addNotes[project] {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle").foregroundColor(.orange)
                    Text(note).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { indexer.dismissAddNote(project) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 5)
            }
        }
    }

    @ViewBuilder
    private func status(_ project: UUID) -> some View {
        if !indexer.isEnabled {
            HStack(spacing: 6) {
                dot
                Text("Project files are off")
                dot
                // What a click on the line does: Settings › Files.
                Text(GettingStarted.isProject(project)
                     ? NSLocalizedString("turn on in Settings to add the LLMTray guide", comment: "a project chat's status line: Getting Started's guide waits for Project files")
                     : NSLocalizedString("turn on in Settings", comment: "a project chat's status line: Project files are off"))
                    .foregroundColor(.accentColor)
            }
        } else {
            let docs = indexer.documents[project] ?? []
            let totals = ProjectFileTotals(docs)
            HStack(spacing: 6) {
                dot
                switch ProjectChatStatus(totals: totals, ring: indexer.ring(for: project)) {
                case .noFiles:
                    Text("No files yet")
                case .indexing:
                    filesCount(totals)
                    dot
                    // The ring (left) is the progress; this the words.
                    Text(indexer.statusText(for: project) ?? NSLocalizedString("Indexing", comment: "a project chat's status line"))
                        .truncationMode(.tail)
                case .indexed(let failed):
                    filesCount(totals)
                    dot
                    Label { Text("Indexed") } icon: { Circle().fill(Color.green).frame(width: 6, height: 6) }
                        .labelStyle(DotLabelStyle())
                    if failed > 0 {
                        dot
                        Text(String(format: NSLocalizedString("%lld failed", comment: "project indexing: files that failed"), Int64(failed)))
                            .foregroundColor(.orange)
                    }
                case .failed:
                    filesCount(totals)
                    dot
                    Text("Indexing failed").foregroundColor(.orange)
                case .notIndexed:
                    filesCount(totals)
                    dot
                    Text("Not indexed")
                }
                if totals.searchable > 0 {
                    dot
                    // Search by meaning needs the embedding model; without it
                    // the files are still searched, by their words.
                    Text(indexer.isEmbedderReady && indexer.embeddingUnavailable == nil
                         ? NSLocalizedString("RAG on", comment: "a project chat's status line: its files are searched by meaning")
                         : NSLocalizedString("Words only", comment: "a project chat's status line: its files are searched by their words, no embedding model"))
                }
                if let pinned = indexer.pins[project], !pinned.isEmpty {
                    Text(String(format: NSLocalizedString("· %lld pinned", comment: "a project chat's header: how many files are pinned (whole in its requests)"),
                                Int64(pinned.count)))
                }
            }
        }
    }

    private var dot: some View { Text(verbatim: "·") }

    private func filesCount(_ totals: ProjectFileTotals) -> some View {
        Text(String(format: NSLocalizedString("%lld files", comment: "a project chat's status line: how many files the project has"), Int64(totals.files)))
    }

    /// Why it failed (the first few files), what it's doing, or what a click does.
    private func help(_ project: UUID) -> String {
        guard indexer.isEnabled else {
            return NSLocalizedString("Turn on Project files in Settings to add files to the project and let its chats search them.", comment: "")
        }
        let failures = ProjectChatStatus.failureLines(indexer.documents[project] ?? [])
        var lines = [indexer.statusText(for: project)].compactMap { $0 }
        lines += failures
        if lines.isEmpty, ProjectFileTotals(indexer.documents[project] ?? []).searchable > 0, !indexer.isEmbedderReady {
            lines.append(NSLocalizedString("No embedding model: files are searched by their words. Download it in Settings > Files for search by meaning.", comment: ""))
        }
        lines.append(NSLocalizedString("Show the project's files", comment: ""))
        return lines.joined(separator: "\n")
    }
}

/// A 6 pt dot beside its text, closer than a Label's default spacing.
private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

/// An empty project chat's invitation to add files (adr/0012): dropped
/// here, or picked with Choose Files…, they go into the project -- as in
/// its Files window. With Project files off, the way to Settings instead
/// (nothing is turned on or downloaded from here).
struct ProjectChatDropZone: View {
    let sessionID: UUID
    let dropTargeted: Bool
    @ObservedObject private var store = ChatLibraryStore.shared
    @ObservedObject private var indexer = ProjectIndexer.shared

    var body: some View {
        if let project = store.library.projectContext(forChat: sessionID) {
            if indexer.isEnabled {
                ProjectDropZoneCard(project: project.id, hasFiles: ProjectFileTotals(indexer.documents[project.id] ?? []).files > 0,
                                    targeted: dropTargeted)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "folder.badge.questionmark").font(.title3)
                    Text("Project files are off").font(.callout)
                    Text("Turn on Project files to add files to a project and let its chats search them. Nothing is indexed or downloaded until then.")
                        .font(.caption).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button("Settings…") { openFilesSettings() }.controlSize(.small)
                }
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(12)
            }
        }
    }

}

/// The drop zone itself: files dropped or chosen go into `project`.
struct ProjectDropZoneCard: View {
    let project: UUID
    let hasFiles: Bool
    /// Dragged over the chat, which takes the drop (one handler: an image
    /// goes where it would anywhere else in the chat).
    let targeted: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down").font(.title2)
            Text("Drop files here").font(.callout)
            Text(hasFiles ? NSLocalizedString("Add more files: every chat of the project can search them.", comment: "an empty project chat's drop zone")
                          : NSLocalizedString("Files added here are copied into the project and indexed on this Mac; every chat of the project can search them.", comment: ""))
                .font(.caption).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Choose Files…") { ProjectFilesWindow.pickFiles(for: project) }.controlSize(.small)
        }
        .foregroundColor(targeted ? .accentColor : .secondary)
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(targeted ? 0.12 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .foregroundColor(targeted ? .accentColor : .secondary.opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop files here to add them to the project")
    }
}
