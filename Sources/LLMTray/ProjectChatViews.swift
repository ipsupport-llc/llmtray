import AppKit
import LLMTrayCore
import SwiftUI
import UniformTypeIdentifiers

/// The status line above a project chat (adr/0012): "Name · N files ·
/// ● Indexed · RAG on", always there in a project's chat -- what its files
/// are doing was only in the Files window before. Indexing shows the ring
/// and its progress, a failure why on hover. A pill with a chevron, read
/// as plain text before: clicking lists the files with Add Files… (or,
/// with Project files off, turns them on).
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
            HStack(spacing: 0) {
                Button {
                    if indexer.isEnabled { ProjectFilesMenu.show(for: project) } else { turnOnProjectFiles() }
                } label: {
                    HStack(spacing: 6) {
                        ProjectRingIcon(ring: indexer.ring(for: project))
                        Text(name).lineLimit(1).truncationMode(.tail)
                        // The name truncates first, not the status.
                        status(project).lineLimit(1).layoutPriority(1)
                        if indexer.isEnabled {
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).layoutPriority(1)
                        }
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.25)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(help(project))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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
                .font(.subheadline)
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
                // What a click on the line does: turns them on.
                Text(GettingStarted.isProject(project)
                     ? NSLocalizedString("enable them to add the LLMTray guide", comment: "a project chat's status line: Getting Started's guide waits for Project files; a click turns them on")
                     : NSLocalizedString("click to enable", comment: "a project chat's status line: Project files are off; a click turns them on"))
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
            return NSLocalizedString("Click to enable Project files: add files to the project and let its chats search them.", comment: "")
        }
        let failures = ProjectChatStatus.failureLines(indexer.documents[project] ?? [])
        var lines = [indexer.statusText(for: project)].compactMap { $0 }
        lines += failures
        if lines.isEmpty, ProjectFileTotals(indexer.documents[project] ?? []).searchable > 0, !indexer.isEmbedderReady {
            lines.append(NSLocalizedString("No embedding model: files are searched by their words. Download it in Settings > Files for search by meaning.", comment: ""))
        }
        lines.append(NSLocalizedString("The project's files, and Add Files…", comment: "a project chat's status line: what a click shows"))
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
/// its Files window. With Project files off, the button turns them on
/// (asking first whether to download the embedding model, as Settings
/// does).
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
                    Text("Enable Project files to add files to a project and let its chats search them. Nothing is indexed or downloaded until then.")
                        .font(.caption).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button("Enable Project Files…") { turnOnProjectFiles() }.controlSize(.small)
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

/// The status line's menu: the project's files (a click shows them in the
/// Files window, where they're pinned and removed), Add Files… and Show
/// All Files…. An AppKit menu at the pointer, as the ring's: a SwiftUI
/// Menu's label can't draw the ring.
@MainActor
enum ProjectFilesMenu {
    /// Files listed by name; the rest are one "N more…" line.
    static let listed = 12

    static func show(for project: UUID) {
        let indexer = ProjectIndexer.shared
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let text = indexer.statusText(for: project) {
            let info = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            menu.addItem(.separator())
        }
        let docs = (indexer.documents[project] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let pinned = Set(indexer.pins[project] ?? [])
        for doc in docs.prefix(listed) {
            let item = ClosureMenuItem(doc.name) { ProjectFilesWindow.show(project) }
            item.image = NSImage(systemSymbolName: pinned.contains(doc.doc) ? "pin.fill" : "doc", accessibilityDescription: nil)
            menu.addItem(item)
        }
        if docs.count > listed {
            menu.addItem(ClosureMenuItem(String(format: NSLocalizedString("%lld more…", comment: "a project's files menu: the files not listed"),
                                                Int64(docs.count - listed))) { ProjectFilesWindow.show(project) })
        }
        if !docs.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(NSLocalizedString("Add Files…", comment: "a project's files menu")) { ProjectFilesWindow.pickFiles(for: project) })
        menu.addItem(ClosureMenuItem(NSLocalizedString("Show All Files…", comment: "a project's files menu")) { ProjectFilesWindow.show(project) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

/// Files dropped on, or added from, a chat that isn't in a project: files
/// live in projects, so this asks which one -- a new one named after the
/// chat, or one there is -- and moves the chat into it with them (they
/// were dropped and silently ignored before). Project files off: turned
/// on first, asking about the embedding model as Settings does.
@MainActor
enum ProjectFileOffer {
    static func offer(_ urls: [URL], chat: UUID?) async {
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        guard let chat else {
            alert.messageText = NSLocalizedString("A temporary chat can't hold files", comment: "")
            alert.informativeText = NSLocalizedString("Files go into a project, and a temporary chat is never in one. Start a new saved chat (⌘N) to add them.", comment: "")
            alert.runModal()
            return
        }
        // Nothing a project takes (folders, hidden files, formats not
        // indexed): said here, and no chat moved or project made for it.
        let accepted = await ProjectFileDrop.sort(urls).accepted
        guard !accepted.isEmpty else {
            alert.messageText = NSLocalizedString("These can't be added to a project", comment: "")
            alert.informativeText = NSLocalizedString("This version indexes text, Markdown, code, PDF, Word (docx, doc), ODT, RTF, HTML and spreadsheet (xlsx, ods) files; folders and hidden files can't be added.", comment: "")
            alert.runModal()
            return
        }
        let store = ChatLibraryStore.shared
        // What the project will take: a folder dropped along isn't named.
        let shown = accepted.prefix(5).map(\.lastPathComponent).joined(separator: ", ") + (accepted.count > 5 ? "…" : "")
        alert.messageText = NSLocalizedString("Add the files to a project?", comment: "a file dropped on a chat that isn't in a project")
        var info = String(format: NSLocalizedString("Files live in projects: every chat of a project can search them. This chat moves into the project with them.\n\n%@",
                                                    comment: "a file dropped on a chat that isn't in a project: the file names"), shown)
        if !ProjectIndexer.shared.isEnabled {
            info += "\n\n" + NSLocalizedString("Project files will be turned on first.", comment: "")
        }
        alert.informativeText = info
        // Numbered here if taken, so the choice names what it makes.
        let newName = uniqueName(projectName(for: chat, urls: accepted), taken: Set(store.library.projects.map(\.name)))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        // Items added to the menu, not by title: same-named projects would
        // replace each other.
        popup.menu?.addItem(NSMenuItem(title: String(format: NSLocalizedString("New project \u{201C}%@\u{201D}", comment: "where dropped files go: a new project, its name"), newName),
                                       action: nil, keyEquivalent: ""))
        let projects = store.library.projects
        if !projects.isEmpty { popup.menu?.addItem(.separator()) }
        let names = projects.map(\.name)
        for (index, project) in projects.enumerated() {
            // Two projects of one name numbered in the sidebar's order.
            let title = names.filter { $0 == project.name }.count > 1
                ? String(format: NSLocalizedString("%1$@ (%2$lld)", comment: "a project in a list: its name, then which of the same-named ones (1, 2…) in the sidebar's order"),
                         project.name, Int64(names[...index].filter { $0 == project.name }.count))
                : project.name
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = project.id
            popup.menu?.addItem(item)
        }
        popup.selectItem(at: 0)
        alert.accessoryView = popup
        alert.addButton(withTitle: NSLocalizedString("Add", comment: "add dropped files to the chosen project"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let chosen = popup.selectedItem?.representedObject as? UUID
        Task { @MainActor in
            guard await enableProjectFiles() else { return }
            // The chat deleted, or its empty tab closed, while Project files
            // were turned on (a download can take a while): nothing.
            guard ChatTabs.shared.index(of: chat) != nil || ChatSessionStore.exists(chat) else { return }
            let target: UUID
            if let chosen {
                // Deleted while Project files were turned on: nothing.
                guard store.library.project(chosen) != nil else { return }
                target = chosen
            } else if let made = store.addProject(named: uniqueName(newName, taken: Set(store.library.projects.map(\.name)))) {
                target = made.id
            } else {
                return
            }
            // Unpinned too, as a chat dragged onto a project: a pinned chat
            // shows under Pinned only.
            store.move(chat, to: target)
            store.setPinned(chat, false)
            await ProjectIndexer.shared.addFiles(urls, to: target)
        }
    }

    /// The chat's title; an unsaved chat has none: the first file's name.
    static func projectName(for chat: UUID, urls: [URL]) -> String {
        if let title = ChatLibraryStore.shared.chats.first(where: { $0.id == chat })?.title
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return urls.first?.deletingPathExtension().lastPathComponent ?? NSLocalizedString("New project", comment: "")
    }

    /// "Name", or "Name 2", "Name 3"… when taken.
    static func uniqueName(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) }!
    }
}

/// Turns Project files on when they're off (asking first whether to
/// download the embedding model, as the Settings switch does); a failed
/// download -- the feature is on by then, searching by words -- is shown.
/// Whether they're on now.
@MainActor
func enableProjectFiles() async -> Bool {
    let indexer = ProjectIndexer.shared
    if indexer.isEnabled { return true }
    if let failure = await ProjectFilesSection.turnOn() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("The embedding model couldn't be downloaded", comment: "")
        alert.informativeText = failure
        alert.runModal()
    }
    return indexer.isEnabled
}

/// The same, from a button.
@MainActor
func turnOnProjectFiles() {
    Task { _ = await enableProjectFiles() }
}

/// What a drag over the chat would do, over the whole chat while it's
/// there: only the empty project chat's drop zone said it before.
struct ChatDropOverlay: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 30))
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(detail).font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(.accentColor)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
        .padding(8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The chat's drop target: as `onDrop(of:isTargeted:)`, and whether the
/// drag carries files (an image dragged from a browser carries none), for
/// the overlay's words.
struct ChatAreaDrop: DropDelegate {
    @Binding var targeted: Bool
    @Binding var carriesFiles: Bool
    let perform: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL, .image]) }

    func dropEntered(info: DropInfo) {
        carriesFiles = info.hasItemsConforming(to: [.fileURL])
        targeted = true
    }

    func dropExited(info: DropInfo) { targeted = false }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        return perform(info.itemProviders(for: [.fileURL, .image]))
    }
}
