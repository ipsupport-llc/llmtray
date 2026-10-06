import AppKit
import LLMTrayCore
import SwiftUI
import UniformTypeIdentifiers

/// A project's files (adr/0012, UI): a window of its own, like the
/// instructions' -- the sidebar is also in the popover, where SwiftUI's
/// sheets don't present reliably. One window per project, brought to the
/// front when asked again.
@MainActor
enum ProjectFilesWindow {
    private static var windows: [UUID: NSWindow] = [:]

    @MainActor
    private final class Delegate: NSObject, NSWindowDelegate {
        static let shared = Delegate()

        func windowWillClose(_ notification: Notification) {
            ProjectFilesWindow.windows = ProjectFilesWindow.windows.filter { $0.value !== notification.object as? NSWindow }
        }
    }

    /// Its project was deleted.
    static func close(_ projectID: UUID) {
        windows[projectID]?.close()
    }

    /// Its project was renamed.
    static func retitle(_ projectID: UUID, _ name: String) {
        windows[projectID]?.title = title(name)
    }

    private static func title(_ name: String) -> String {
        String(format: NSLocalizedString("Files in %@", comment: "the project files window's title"), name)
    }

    static func show(_ projectID: UUID) {
        guard let project = ChatLibraryStore.shared.library.project(projectID) else { return }
        if let window = windows[projectID] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = title(project.name)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = NSHostingView(rootView: ProjectFilesView(projectID: projectID))
        window.center()
        window.delegate = Delegate.shared
        windows[projectID] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Add Files…: several at once; what isn't offered is refused after,
    /// with the reason (a file without an extension -- a Makefile -- is
    /// text, so the panel can't filter by type).
    static func pickFiles(for projectID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = NSLocalizedString("Add", comment: "the Add Files panel's button")
        panel.message = NSLocalizedString("Text, Markdown, code, PDF, Word (docx, doc), ODT, RTF, HTML and spreadsheet (xlsx, ods) files are indexed.", comment: "the Add Files panel")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { await ProjectIndexer.shared.addFiles(urls, to: projectID) }
    }
}

/// The file URLs a drop carries (Finder's drag), loaded off the drag.
enum ProjectFileDropLoader {
    /// The URLs as their loads finish (on any thread), in drop order after.
    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [(Int, URL)] = []

        func add(_ i: Int, _ url: URL) { lock.withLock { urls.append((i, url)) } }
        var ordered: [URL] { lock.withLock { urls.sorted { $0.0 < $1.0 }.map(\.1) } }
    }

    static let types: [UTType] = [.fileURL]

    static func carriesFiles(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    }

    /// Loads every provider's URL, then hands them all to `perform` on the
    /// main thread (one add for the whole drop).
    static func load(_ providers: [NSItemProvider], perform: @escaping @MainActor @Sendable ([URL]) -> Void) {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return }
        let group = DispatchGroup()
        let found = Found()
        for (i, provider) in files.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { found.add(i, url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let ordered = found.ordered
            MainActor.assumeIsolated { perform(ordered) }
        }
    }
}

private struct ProjectFilesView: View {
    let projectID: UUID
    @ObservedObject private var indexer = ProjectIndexer.shared
    @ObservedObject private var store = ChatLibraryStore.shared
    @State private var dropTargeted = false
    @State private var listDropTargeted = false
    @State private var toRemove: IndexedDocument?
    @State private var disk: (files: Int64, index: Int64)?
    @State private var actionError: String?
    /// The chat window's model: the pin limit shown is for it.
    @AppStorage(Pref.selectedModelID) private var selectedModelID: String?
    /// Read by the limit; here so a change in Settings redraws it.
    @AppStorage(Pref.pinnedFilesPercent) private var pinnedPercent

    private var documents: [IndexedDocument] { indexer.documents[projectID] ?? [] }
    private var pins: [Int64] { indexer.pins[projectID] ?? [] }
    /// At the selected model's ratio (learned from the server's counts).
    private var pinTokens: [Int64: Int] { indexer.pinTokens(projectID, model: selectedModelID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !indexer.isEnabled {
                offNote
            } else {
                let limit = ProjectIndexer.pinLimit(forModel: selectedModelID).tokens
                header
                if !pins.isEmpty { pinnedSummary(limit: limit) }
                controls
                if let note = indexer.addNotes[projectID] { addNote(note) }
                if let actionError {
                    Text(actionError).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                }
                dropZone
                list(limit: limit)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 320)
        .task(id: diskKey) {
            // Debounced: the documents change after every indexing step.
            if disk != nil { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            guard !Task.isCancelled else { return }
            let usage = await ProjectIndexer.diskUsage(for: projectID)
            if !Task.isCancelled { disk = usage }
        }
        .task(id: indexer.progress[projectID] != nil) {
            // Indexing on: measured every 10 s besides the debounced changes
            // (their task restarts at each step; this one doesn't).
            while !Task.isCancelled, indexer.progress[projectID] != nil {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                let usage = await ProjectIndexer.diskUsage(for: projectID)
                if !Task.isCancelled { disk = usage }
            }
        }
        .confirmationDialog(
            Text("Remove this file from the project?"), isPresented: Binding(get: { toRemove != nil }, set: { if !$0 { toRemove = nil } }),
            presenting: toRemove
        ) { doc in
            Button("Remove", role: .destructive) { remove(doc) }
        } message: { doc in
            Text(String(format: NSLocalizedString("\u{201C}%@\u{201D} and its index are deleted from the project. The file you added it from isn't touched.",
                                                  comment: "removing a project file"), doc.name))
        }
    }

    /// Re-read when the documents change (an add, a removal, a step done).
    private var diskKey: String {
        documents.map { "\($0.doc):\($0.rev):\($0.status.rawValue)" }.joined(separator: ",")
    }

    // MARK: - parts

    private var offNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Project files are turned off", systemImage: "folder.badge.questionmark").font(.headline)
            Text("Turn on Project files to add files to a project and let its chats search them. Nothing is indexed or downloaded until then.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Turn On…") { Task { actionError = await ProjectFilesSection.turnOn() } }
                    .keyboardShortcut(.defaultAction)
                Button("Settings…") { openFilesSettings() }
            }
            if let actionError {
                Text(actionError).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var header: some View {
        let t = ProjectFileTotals(documents)
        return VStack(alignment: .leading, spacing: 2) {
            Text(String(format: NSLocalizedString("%1$lld files · %2$lld searchable · %3$lld pages", comment: "project files totals"),
                        Int64(t.files), Int64(t.searchable), Int64(t.pages)))
                .font(.callout)
            if let disk {
                Text(String(format: NSLocalizedString("Copies %1$@ · index %2$@ on disk", comment: "project files: the copies' size, the index's size"),
                            ModelCatalog.format(disk.files), ModelCatalog.format(disk.index)))
                    .font(.caption).foregroundColor(.secondary)
            }
            if indexer.isEnabled, !indexer.isEmbedderReady {
                Text("No embedding model: files are searched by their words. Download it in Settings > Files for search by meaning.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let reason = indexer.embeddingUnavailable {
                Text(String(format: NSLocalizedString("Search by meaning is off for now: %@", comment: ""), reason))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Pinned: K files, ≈X of Y tokens", and which of them the model's room
    /// no longer holds (they're read with project_files instead).
    private func pinnedSummary(limit: Int) -> some View {
        let used = pins.compactMap { pinTokens[$0] }.reduce(0, +)
        let tooLong = PinnedFiles.fitting(pins, tokens: pinTokens, limitTokens: limit).tooLong
        let names = tooLong.compactMap { doc in documents.first { $0.doc == doc }?.name }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Label(String(format: NSLocalizedString("Pinned: %1$lld files, ≈%2$@ of %3$@ tokens",
                                                       comment: "project files: pinned files, their tokens, the model's limit"),
                             Int64(pins.count), Self.tokens(used), Self.tokens(limit)), systemImage: "pin.fill")
                    .font(.caption)
                // Sizes at the model's ratio from the server's counts, or
                // the estimator's until its first answer.
                Text(indexer.isPinRatioMeasured(model: selectedModelID)
                     ? NSLocalizedString("(measured for this model)", comment: "pinned files: their sizes come from the model's own token counts")
                     : NSLocalizedString("(estimate; exact after the first answer)", comment: "pinned files: their sizes are estimated until the model answers once"))
                    .font(.caption2).foregroundColor(.secondary)
            }
            Text("Every chat of the project gets their whole text; web search and image or music generation are off in those chats while a file is pinned.")
                .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if !names.isEmpty {
                Text(String(format: NSLocalizedString("Too long for the selected model's room now, read by search instead: %@",
                                                      comment: "pinned project files that don't fit the model: their names"),
                            names.map { "\u{201C}" + $0 + "\u{201D}" }.joined(separator: ", ")))
                    .font(.caption2).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func tokens(_ n: Int) -> String { n.formatted() }

    private var controls: some View {
        let ring = indexer.ring(for: projectID)
        let paused = indexer.isPaused(projectID)
        let canIndexNow = indexer.stopped.contains(projectID) || ProjectFileTotals(documents).notIndexed > 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProjectRingIcon(ring: ring, expanded: true)
                Text(indexer.statusText(for: projectID) ?? (documents.isEmpty ? NSLocalizedString("No files yet", comment: "project files")
                                                              : NSLocalizedString("Up to date", comment: "project files: nothing to index")))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button { ProjectFilesWindow.pickFiles(for: projectID) } label: { Label("Add Files…", systemImage: "plus") }
                Spacer(minLength: 0)
                if paused {
                    Button("Resume") { indexer.resume(projectID) }
                } else {
                    Button("Pause") { indexer.pause(projectID) }
                        .disabled(!ring.isActive)
                        .help("Pause indexing this project; it stays paused after a relaunch")
                }
                Button("Stop") { Task { await indexer.stop(projectID) } }
                    .disabled(!ring.isActive)
                    .help("Clear the queue: what's indexed stays searchable, the rest is marked not indexed")
                Button("Index Now") { Task { await indexer.indexNow(projectID) } }
                    .disabled(!canIndexNow)
                    .help("Index the files that were stopped")
            }
            .controlSize(.small)
        }
    }

    private func addNote(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle").foregroundColor(.orange)
            Text(note).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { indexer.dismissAddNote(projectID) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
    }

    private var dropZone: some View {
        VStack(spacing: 4) {
            Image(systemName: "tray.and.arrow.down").font(.title2)
            Text("Drop files here").font(.callout)
        }
        .foregroundColor(dropTargeted ? .accentColor : .secondary)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(dropTargeted ? 0.12 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .foregroundColor(dropTargeted ? .accentColor : .secondary.opacity(0.5)))
        .contentShape(Rectangle())
        .onTapGesture { ProjectFilesWindow.pickFiles(for: projectID) }
        .onDrop(of: ProjectFileDropLoader.types, isTargeted: $dropTargeted) { providers in
            ProjectFileDropLoader.load(providers) { urls in Task { await ProjectIndexer.shared.addFiles(urls, to: projectID) } }
            return ProjectFileDropLoader.carriesFiles(providers)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drop files here to add them to the project")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { ProjectFilesWindow.pickFiles(for: projectID) }
    }

    @ViewBuilder
    private func list(limit: Int) -> some View {
        if documents.isEmpty {
            Text("Files added here are copied into the project and indexed on this Mac; every chat of the project can search them.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(documents, id: \.doc) { doc in
                        row(doc, limit: limit)
                        Divider()
                    }
                }
            }
            // Files dropped on the list go in too.
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(listDropTargeted ? 0.08 : 0)))
            .onDrop(of: ProjectFileDropLoader.types, isTargeted: $listDropTargeted) { providers in
                ProjectFileDropLoader.load(providers) { urls in Task { await ProjectIndexer.shared.addFiles(urls, to: projectID) } }
                return ProjectFileDropLoader.carriesFiles(providers)
            }
        }
    }

    private func row(_ doc: IndexedDocument, limit: Int) -> some View {
        let status = indexer.displayStatus(doc, in: projectID)
        let pinned = pins.contains(doc.doc)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.icon(doc.ext)).foregroundColor(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.name).lineLimit(1).truncationMode(.middle).help(doc.name)
                HStack(spacing: 6) {
                    ProjectFileStatusLabel(status: status)
                    if let pages = doc.pages, pages > 0 {
                        Text(String(format: NSLocalizedString("%lld pages", comment: "a project file's page count"), Int64(pages)))
                    }
                    Text(ModelCatalog.format(doc.bytes))
                    if pinned {
                        Text(pinTokens[doc.doc].map { String(format: NSLocalizedString("Pinned · ≈%@ tokens", comment: "a pinned project file: its size"), Self.tokens($0)) }
                             ?? NSLocalizedString("Pinned", comment: "a pinned project file"))
                            .foregroundColor(.accentColor)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                if let error = doc.error, status == .failed || status == .notSupported || status == .empty || status == .ready || status == .readyWordsOnly {
                    // Why it failed, has no text, or why the last re-index didn't take.
                    Text(error).font(.caption2).foregroundColor(status == .failed ? .red : .secondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            pinButton(doc, pinned: pinned, limit: limit)
            Button { Task { await indexer.reindex(doc.doc, in: projectID) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(!Self.canReindex(status))
                .help("Re-index this file")
                .accessibilityLabel(String(format: NSLocalizedString("Re-index %@", comment: "a project file's action"), doc.name))
            Button { toRemove = doc } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(status == .removing)
                .help("Remove from the project")
                .accessibilityLabel(String(format: NSLocalizedString("Remove %@", comment: "a project file's action"), doc.name))
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    /// Pin / unpin (adr/0012, "Pinned files"): disabled, with why, for a
    /// file without searchable text yet or one that wouldn't fit.
    private func pinButton(_ doc: IndexedDocument, pinned: Bool, limit: Int) -> some View {
        let check = PinnedFiles.check(doc.doc, docs: documents, pins: pins, tokens: pinTokens, limitTokens: limit)
        let help: String
        var enabled = true
        switch check {
        case .alreadyPinned:
            help = NSLocalizedString("Unpin: the project's chats search this file again instead of getting all of it", comment: "a pinned project file's pin button")
        case .fits(let t):
            help = String(format: NSLocalizedString("Pin: every chat of the project gets the whole file (≈%@ tokens). Web search and image or music generation are off in those chats while it's pinned.",
                                                    comment: "a project file's pin button: its size"), Self.tokens(t))
        case .tooLong(let t, let used, let limit):
            enabled = false
            help = String(format: NSLocalizedString("Too long to pin with the selected model: ≈%1$@ tokens, ≈%2$@ of %3$@ left",
                                                    comment: "a project file's pin button: its size, what's left, the limit"),
                          Self.tokens(t), Self.tokens(max(0, limit - used)), Self.tokens(limit))
        case .noText, .noSuchFile:
            enabled = false
            help = doc.status.isSearchable ? NSLocalizedString("Measuring the file…", comment: "a project file's pin button, its size not known yet")
                : NSLocalizedString("Nothing to pin until the file has been read", comment: "a project file's pin button")
        }
        return Button { setPinned(doc, !pinned) } label: { Image(systemName: pinned ? "pin.fill" : "pin") }
            .buttonStyle(.borderless)
            .foregroundColor(pinned ? .accentColor : nil)
            // Unpinning is always possible.
            .disabled(!pinned && !enabled)
            .help(help)
            .accessibilityLabel(String(format: pinned ? NSLocalizedString("Unpin %@", comment: "a project file's action")
                                                      : NSLocalizedString("Pin %@", comment: "a project file's action"), doc.name))
    }

    private func setPinned(_ doc: IndexedDocument, _ on: Bool) {
        actionError = nil
        Task {
            do {
                try await indexer.setPinned(doc.doc, on, in: projectID)
            } catch {
                actionError = String(format: NSLocalizedString("\u{201C}%1$@\u{201D}: the pin couldn't be changed: %2$@", comment: "a project file's pin or unpin failed"),
                                     doc.name, error.localizedDescription)
            }
        }
    }

    private static func canReindex(_ s: DocumentDisplayStatus) -> Bool {
        switch s {
        case .ready, .readyWordsOnly, .empty, .failed, .notSupported: return true
        // Not indexed: Index Now does it (a re-index would race it).
        case .queued, .copying, .reading, .embedding, .removing, .notIndexed: return false
        }
    }

    private static func icon(_ ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "doc.richtext"
        case "html", "htm", "xhtml": return "globe"
        case "doc", "docx", "odt", "rtf": return "doc.text"
        case "xlsx", "xlsm", "ods", "csv", "tsv": return "tablecells"
        case "md", "markdown", "txt", "text": return "text.alignleft"
        default: return ProjectFileFormats.code.contains(ext.lowercased()) ? "chevron.left.forwardslash.chevron.right" : "doc"
        }
    }

    private func remove(_ doc: IndexedDocument) {
        actionError = nil
        Task {
            do {
                try await indexer.removeDocument(doc.doc, from: projectID)
            } catch {
                actionError = String(format: NSLocalizedString("\u{201C}%1$@\u{201D} couldn't be removed: %2$@", comment: "a project file's removal failed"),
                                     doc.name, error.localizedDescription)
            }
        }
    }
}

/// Opens Settings on the pane with the Project files switch.
@MainActor
func openFilesSettings() {
    NotificationCenter.default.post(name: .showSettings, object: nil, userInfo: ["pane": SettingsPane.folders.rawValue])
}

/// A document's status as the user sees it (adr/0012, the one mapping).
struct ProjectFileStatusLabel: View {
    let status: DocumentDisplayStatus

    var body: some View {
        HStack(spacing: 3) {
            if Self.isBusy(status) {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: Self.symbol(status)).foregroundColor(Self.color(status))
            }
            Text(Self.title(status)).foregroundColor(status == .failed ? .red : .secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.title(status))
    }

    static func isBusy(_ s: DocumentDisplayStatus) -> Bool { s == .copying || s == .reading || s == .embedding || s == .removing }

    static func title(_ s: DocumentDisplayStatus) -> String {
        switch s {
        case .queued: return NSLocalizedString("queued", comment: "project file status")
        case .copying: return NSLocalizedString("copying", comment: "project file status")
        case .reading: return NSLocalizedString("reading", comment: "project file status")
        case .embedding: return NSLocalizedString("embedding", comment: "project file status")
        case .readyWordsOnly: return NSLocalizedString("ready (words only)", comment: "project file status: searchable by its words, not yet by meaning")
        case .ready: return NSLocalizedString("ready", comment: "project file status")
        case .empty: return NSLocalizedString("no text", comment: "project file status: nothing to index in it")
        case .failed: return NSLocalizedString("failed", comment: "project file status")
        case .notSupported: return NSLocalizedString("not supported", comment: "project file status")
        case .notIndexed: return NSLocalizedString("not indexed", comment: "project file status: indexing was stopped")
        case .removing: return NSLocalizedString("removing", comment: "project file status")
        }
    }

    static func symbol(_ s: DocumentDisplayStatus) -> String {
        switch s {
        case .queued: return "clock"
        case .ready: return "checkmark.circle.fill"
        case .readyWordsOnly: return "checkmark.circle"
        case .empty: return "doc"
        case .failed: return "exclamationmark.triangle.fill"
        case .notSupported: return "nosign"
        case .notIndexed: return "pause.circle"
        case .copying, .reading, .embedding, .removing: return "circle.dotted"
        }
    }

    static func color(_ s: DocumentDisplayStatus) -> Color {
        switch s {
        case .ready: return .green
        case .failed: return .red
        case .notSupported: return .orange
        default: return .secondary
        }
    }
}

/// The project's icon (adr/0012, the user's design): the folder, or the
/// ring while it indexes -- ⏸ paused, dimmed while waiting -- or ⚠︎ with a
/// count. `expanded`: the Files view's larger one.
struct ProjectRingIcon: View {
    let ring: ProjectRing
    var folderOpen = true
    var expanded = false

    private var size: CGFloat { expanded ? 16 : 13 }

    var body: some View {
        HStack(spacing: 2) {
            switch ring.kind {
            case .folder:
                Image(systemName: folderOpen ? "folder.fill" : "folder").foregroundColor(.secondary)
            case .indexing, .waiting, .paused:
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                    if let fraction = ring.fraction {
                        Circle().trim(from: 0, to: max(0.03, fraction))
                            .stroke(ring.kind == .indexing ? Color.accentColor : Color.secondary,
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    if ring.kind == .paused {
                        Image(systemName: "pause.fill").font(.system(size: size * 0.45, weight: .bold)).foregroundColor(.secondary)
                    } else if ring.kind == .waiting {
                        Image(systemName: "hourglass").font(.system(size: size * 0.45, weight: .bold)).foregroundColor(.secondary)
                    }
                }
                .frame(width: size, height: size)
                if ring.failed > 0 { failedBadge }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                failedBadge
            }
        }
        .frame(minWidth: size, alignment: .leading)
    }

    private var failedBadge: some View {
        Text(verbatim: "\(ring.failed)")
            .font(.caption.weight(.semibold))
            .foregroundColor(.orange)
            .monospacedDigit()
    }
}
