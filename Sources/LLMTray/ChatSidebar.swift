import LLMTrayCore
import SwiftUI

/// The saved chats, as in ChatGPT / Claude on the web: new chat and search
/// on top, then pinned chats, projects (folders of chats) and the recents
/// by day. Beside the chat in its window; over it in the popover.
struct ChatSidebar: View {
    @EnvironmentObject var chat: ChatClient
    @ObservedObject private var store = ChatLibraryStore.shared
    /// Hides the sidebar (the popover's overlay closes; the window's
    /// collapses).
    let close: () -> Void
    /// The popover's overlay closes once a chat is picked.
    var closesOnOpen = false

    @State private var query = ""
    @State private var showsAllRecents = false
    @State private var renaming: UUID?
    @State private var renamingProject: UUID?
    @State private var draftName = ""
    @State private var chatToDelete: ChatSummary?
    @State private var projectToDelete: ChatLibrary.Project?
    @State private var collapsedProjects: Set<UUID> = []
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool

    private static let recentsShown = 25

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !query.isEmpty {
                        searchResults
                    } else {
                        pinnedSection
                        projectsSection
                        recentsSection
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(.regularMaterial)
        .confirmationDialog(
            Text("Delete this chat?"), isPresented: Binding(get: { chatToDelete != nil }, set: { if !$0 { chatToDelete = nil } }),
            presenting: chatToDelete
        ) { summary in
            Button("Delete", role: .destructive) { store.delete(summary.id, chat: chat) }
        } message: { summary in
            Text(summary.title)
        }
        .confirmationDialog(
            Text("Delete this project?"), isPresented: Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } }),
            presenting: projectToDelete
        ) { project in
            Button("Delete Project", role: .destructive) { store.deleteProject(project.id) }
        } message: { _ in
            Text("Its chats stay, back among the recents.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { close() } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.plain)
                    .help("Hide chats")
                    .accessibilityLabel("Hide chats")
                Spacer()
                Button { open { chat.newTemporaryChat() } } label: { Image(systemName: "eye.slash") }
                    .buttonStyle(.plain)
                    .help("New temporary chat -- nothing about it is ever saved")
                    .accessibilityLabel("New temporary chat")
            }
            .foregroundColor(.secondary)
            Button { open { chat.newSession() } } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SidebarRowStyle(isSelected: false))
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search chats", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { query = "" }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
        .padding(10)
    }

    // MARK: - Sections

    @ViewBuilder
    private var searchResults: some View {
        let found = store.chats.filter { $0.matches(query) }
        if found.isEmpty {
            Text("No chats found").foregroundColor(.secondary).padding(8)
        }
        ForEach(found) { row($0) }
    }

    @ViewBuilder
    private var pinnedSection: some View {
        let pinned = store.pinnedChats
        if !pinned.isEmpty {
            sectionTitle(Text("Pinned"))
            ForEach(pinned) { row($0) }
        }
    }

    private var projectsSection: some View {
        Group {
            HStack {
                sectionTitle(Text("Projects"))
                Spacer()
                Button { newProject() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
                    .help("New project")
                    .accessibilityLabel("New project")
            }
            ForEach(store.library.projects) { project in
                projectRow(project)
                if !collapsedProjects.contains(project.id) {
                    let chats = store.chats(inProject: project.id)
                    if chats.isEmpty {
                        Text("Move chats here from their menu")
                            .font(.caption).foregroundColor(.secondary)
                            .padding(.leading, 30).padding(.vertical, 3)
                    }
                    ForEach(chats) { row($0).padding(.leading, 18) }
                }
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        let recents = store.recentChats
        let shown = showsAllRecents ? recents : Array(recents.prefix(Self.recentsShown))
        if store.isLoaded && store.chats.isEmpty {
            Text("Saved chats will show up here.").foregroundColor(.secondary).font(.callout).padding(8)
        }
        ForEach(ChatAge.group(shown, now: Date()), id: \.0) { age, chats in
            sectionTitle(age.title)
            ForEach(chats) { row($0) }
        }
        if recents.count > shown.count {
            Button("Show more") { showsAllRecents = true }
                .buttonStyle(SidebarRowStyle(isSelected: false))
                .foregroundColor(.secondary)
        }
    }

    private func sectionTitle(_ title: Text) -> some View {
        title
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ summary: ChatSummary) -> some View {
        if renaming == summary.id {
            TextField("Chat name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .focused($renameFocused)
                .onSubmit { commitRename(summary.id) }
                .onExitCommand { renaming = nil }
                .padding(.vertical, 2)
        } else {
            Button { open { openChat(summary.id) } } label: {
                HStack(spacing: 6) {
                    if store.library.isPinned(summary.id) && !query.isEmpty {
                        Image(systemName: "pin.fill").font(.caption2).foregroundColor(.secondary)
                    }
                    Text(summary.title).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(SidebarRowStyle(isSelected: chat.currentSessionID == summary.id))
            .help(summary.title)
            .contextMenu { chatMenu(summary) }
        }
    }

    @ViewBuilder
    private func chatMenu(_ summary: ChatSummary) -> some View {
        Button("Rename…") { startRename(summary) }
        if store.library.isPinned(summary.id) {
            Button("Unpin") { store.setPinned(summary.id, false) }
        } else {
            Button("Pin") { store.setPinned(summary.id, true) }
        }
        Menu("Move to Project") {
            ForEach(store.library.projects) { project in
                Button(project.name) { store.move(summary.id, to: project.id) }
                    .disabled(store.library.projectOfChat[summary.id] == project.id)
            }
            if !store.library.projects.isEmpty { Divider() }
            Button("New Project…") {
                if let project = newProject() { store.move(summary.id, to: project.id) }
            }
            if store.library.projectOfChat[summary.id] != nil {
                Button("Remove from Project") { store.move(summary.id, to: nil) }
            }
        }
        Divider()
        Button("Delete…", role: .destructive) { chatToDelete = summary }
    }

    @ViewBuilder
    private func projectRow(_ project: ChatLibrary.Project) -> some View {
        if renamingProject == project.id {
            TextField("Project name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .focused($renameFocused)
                .onSubmit {
                    store.renameProject(project.id, to: draftName)
                    renamingProject = nil
                }
                .onExitCommand { renamingProject = nil }
                .padding(.vertical, 2)
        } else {
            Button {
                if collapsedProjects.contains(project.id) {
                    collapsedProjects.remove(project.id)
                } else {
                    collapsedProjects.insert(project.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsedProjects.contains(project.id) ? "folder" : "folder.fill")
                        .foregroundColor(.secondary)
                    Text(project.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(SidebarRowStyle(isSelected: false))
            .contextMenu {
                Button("Rename…") {
                    draftName = project.name
                    renamingProject = project.id
                    renameFocused = true
                }
                Button("Delete Project…", role: .destructive) { projectToDelete = project }
            }
        }
    }

    // MARK: - Actions

    private func open(_ action: () -> Void) {
        action()
        if closesOnOpen { close() }
    }

    private func openChat(_ id: UUID) {
        guard chat.currentSessionID != id, let file = ChatSessionStore.load(id: id) else { return }
        chat.loadSession(file)
    }

    private func startRename(_ summary: ChatSummary) {
        draftName = summary.title
        renaming = summary.id
        renameFocused = true
    }

    private func commitRename(_ id: UUID) {
        store.rename(id, to: draftName, chat: chat)
        renaming = nil
    }

    /// A project named "New project" (numbered if taken), renamed in place.
    @discardableResult
    private func newProject() -> ChatLibrary.Project? {
        let base = NSLocalizedString("New project", comment: "")
        let names = Set(store.library.projects.map(\.name))
        let name = names.contains(base) ? (2...).lazy.map { "\(base) \($0)" }.first { !names.contains($0) }! : base
        guard let project = store.addProject(named: name) else { return nil }
        collapsedProjects.remove(project.id)
        draftName = project.name
        renamingProject = project.id
        renameFocused = true
        return project
    }
}

extension ChatAge {
    var title: Text {
        switch self {
        case .today: return Text("Today")
        case .yesterday: return Text("Yesterday")
        case .previous7Days: return Text("Previous 7 Days")
        case .previous30Days: return Text("Previous 30 Days")
        case .older: return Text("Older")
        }
    }
}

/// A sidebar row: full width, highlighted when it's the open chat or hovered.
struct SidebarRowStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovered in
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(
                        isSelected ? Color.accentColor.opacity(0.18)
                            : Color.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.06 : 0)
                    )
                )
        }
    }

    private struct Hovering<Content: View>: View {
        @State private var hovered = false
        let content: (Bool) -> Content

        var body: some View {
            content(hovered).onHover { hovered = $0 }
        }
    }
}
