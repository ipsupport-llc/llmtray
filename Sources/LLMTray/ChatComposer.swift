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
    @Published var acceptsImages = false {
        didSet {
            if !acceptsImages { attachments.removeAll() } else { notice = nil }
        }
    }

    var isEmpty: Bool { draft.trimmingCharacters(in: .whitespaces).isEmpty && attachments.isEmpty }

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

    private func modelCantSeeImages() {
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
    func take() -> (text: String, images: [Data]) {
        defer { draft = ""; attachments = [] }
        return (draft, attachments)
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
    @ObservedObject var composer: ComposerModel
    @ObservedObject private var folders = FolderAccessManager.shared
    let canChat: Bool
    let canRegenerate: Bool
    let canCompact: Bool
    var isFocused: FocusState<Bool>.Binding
    let send: () -> Void
    let regenerate: () -> Void
    let compact: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            if canRegenerate || chat.lastTokensPerSecond != nil || canCompact || chat.currentSessionID == nil {
                turnActions
            }
            if !composer.attachments.isEmpty {
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
                if composer.acceptsImages {
                    Button { composer.pickImages() } label: { Image(systemName: "paperclip") }
                        .buttonStyle(.plain)
                        .help("Attach image(s) for the model to see")
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
                    .onDrop(of: [.fileURL, .image], isTargeted: nil) { composer.handleDrop($0) }
                    .background(PasteImageWatcher(isFocused: isFocused.wrappedValue) { composer.pasteImages() })
                    .focused(isFocused)
                    .disabled(!canChat)

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
