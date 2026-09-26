import Foundation
import SwiftUI

/// Creator mode: an image or song the chat model asks for is shown first as
/// an editable draft -- the prompt it wrote, the model, the knobs -- that
/// goes ahead by itself after a short countdown unless the user touches it.
/// Also what "Tweak…" on a finished image or song opens.
@MainActor
final class GenerationDraft: ObservableObject, Identifiable {
    enum Kind { case image, edit, music }
    enum Outcome { case run, skip }

    enum Aspect: String, CaseIterable, Identifiable {
        case square, landscape, portrait, wide, tall
        var id: String { rawValue }
        var label: String {
            switch self {
            case .square: return "1:1"
            case .landscape: return "3:2"
            case .portrait: return "2:3"
            case .wide: return "16:9"
            case .tall: return "9:16"
            }
        }
        /// About a megapixel at this ratio, sides a multiple of 16.
        var size: (width: Int, height: Int) {
            switch self {
            case .square: return (1024, 1024)
            case .landscape: return (1248, 832)
            case .portrait: return (832, 1248)
            case .wide: return (1360, 768)
            case .tall: return (768, 1360)
            }
        }
        static func closest(width: Int, height: Int) -> Aspect {
            let ratio = Double(width) / Double(max(height, 1))
            return allCases.min { abs(Double($0.size.width) / Double($0.size.height) - ratio)
                < abs(Double($1.size.width) / Double($1.size.height) - ratio) } ?? .square
        }
    }

    let id = UUID()
    let kind: Kind
    let call: ToolCall
    /// Tweak: the image or song it remakes (message, index), shown right
    /// under it; nil = a new one, shown at the chat's end.
    var anchor: (message: UUID, index: Int)?
    @Published var prompt: String
    @Published var lyrics: String
    @Published var duration: Int
    @Published var imageModel: ImageGenModel
    @Published var editModel: ImageGenModel?
    @Published var aspect: Aspect
    @Published var musicModel: MusicModel
    @Published var creativity: Double
    @Published var adherence: Double
    /// Seconds left before it goes ahead by itself; nil = waiting for the user.
    @Published private(set) var remaining: Double?
    private(set) var countdownTotal: Double = 3
    private let arguments: [String: Any]
    /// The shape the call asked for: its exact size is kept unless the
    /// user picks another shape.
    private let requestedAspect: Aspect
    private var continuation: CheckedContinuation<Outcome?, Never>?
    private var ticker: Task<Void, Never>?

    init(kind: Kind, call: ToolCall, settings: ChatSettings) {
        self.kind = kind
        self.call = call
        let args = ChatToolbox.parseArguments(call.argumentsJSON)
        arguments = args
        prompt = (args["prompt"] as? String) ?? ""
        lyrics = (args["lyrics"] as? String) ?? ""
        duration = MusicToolRunner.duration(args["duration"])
        imageModel = settings.imageGenModel
        editModel = settings.imageEditModel
        let asked = Aspect.closest(width: (args["width"] as? Int) ?? 1024, height: (args["height"] as? Int) ?? 1024)
        aspect = asked
        requestedAspect = asked
        musicModel = settings.musicModel
        creativity = MusicToolRunner.unit(args["creativity"]) ?? settings.musicCreativity
        adherence = MusicToolRunner.unit(args["adherence"]) ?? settings.musicAdherence
    }

    /// Waits for the user (or the countdown). nil = cancelled (Stop, another
    /// chat).
    func decide(countdown: Int) async -> Outcome? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Outcome?, Never>) in
                continuation = c
                // Cancelled before it got here: cancel() had no draft to resolve.
                if Task.isCancelled {
                    resolve(nil)
                    return
                }
                startCountdown(countdown)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(nil) }
        }
    }

    private func startCountdown(_ countdown: Int) {
        guard countdown > 0 else { return }
        countdownTotal = Double(countdown)
        remaining = Double(countdown)
        ticker = Task { [weak self] in
            while let self, let left = self.remaining, !Task.isCancelled {
                if left <= 0 {
                    self.resolve(.run)
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
                if self.remaining != nil { self.remaining = max(0, left - 0.1) }
            }
        }
    }

    /// Any edit: the countdown stops, the user starts it.
    func hold() {
        remaining = nil
        ticker?.cancel()
    }

    func resolve(_ outcome: Outcome?) {
        ticker?.cancel()
        remaining = nil
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    /// The call as edited.
    var editedCall: ToolCall {
        var args = arguments
        args["prompt"] = prompt
        switch kind {
        case .image where aspect != requestedAspect:
            args["width"] = aspect.size.width
            args["height"] = aspect.size.height
        case .image, .edit:
            break
        case .music:
            args["lyrics"] = lyrics
            args["duration"] = duration
            args["creativity"] = creativity
            args["adherence"] = adherence
        }
        let json = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? call.argumentsJSON
        return ToolCall(id: call.id, name: call.name, argumentsJSON: json)
    }

    /// The settings the call runs with: the models chosen here.
    func apply(to settings: ChatSettings) -> ChatSettings {
        var s = settings
        switch kind {
        case .image: s.imageGenModel = imageModel
        case .edit: s.imageEditModel = editModel
        case .music: s.musicModel = musicModel
        }
        return s
    }

    /// The chosen model, for the media's source.
    var modelID: String? {
        switch kind {
        case .image: return imageModel.rawValue
        case .edit: return editModel?.rawValue
        case .music: return musicModel.rawValue
        }
    }

    /// `settings` with the model a source recorded (`MediaSource.model`) for
    /// this call, when there is one and it still exists.
    static func pinning(_ model: String?, for call: ToolCall, _ settings: ChatSettings) -> ChatSettings {
        guard let model else { return settings }
        var s = settings
        switch call.name {
        case ImageToolRunner.toolName:
            if let m = ImageGenModel(rawValue: model) { s.imageGenModel = m }
        case EditImageTool.toolName:
            if let m = ImageGenModel(rawValue: model), m.supportsEditing, s.imageEditModel != nil { s.imageEditModel = m }
        case MusicToolRunner.toolName:
            if let m = MusicModel(rawValue: model) { s.musicModel = m }
        default:
            break
        }
        return s
    }

    static func kind(of call: ToolCall, _ settings: ChatSettings) -> Kind? {
        switch call.name {
        case ImageToolRunner.toolName: return .image
        case EditImageTool.toolName: return settings.imageEditModel == nil ? nil : .edit
        case MusicToolRunner.toolName: return .music
        default: return nil
        }
    }
}

/// The draft in the chat: what's about to be made, editable, with the
/// countdown; any change holds it until "Generate".
struct GenerationDraftView: View {
    @ObservedObject var draft: GenerationDraft

    private var title: LocalizedStringKey {
        switch draft.kind {
        case .image: return "Image"
        case .edit: return "Image edit"
        case .music: return "Music"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: draft.kind == .music ? "music.note" : "photo")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            TextEditor(text: held($draft.prompt))
                .font(.system(size: 12))
                .frame(minHeight: 44, maxHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            switch draft.kind {
            case .image:
                HStack {
                    Picker("Model", selection: held($draft.imageModel)) {
                        ForEach(ImageGenModel.selectable.filter { $0.isDownloaded || $0 == draft.imageModel }) { Text($0.displayName).tag($0) }
                    }
                    Picker("Shape", selection: held($draft.aspect)) {
                        ForEach(GenerationDraft.Aspect.allCases) { Text(verbatim: $0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
            case .edit:
                Picker("Model", selection: held($draft.editModel)) {
                    ForEach(ImageGenModel.allCases.filter { $0.supportsEditing && ($0.isDownloaded || $0 == draft.editModel) }) {
                        Text($0.displayName).tag(Optional($0))
                    }
                }
                .fixedSize()
            case .music:
                DisclosureGroup("Lyrics") {
                    TextEditor(text: held($draft.lyrics))
                        .font(.system(size: 11))
                        .frame(minHeight: 60, maxHeight: 140)
                }
                .font(.system(size: 11))
                HStack {
                    Picker("Model", selection: held($draft.musicModel)) {
                        ForEach(MusicManager.selectable.filter { MusicManager.isDownloadedStatic($0) || $0 == draft.musicModel }) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    Stepper(value: held($draft.duration), in: 10...120, step: 10) {
                        Text(String(format: NSLocalizedString("%lld s", comment: "music duration"), draft.duration))
                    }
                    .fixedSize()
                }
                knob("Creativity", held($draft.creativity), enabled: draft.musicModel.hasCreativity)
                knob("Follow the description", held($draft.adherence), enabled: true)
            }
            HStack {
                if let left = draft.remaining {
                    ProgressView(value: left, total: draft.countdownTotal).frame(width: 60).opacity(0.6)
                    Text(String(format: NSLocalizedString("Starting in %.0f s…", comment: "creator mode countdown"), left.rounded(.up)))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Button("Skip") { draft.resolve(.skip) }
                Button("Generate") { draft.resolve(.run) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: 560, alignment: .leading)
    }

    /// Editing anything stops the countdown.
    private func held<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; draft.hold() })
    }

    private func knob(_ label: LocalizedStringKey, _ value: Binding<Double>, enabled: Bool) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).frame(width: 150, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text(String(format: "%.2f", value.wrappedValue)).font(.system(size: 10).monospacedDigit()).frame(width: 32)
        }
        .disabled(!enabled)
        .help(enabled ? Text(label) : Text("Only turbo has this knob: sft has no song planner to vary."))
    }
}
