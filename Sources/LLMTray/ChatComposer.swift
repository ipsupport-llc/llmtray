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
            if !acceptsImages { attachments.removeAll() } else { notice = nil }
        }
    }

    var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespaces).isEmpty && attachments.isEmpty && recordings.isEmpty && !recorder.isRecording
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
    func take() -> (text: String, images: [Data], audios: [Data]) {
        if let wav = recorder.stop() { recordings.append(wav) }
        defer { draft = ""; attachments = []; recordings = [] }
        return (draft, attachments, recordings)
    }

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
        VStack(spacing: 4) {
            if canRegenerate || chat.lastTokensPerSecond != nil || canCompact || chat.currentSessionID == nil {
                turnActions
            }
            if !composer.attachments.isEmpty || !composer.recordings.isEmpty {
                attachmentStrip
            }
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
            HStack(spacing: 8) {
                if chat.currentSessionID != nil || composer.acceptsImages {
                    addMenu
                }
                if folders.isEnabled {
                    ChatFolderMenu()
                }
                // Not disabled during streaming: a disabled NSTextField
                // resigns first responder, which kicked focus out of the
                // field every time a response started -- send's own guard
                // already stops a second send.
                TextField("Message…", text: $composer.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                    .onChange(of: composer.draft) { composer.convertDroppedImagePaths() }
                    .onDrop(of: [.fileURL, .image], isTargeted: nil) { dropFiles($0) }
                    .background(PasteImageWatcher(isFocused: isFocused.wrappedValue) { composer.pasteImages() })
                    .focused(isFocused)
                    .disabled(!canChat)
                    // Recording: the time and level over the field.
                    .overlay {
                        if composer.recorder.isRecording || composer.recorder.heldPending { RecordingBar(recorder: composer.recorder) }
                    }

                if composer.acceptsAudio {
                    RecordButton(recorder: composer.recorder, full: composer.recordings.count >= ComposerModel.maxRecordings,
                                 done: { composer.recordings.append($0) },
                                 sendNow: { composer.recordings.append($0); send() })
                }
                if composer.thinkingStyle != .none {
                    ThinkingEffortPicker()
                }
                if chat.isBusy {
                    Button { chat.cancel() } label: { Image(systemName: "stop.fill") }
                        .help("Stop generating")
                        .accessibilityLabel("Stop generating")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill") }
                        .help("Send")
                        .accessibilityLabel("Send")
                        .disabled(!canChat || composer.isEmpty)
                }
            }
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
            // Documents (adr/0020): loads their tools into this saved chat,
            // for a model that wouldn't think of load_tools.
            if id != nil, documentsEnabled {
                Divider()
                if chat.loadedToolGroups.contains(ToolGroups.documents) {
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
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(id == nil ? Text("Attach images for the model to see")
              : composer.acceptsImages ? Text("Add files to a project, or images for the model to see")
              : Text("Add files to a project"))
        .accessibilityLabel(id == nil ? Text("Attach images") : composer.acceptsImages ? Text("Add files or images") : Text("Add files"))
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
        .padding(.horizontal, 12)
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
        Image(systemName: recorder.isRecording ? (recorder.holdToSend ? "mic.fill" : "stop.circle.fill") : "mic")
            .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)
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

    private var hint: String {
        if recorder.heldPending {
            return NSLocalizedString("30 s reached · release to send, Esc to drop", comment: "hold-to-talk at the limit")
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
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(recorder.levels.suffix(28).enumerated()), id: \.offset) { _, level in
                    Capsule().fill(Color.red.opacity(0.7))
                        .frame(width: 3, height: max(2, min(18, CGFloat(level) * 120)))
                }
            }
            .frame(height: 20)
            Spacer(minLength: 4)
            Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }
}
