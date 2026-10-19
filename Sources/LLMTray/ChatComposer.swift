import Combine
import AppKit
import LLMTrayCore
import SwiftUI
import UniformTypeIdentifiers

/// An image loaded off the main thread and handed to it: nothing touches it
/// on the loading side afterwards. Swift 6's region analysis sees that on
/// its own; Swift 5.10 (CI) needs the promise spelled out.
private struct HandedOff<Value>: @unchecked Sendable {
    let value: Value
}

/// The message being composed: its text and attached images. Shared by the
/// composer and the chat area (images can be dropped on either).
@MainActor
final class ComposerModel: ObservableObject {
    @Published var draft = ""
    /// Always PNG -- ChatRequestBuilder sends them as image/png.
    @Published var attachments: [Data] = []
    /// Windows, the screen or browser tabs shown with the message
    /// (adr/0030): a capture goes as its image to a model that sees, as
    /// its recognized text to one that doesn't.
    @Published var shared: [SharedItem] = []
    /// A capture or a tab being read: a chip with a spinner meanwhile.
    @Published var isSharing = false

    struct SharedItem: Identifiable {
        var context: SharedContext
        /// A capture's PNG, for a model that sees.
        var image: Data?
        var id: UUID { context.id }
    }
    /// Only a vision-capable model can take images; switching to one that
    /// can't drops what's attached.
    /// What the model's template offers for thinking: the effort picker
    /// shows for one that thinks.
    @Published var thinkingStyle: ThinkingStyle = .none
    /// Recordings for a model that hears (WAV, ChatRecorder); switching to
    /// one that doesn't drops them. At most `maxRecordings` a message (the
    /// server takes eight clips a request).
    @Published var recordings: [Data] = []
    @Published var acceptsAudio = false {
        didSet { if !acceptsAudio { recordings.removeAll(); recorder.cancel() } }
    }
    let recorder = ChatRecorder()
    static let maxRecordings = 8
    private var recorderWatch: AnyCancellable?

    init() {
        // Send's state follows the recording (isEmpty reads it).
        recorderWatch = recorder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        recorder.onLimit = { [weak self] wav in self?.recordings.append(wav) }
    }
    @Published var acceptsImages = false {
        didSet {
            // A capture shown as an image goes too (a text model would get
            // nothing of it).
            if !acceptsImages { attachments.removeAll(); shared.removeAll { $0.image != nil } } else { notice = nil }
        }
    }

    var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespaces).isEmpty && attachments.isEmpty && recordings.isEmpty && shared.isEmpty
            && !recorder.isRecording
    }

    /// A short note under the field (an image the model can't take), gone
    /// after a few seconds.
    @Published private(set) var notice: String?
    private var noticeToken = 0

    func showNotice(_ text: String) {
        notice = text
        noticeToken += 1
        let token = noticeToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let self, self.noticeToken == token { self.notice = nil }
        }
    }

    func modelCantSeeImages() {
        showNotice(NSLocalizedString("This model can't see images: pick one that can (a vision model) to attach them.",
                                     comment: "chat: an image pasted or dropped for a model without vision"))
    }

    /// ⌘V in the field with an image on the clipboard: attached, like a
    /// dropped one (the text field itself pastes only text). Image files
    /// copied in Finder, or image data (a screenshot, Copy Image) when
    /// there's no text with it. Returns whether the paste was handled
    /// here; otherwise the field pastes as usual.
    func pasteImages(from pasteboard: NSPasteboard = .general) -> Bool {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL]) ?? []
        let images: [NSImage]
        let text = pasteboard.string(forType: .string)
        switch ClipboardImages.source(imageFiles: files.count, text: text,
                                      hasImageData: pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)) {
        case .files:
            images = files.compactMap { NSImage(contentsOf: $0) }
        case .imageData:
            images = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage]) ?? []
        case .text:
            return false
        }
        guard !images.isEmpty else { return false }
        guard acceptsImages else {
            modelCantSeeImages()
            return true
        }
        for image in images { attach(image) }
        return true
    }

    /// Takes the draft and attachments for sending and clears them.
    /// What's sent: a recording still going is stopped and goes too.
    func take() -> (text: String, images: [Data], audios: [Data], shared: [SharedContext]) {
        if let wav = recorder.stop() { recordings.append(wav) }
        defer { draft = ""; attachments = []; recordings = []; shared = [] }
        return (draft, attachments + shared.compactMap(\.image), recordings, shared.map(\.context))
    }

    /// Shows the model a window or the screen (adr/0030): the system
    /// picker, one still; its image for a model that sees, its text for
    /// one that doesn't.
    func shareWindow(screen: Bool) {
        guard !isSharing else { return }
        isSharing = true
        Task {
            defer { isSharing = false }
            let capture: ScreenShare.Capture
            switch await ScreenShare.shared.capture(screen: screen) {
            case .success(let c): capture = c
            case .failure(.cancelled): return
            case .failure(.busy):
                showNotice(NSLocalizedString("Another chat is picking a window: finish that first.", comment: "chat: a second window pick while one is open"))
                return
            case .failure(.failed):
                showNotice(NSLocalizedString("Nothing was captured: the window may have closed. Try again.", comment: "chat: a picked window gave no picture"))
                return
            }
            // Whether the model sees is read now, not at the click: the
            // model may have changed while the picker was up.
            if acceptsImages, let png = ImageAttachment.pngData(capture.image) {
                shared.append(SharedItem(context: capture.context, image: png))
                return
            }
            let base = capture.context
            let context = SharedContext(kind: base.kind, title: base.title, source: base.source,
                                        text: await ScreenShare.recognizeText(capture.image))
            guard context.text != nil else {
                showNotice(NSLocalizedString("No text was found in it, and this model can't see images: pick a vision model to show it as a picture.",
                                             comment: "chat: a window shown to a text-only model had no readable text"))
                return
            }
            shared.append(SharedItem(context: context))
        }
    }

    #if !APP_STORE
    /// Attaches the front tab of the browser last in front (adr/0030).
    func shareTab(_ browser: BrowserTab.Browser) {
        guard !isSharing else { return }
        isSharing = true
        Task {
            defer { isSharing = false }
            switch await ScreenShare.shared.readTab(browser) {
            case .success(let tab):
                shared.append(SharedItem(context: tab))
                if tab.titleOnly {
                    showNotice(String(format: NSLocalizedString("Only the tab's title and address: for its text, turn on View › Developer › Allow JavaScript from Apple Events in %@.",
                                                                comment: "chat: a Chromium browser's tab attached without its text"), browser.name))
                }
            case .failure(.notAllowed):
                showNotice(String(format: NSLocalizedString("LLMTray isn't allowed to read %@'s tab: turn it on in System Settings › Privacy & Security › Automation.",
                                                            comment: "chat: Automation for the browser was turned down"), browser.name))
            case .failure(.noTab):
                showNotice(String(format: NSLocalizedString("No open tab in %@.", comment: "chat: the browser has no window"), browser.name))
            }
        }
    }
    #endif


    func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            attach(NSImage(contentsOf: url))
        }
    }

    @discardableResult
    func attach(_ nsImage: NSImage?) -> Bool {
        // The bitmap rep's CGImage has the full pixel size (a Retina
        // image's own cgImage would be at its point size).
        guard acceptsImages, let nsImage,
              let tiff = nsImage.tiffRepresentation,
              let cgImage = NSBitmapImageRep(data: tiff)?.cgImage,
              let png = ImageAttachment.pngData(cgImage) else { return false }
        attachments.append(png)
        return true
    }

    /// Images dropped on the chat or the composer: files (incl. the
    /// floating screenshot thumbnail, which hands over a file URL) or raw
    /// image data.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard acceptsImages else {
            if providers.contains(where: { $0.canLoadObject(ofClass: NSImage.self) || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
                modelCantSeeImages()
            } else {
                // A file from Finder: an image only by its type, known once
                // its URL is loaded.
                for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return }
                        DispatchQueue.main.async { if !self.acceptsImages { self.modelCantSeeImages() } }
                    }
                }
            }
            return false
        }
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let image = NSImage(contentsOf: url)
                    DispatchQueue.main.async { self.attach(image) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    let image = HandedOff(value: obj as? NSImage)
                    DispatchQueue.main.async { self.attach(image.value) }
                }
            }
        }
        return handled
    }

    /// Dropping a file onto the text field itself makes AppKit's field
    /// editor insert its *path* as text before any SwiftUI drop handler
    /// sees it -- a dragged screenshot was sent as "/var/folders/...png" and
    /// the model replied it can't open local files. A path to an existing
    /// image file appearing in the draft becomes an attachment instead.
    func convertDroppedImagePaths() {
        guard acceptsImages, draft.contains("/") else { return }
        var remaining = draft
        var converted = false
        for line in draft.components(separatedBy: .newlines) {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard candidate.hasPrefix("/") || candidate.hasPrefix("file://") else { continue }
            let url = candidate.hasPrefix("file://") ? URL(string: candidate) : URL(fileURLWithPath: candidate)
            guard let url, url.isFileURL,
                  let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  FileManager.default.fileExists(atPath: url.path),
                  attach(NSImage(contentsOf: url)) else { continue }
            remaining = remaining.replacingOccurrences(of: candidate, with: "")
            converted = true
        }
        if converted {
            draft = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// The input bar: turn actions (regenerate, compact, tok/s), attachments,
/// the text field and Send/Stop.
struct ChatComposer: View {
    @EnvironmentObject var chat: ChatClient
    @AppStorage(Pref.documentsEnabled.name) private var documentsEnabled = Pref.documentsEnabled.defaultValue
    @AppStorage(Pref.screenSharingEnabled.name) private var sharingEnabled = Pref.screenSharingEnabled.defaultValue
    @ObservedObject private var mcp = MCPHub.shared

    /// The MCP servers' groups the + menu offers (switched on, tools reviewed).
    private var mcpGroups: [ToolGroups.Group] {
        _ = mcp.servers
        return ToolGroups.all.filter { g in !ToolGroups.builtInGroups.contains { $0.name == g.name } }
    }

    private func mcpTitle(_ group: ToolGroups.Group) -> String {
        mcp.servers.first { $0.key == group.name }?.name ?? group.name
    }
    @ObservedObject var composer: ComposerModel
    @ObservedObject private var folders = FolderAccessManager.shared
    @ObservedObject private var library = ChatLibraryStore.shared
    let canChat: Bool
    let canRegenerate: Bool
    let canCompact: Bool
    var isFocused: FocusState<Bool>.Binding
    let send: () -> Void
    let regenerate: () -> Void
    let compact: () -> Void
    /// A drop on the field: the chat's handler (files into the project).
    let dropFiles: ([NSItemProvider]) -> Bool

    var body: some View {
        VStack(spacing: 6) {
            if !canChat {
                // No model on this Mac yet: say what to do rather than a grey
                // field that reads as a broken app.
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox").foregroundStyle(.secondary)
                    Text("No chat model yet.").foregroundStyle(.secondary)
                    Button("Get a Model…") { NotificationCenter.default.post(name: .showSetupWizard, object: nil) }
                }
                .font(.callout)
                .padding(.horizontal, 12)
            }
            // Above the card, as before: the turn's actions and the folders
            // the chat may use, then the card.
            turnActions
            card
                .padding(.horizontal, 12)
            if let draft = chat.draft {
                // A Creator draft holds the chat (it waits for Generate or
                // Skip, or for its countdown): say so, not a silent Stop.
                Label(Self.draftHint(draft.kind), systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            if let notice = composer.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .transition(.opacity)
            }
            ModelDisclaimer.Line()
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
        // Room above, so the card doesn't run into the chat.
        .padding(.top, 8)
    }

    /// The message as one card, as ChatGPT's and Claude's: attachments and
    /// recordings at the top, the text, then a row -- + and the microphone
    /// on the left, the thinking effort and Send on the right.
    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !composer.attachments.isEmpty || !composer.recordings.isEmpty || !composer.shared.isEmpty || composer.isSharing {
                attachmentStrip
            }
            // Not disabled during streaming: a disabled NSTextField
            // resigns first responder, which kicked focus out of the
            // field every time a response started -- send's own guard
            // already stops a second send.
            TextField("Message…", text: $composer.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...8)
                .onSubmit(send)
                .onChange(of: composer.draft) { composer.convertDroppedImagePaths() }
                .background(PasteImageWatcher(isFocused: isFocused.wrappedValue) { composer.pasteImages() })
                .focused(isFocused)
                .disabled(!canChat)
                // Recording: the time and level over the field.
                .overlay {
                    if composer.recorder.isRecording || composer.recorder.heldPending { RecordingBar(recorder: composer.recorder) }
                }
            HStack(spacing: 12) {
                if chat.currentSessionID != nil || composer.acceptsImages || folders.isEnabled || sharingEnabled {
                    addMenu
                }
                if composer.acceptsAudio {
                    RecordButton(recorder: composer.recorder, full: composer.recordings.count >= ComposerModel.maxRecordings,
                                 done: { composer.recordings.append($0) },
                                 sendNow: { composer.recordings.append($0); send() })
                }
                Spacer(minLength: 8)
                if composer.thinkingStyle != .none {
                    ThinkingEffortPicker()
                }
                if chat.isBusy {
                    Button { chat.cancel() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 28))
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                    .accessibilityLabel("Stop generating")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                            .foregroundStyle(!canChat || composer.isEmpty ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Send")
                    .accessibilityLabel("Send")
                    .disabled(!canChat || composer.isEmpty)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.gray.opacity(0.3)))
        // The whole card takes a drop, not only the text.
        .contentShape(Rectangle())
        .onTapGesture { isFocused.wrappedValue = true }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { dropFiles($0) }
    }

    static func addHelp(files: Bool, images: Bool, folders: Bool) -> String {
        switch (files, images, folders) {
        case (true, true, true): return NSLocalizedString("Add files, images or folders", comment: "the composer's + menu")
        case (true, true, false): return NSLocalizedString("Add files or images", comment: "the composer's + menu")
        case (true, false, true): return NSLocalizedString("Add files or folders", comment: "the composer's + menu")
        case (true, false, false): return NSLocalizedString("Add files", comment: "the composer's + menu")
        case (false, true, true): return NSLocalizedString("Attach images or allow folders", comment: "the composer's + menu")
        case (false, true, false): return NSLocalizedString("Attach images", comment: "the composer's + menu")
        default: return NSLocalizedString("Allow folders", comment: "the composer's + menu")
        }
    }

    static func draftHint(_ kind: GenerationDraft.Kind) -> String {
        switch kind {
        case .music: return NSLocalizedString("The music draft above is open: Generate or Skip it to keep chatting.", comment: "")
        case .image: return NSLocalizedString("The image draft above is open: Generate or Skip it to keep chatting.", comment: "")
        case .edit: return NSLocalizedString("The image edit draft above is open: Generate or Skip it to keep chatting.", comment: "")
        }
    }

    /// "+": files into the chat's project (in a chat outside one, into a
    /// project it moves into with them), and images for a model that sees
    /// them. A paperclip for images only was all there was, and people
    /// looked there for files first.
    private var addMenu: some View {
        let id = chat.currentSessionID
        let project = id.flatMap { library.library.projectContext(forChat: $0) }
        return Menu {
            if let project {
                Button(String(format: NSLocalizedString("Add Files to \u{201C}%@\u{201D}…", comment: "the composer's + menu: files into the chat's project"), project.name)) {
                    let projectID = project.id
                    Task { @MainActor in
                        guard await enableProjectFiles() else { return }
                        ProjectFilesWindow.pickFiles(for: projectID)
                    }
                }
            } else if id != nil {
                Button("Add Files…") {
                    guard let urls = ProjectFilesWindow.chooseFiles() else { return }
                    Task { await ProjectFileOffer.offer(urls, chat: id) }
                }
            }
            if composer.acceptsImages {
                Button("Attach Images…") { composer.pickImages() }
            }
            // Showing the model what's on screen (adr/0030).
            if sharingEnabled {
                Divider()
                Button { composer.shareWindow(screen: false) } label: { Label("Show a Window…", systemImage: "macwindow") }
                Button { composer.shareWindow(screen: true) } label: { Label("Show the Screen…", systemImage: "display") }
                #if !APP_STORE
                if let browser = ScreenShare.shared.currentBrowser {
                    Button { composer.shareTab(browser) } label: {
                        Label(String(format: NSLocalizedString("Attach Tab from %@", comment: "+ menu: the front tab of a browser (its name)"), browser.name),
                              systemImage: "globe")
                    }
                }
                #endif
            }
            // Documents (adr/0020): loads their tools into this saved chat,
            // for a model that wouldn't think of load_tools.
            if id != nil, documentsEnabled {
                Divider()
                // On in every saved chat already (the profile's "Always"):
                // shown as on, not offered again.
                let always = ProfileManager.shared.resolved(for: UserDefaults.standard[Pref.selectedModelID])
                    .toolLoading[ToolGroups.documents] == .always
                if always || chat.loadedToolGroups.contains(ToolGroups.documents) {
                    Button { } label: { Label("Documents On in This Chat", systemImage: "checkmark") }
                        .disabled(true)
                } else {
                    Button("Make a Document…") {
                        chat.loadToolGroup(ToolGroups.documents)
                        composer.showNotice(NSLocalizedString("Documents are on in this chat: ask for one (a report, a letter…).", comment: "after the + menu's Make a Document…"))
                        isFocused.wrappedValue = true
                    }
                }
            }
            // MCP servers switched on (adr/0027): each loads its tools into
            // this saved chat.
            if id != nil, !mcpGroups.isEmpty {
                Divider()
                let profile = ProfileManager.shared.resolved(for: UserDefaults.standard[Pref.selectedModelID])
                ForEach(mcpGroups, id: \.name) { group in
                    if profile.toolLoading[group.name] == .always || chat.loadedToolGroups.contains(group.name) {
                        Button { } label: { Label(String(format: NSLocalizedString("%@ On in This Chat", comment: "+ menu: an MCP server's tools are loaded"),
                                                         mcpTitle(group)), systemImage: "checkmark") }
                            .disabled(true)
                    } else {
                        Button(String(format: NSLocalizedString("Use %@", comment: "+ menu: load an MCP server's tools"), mcpTitle(group))) {
                            chat.loadToolGroup(group.name)
                            composer.showNotice(String(format: NSLocalizedString("%@ is on in this chat: you'll be asked before each call.", comment: "after + menu's Use <server>"),
                                                       mcpTitle(group)))
                            isFocused.wrappedValue = true
                        }
                    }
                }
            }
            // Folder access (adr/0014), where the folder button was.
            if folders.isEnabled {
                Divider()
                Menu("Folders") { FolderMenuItems() }
                    // Read again when grants change.
                    .id(folders.grantsRevision)
            }
        } label: {
            Image(systemName: "plus.circle").font(.title3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // What's in it: files (a saved chat), images (a model that sees),
        // folders (folder access on).
        .help(Text(Self.addHelp(files: id != nil, images: composer.acceptsImages, folders: folders.isEnabled)))
        .accessibilityLabel(Text(Self.addHelp(files: id != nil, images: composer.acceptsImages, folders: folders.isEnabled)))
    }

    private var turnActions: some View {
        HStack {
            if chat.currentSessionID == nil {
                Label("Temporary — not saved", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if canRegenerate {
                Button(action: regenerate) {
                    Label("Regenerate", systemImage: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            if canCompact {
                Button(action: compact) {
                    Label("Compact", systemImage: "arrow.down.right.and.arrow.up.left").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(chat.isBusy)
            }
            ChatMemoryChip()
            ChatFolderChips()
            Spacer()
            if let tps = chat.lastTokensPerSecond {
                Text(String(format: "%.1f tok/s", tps))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(composer.recordings.enumerated()), id: \.offset) { i, wav in
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                        Text(RecordButton.time(Double(max(0, wav.count - 44)) / Double(2 * ChatRecorder.sampleRate)))
                            .monospacedDigit()
                        Button {
                            composer.recordings.remove(at: i)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Remove recording")
                        .accessibilityLabel("Remove recording")
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
                }
                ForEach(composer.shared) { item in
                    SharedChip(item: item) { composer.shared.removeAll { $0.id == item.id } }
                }
                if composer.isSharing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for your pick…").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
                }
                ForEach(Array(composer.attachments.enumerated()), id: \.offset) { i, data in
                    if let nsImage = NSImage(data: data) {
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .onTapGesture { ImageActions.openPreview(data, title: "Attachment") }
                                .pointingHandCursor()
                                .contextMenu {
                                    Button("Copy") { ImageActions.copy(data) }
                                    Button("Save…") { ImageActions.save(data, prompt: "attachment") }
                                }
                            Button {
                                composer.attachments.remove(at: i)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.callout)
                                    .foregroundColor(.white)
                                    .background(Circle().fill(Color.black.opacity(0.5)))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                            .help("Remove attachment")
                            .accessibilityLabel("Remove attachment")
                        }
                    }
                }
            }
        }
    }
}

/// ⌘V for the composer's field while it has focus in its window: `paste`
/// decides whether it's an image (handled, the key consumed) or text for
/// the field as usual. A text field's own paste takes only text.
private struct PasteImageWatcher: NSViewRepresentable {
    let isFocused: Bool
    let paste: () -> Bool

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.isFocused = isFocused
        view.paste = paste
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.isFocused = isFocused
        view.paste = paste
    }

    final class WatcherView: NSView {
        var isFocused = false
        var paste: (() -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isFocused, event.window === self.window,
                      // Caps Lock and the like aside, as every ⌘ shortcut.
                      event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                      ClipboardImages.isPasteKey(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode),
                      let paste = self.paste else { return event }
                return MainActor.assumeIsolated { paste() } ? nil : event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// The composer's thinking effort (adr/0022): Off, Low, Medium, High, for
/// a model that thinks -- one setting for every chat, as ChatGPT's.
struct ThinkingEffortPicker: View {
    @AppStorage(Pref.thinkingEffort.name) private var raw = Pref.thinkingEffort.defaultValue

    private var effort: ThinkingEffort { ThinkingEffort(rawValue: raw) ?? .high }

    var body: some View {
        Menu {
            ForEach(ThinkingEffort.allCases, id: \.self) { e in
                Button {
                    raw = e.rawValue
                } label: {
                    if e == effort { Label(e.title, systemImage: "checkmark") } else { Text(e.title) }
                }
            }
        } label: {
            Label(effort.title, systemImage: "brain")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Thinking effort: how long the model may think before it answers")
        .accessibilityLabel(Text(String(format: NSLocalizedString("Thinking effort: %@", comment: ""), effort.title)))
    }
}

/// The composer's microphone for a model that hears (adr/0023), as
/// Telegram's: a click records a clip that waits by the field (a second
/// click stops it); held, it's a walkie-talkie -- released, the message
/// goes at once (with the field's text), moved off the button first, the
/// recording is dropped.
struct RecordButton: View {
    @ObservedObject var recorder: ChatRecorder
    /// The message has as many recordings as it can take.
    var full = false
    /// A clip for the field.
    let done: (Data) -> Void
    /// Held and released over the button: send with this recording.
    let sendNow: (Data) -> Void
    @State private var pressed = false
    @State private var holding = false
    @State private var holdTask: Task<Void, Never>?
    @State private var lastLocation: CGPoint = .zero
    /// How long a press is before it's a hold.
    static let holdDelay: UInt64 = 300_000_000

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var disabled: Bool { recorder.isStarting || (full && !recorder.isRecording) }

    private func inside(_ p: CGPoint) -> Bool { CGRect(x: -16, y: -16, width: 56, height: 56).contains(p) }

    var body: some View {
        Image(systemName: recorder.heldPending ? "mic.fill"
              : recorder.isRecording ? (recorder.holdToSend ? "mic.fill" : "stop.circle.fill") : "mic")
            .font(.title3)
            .foregroundStyle(recorder.isRecording || recorder.heldPending ? Color.red : Color.primary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .opacity(disabled ? 0.4 : 1)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    lastLocation = value.location
                    if holding { recorder.holdAway = !inside(value.location) }
                    guard !disabled else { return }
                    if !pressed {
                        pressed = true
                        // A press on a clip being recorded is the click
                        // that stops it, never a hold.
                        if !recorder.isRecording {
                            holdTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: Self.holdDelay)
                                guard !Task.isCancelled, pressed else { return }
                                holding = true
                                recorder.holdToSend = true
                                recorder.holdAway = !inside(lastLocation)
                                await recorder.start()
                            }
                        }
                    }
                }
                .onEnded { value in
                    defer { pressed = false; holding = false; holdTask?.cancel(); holdTask = nil }
                    // A hold ends however it is (still starting too: the stop
                    // cancels that start): sent if released over the button.
                    if holding {
                        let keep = inside(value.location)
                        let wav = recorder.stop() ?? recorder.takeHeldClip()
                        if keep, let wav { sendNow(wav) }
                        return
                    }
                    guard !disabled else { return }
                    if recorder.isRecording {
                        if let wav = recorder.stop() { done(wav) }
                    } else {
                        Task { await recorder.start() }
                    }
                })
            .help(recorder.isRecording
                  ? (recorder.holdToSend ? "Release to send" : "Stop recording")
                  : "Click to record a clip; hold to talk and release to send (the model hears it)")
            .accessibilityElement()
            .accessibilityLabel(recorder.isRecording ? Text("Stop recording") : Text("Record"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if recorder.isRecording {
                    if let wav = recorder.stop() { done(wav) }
                } else if !disabled {
                    Task { await recorder.start() }
                }
            }
            .popover(isPresented: Binding(get: { recorder.problem != nil }, set: { if !$0 { recorder.problem = nil } })) {
                Text(recorder.problem ?? "").padding().frame(maxWidth: 320)
            }
            // Gone mid-press (another tab, a model that doesn't hear): no
            // start behind the user's back, a hold dropped.
            .onDisappear {
                holdTask?.cancel()
                holdTask = nil
                if holding { recorder.cancel(); _ = recorder.takeHeldClip() }
                pressed = false
                holding = false
            }
            // Esc drops a recording; ⌥⌘R starts or stops a clip. Behind the
            // button: no room taken, nothing for VoiceOver.
            .background {
                Group {
                    Button("") { recorder.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(!recorder.isRecording && !recorder.heldPending)
                    Button("") {
                        if recorder.isRecording {
                            if let wav = recorder.stop() { done(wav) }
                        } else if !disabled {
                            Task { await recorder.start() }
                        }
                    }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                }
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

/// Over the field while recording: the time, the level, what ends it.
struct RecordingBar: View {
    @ObservedObject var recorder: ChatRecorder

    /// A level (RMS) as a meter shows it: -60 dB to 0 over the bar's
    /// height (speech is around -40 to -15 dB: linear, it barely moved).
    static func barHeight(_ rms: Float) -> CGFloat {
        let db = 20 * log10(max(rms, 1e-6))
        let fraction = min(max((db + 60) / 60, 0), 1)
        return 2 + CGFloat(fraction) * 16
    }

    private var hint: String {
        if recorder.heldPending {
            return recorder.holdAway ? NSLocalizedString("Release to cancel", comment: "hold-to-talk, moved off the button")
                : NSLocalizedString("30 s reached · release to send, Esc to drop", comment: "hold-to-talk at the limit")
        }
        if recorder.holdToSend {
            return recorder.holdAway ? NSLocalizedString("Release to cancel", comment: "hold-to-talk, moved off the button")
                : NSLocalizedString("Release to send · move away to cancel", comment: "hold-to-talk")
        }
        return NSLocalizedString("Click ■ to stop · Esc cancels", comment: "recording a clip")
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text(RecordButton.time(recorder.seconds)).font(.callout.monospacedDigit())
            // The meter fills the room up to the hint: as many of the last
            // levels as fit, newest on the right.
            GeometryReader { geo in
                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array(recorder.levels.suffix(max(1, Int(geo.size.width / 5))).enumerated()), id: \.offset) { _, level in
                        Capsule().fill(Color.red.opacity(0.75))
                            .frame(width: 3, height: Self.barHeight(level))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .trailing)
            }
            .frame(height: 20)
            Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }
}

/// A window, the screen or a tab about to be shown (adr/0030): its picture
/// or symbol, what it is and what goes, a click to look at it, × to drop.
struct SharedChip: View {
    let item: ComposerModel.SharedItem
    let remove: () -> Void
    @State private var showsText = false

    var body: some View {
        HStack(spacing: 8) {
            preview
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: Self.title(item.context)).font(.callout.weight(.medium)).lineLimit(1)
                Text(verbatim: Self.detail(item.context, image: item.image != nil)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: 180, alignment: .leading)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Remove")
                .accessibilityLabel("Remove")
        }
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .pointingHandCursor()
        .popover(isPresented: $showsText, arrowEdge: .top) {
            ScrollView {
                Text(verbatim: item.context.text ?? item.context.source)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(width: 380, height: 300)
        }
        .help(Text(verbatim: item.context.heading))
    }

    @ViewBuilder private var preview: some View {
        if let data = item.image, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: Self.symbol(item.context.kind))
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
        }
    }

    private func open() {
        if let data = item.image {
            ImageActions.openPreview(data, title: Self.title(item.context))
        } else {
            showsText = true
        }
    }

    static func symbol(_ kind: SharedContext.Kind) -> String {
        switch kind {
        case .window: return "macwindow"
        case .screen: return "display"
        case .browserTab: return "globe"
        }
    }

    static func title(_ c: SharedContext) -> String {
        switch c.kind {
        case .window:
            return !c.title.isEmpty ? c.title : !c.source.isEmpty ? c.source : NSLocalizedString("Window", comment: "a shown window without a title")
        case .screen:
            return NSLocalizedString("Screen", comment: "the whole screen shown to the model")
        case .browserTab:
            return c.title.isEmpty ? (URL(string: c.source)?.host ?? c.source) : c.title
        }
    }

    /// What goes: a picture or text (its size); for a tab, its site.
    static func detail(_ c: SharedContext, image: Bool) -> String {
        switch c.kind {
        case .window, .screen:
            let app = c.kind == .window && !c.title.isEmpty && !c.source.isEmpty ? c.source + " · " : ""
            if image { return app + NSLocalizedString("Picture", comment: "a shown window goes as a picture") }
            let size = ByteCountFormatter.string(fromByteCount: Int64(c.text?.utf8.count ?? 0), countStyle: .file)
            return String(format: NSLocalizedString("Text · %@", comment: "a shown window goes as its recognized text (its size)"), size)
        case .browserTab:
            let host = URL(string: c.source)?.host ?? c.source
            return c.text == nil ? host + " · " + NSLocalizedString("no page text", comment: "a tab attached with its title and address only") : host
        }
    }
}
