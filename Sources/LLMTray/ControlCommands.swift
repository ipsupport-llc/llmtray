#if !APP_STORE
import Combine
import Foundation
import LLMTrayCore

/// What `llmtray`'s commands do (adr/0019 §3): each one the tray's own
/// action, called the same way -- Start is the tray's Start, a model is
/// loaded as picking it does, a download goes through the download queue,
/// an image through the generator queue with the chat model's unload --
/// so nothing here is a second copy of how the app works.
@MainActor
final class ControlCommands {
    private let server: ServerManager
    private let downloads: DownloadQueue
    private let benchmark: BenchmarkRunner
    /// The tray's Start for the selected model (AppDelegate.attemptStart:
    /// no fallback to another model, one retry for a startup race).
    private let startSelectedModel: () async -> Void
    private var catalog: ModelCatalog { .shared }

    /// `<Application Support>/LLMTray/control.sock`, or the environment's
    /// override (a second dev copy beside an installed LLMTray). Served by
    /// LLMTrayCore's ControlSocketServer: owner-only, and the transport is
    /// tested there.
    nonisolated static var socketPath: String {
        ProcessInfo.processInfo.environment[ControlProtocol.socketPathEnvironment].flatMap { $0.isEmpty ? nil : $0 }
            ?? RuntimePaths.externalRuntimeDir + "/" + ControlProtocol.socketFileName
    }

    init(server: ServerManager, downloads: DownloadQueue, benchmark: BenchmarkRunner,
         startSelectedModel: @escaping () async -> Void) {
        self.server = server
        self.downloads = downloads
        self.benchmark = benchmark
        self.startSelectedModel = startSelectedModel
    }

    func handle(_ command: ControlCommand, reply: ControlReplySink) async {
        switch command {
        case .status:
            reply.send(ControlReply(done: true, status: status()))
        case .models:
            reply.send(ControlReply(done: true, models: models()))
        case .start(let model):
            await start(model, reply: reply)
        case .stop:
            server.stop()
            reply.send(ControlReply(done: true, status: status()))
        case .pull(let repo):
            await pull(repo, reply: reply)
        case .image(let request):
            await image(request, reply: reply)
        }
    }

    // MARK: - status, models

    func status() -> ControlStatus {
        let (state, message) = Self.describe(server.state)
        let running: Int? = { if case .running(let port, _) = server.state { return port } else { return nil } }()
        let port = running ?? UserDefaults.standard[Pref.port]
        // Idle-unloaded, the model is still the one the next request gets.
        let loaded = running != nil || server.isIdleUnloaded ? server.loadedModelPath : nil
        let selected = UserDefaults.standard[Pref.selectedModelID].flatMap { catalog.model(id: $0) }
        return ControlStatus(
            state: state, message: message,
            model: loaded.map { catalog.requestName(for: $0) }, modelPath: loaded,
            selectedModel: selected.map { catalog.requestName(for: $0.id) },
            port: port, idleUnloaded: server.isIdleUnloaded,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            baseURL: ControlStatus.baseURL(port: port),
            // Only this user's processes reach the socket (adr/0019 §3).
            appTokenHeader: AppRequestToken.header, appToken: AppRequestToken.value
        )
    }

    private func models() -> [ControlModel] {
        // The catalog as the popover shows it -- no rescan here: each one
        // restarts the background size measurement, and a script polling
        // `models` would keep the sizes from ever arriving.
        let selected = UserDefaults.standard[Pref.selectedModelID]
        let loaded: String? = {
            if case .running = server.state { return server.loadedModelPath }
            return server.isIdleUnloaded ? server.loadedModelPath : nil
        }()
        return catalog.models.map {
            ControlModel(path: $0.path, name: catalog.requestName(for: $0.id), displayName: $0.displayName,
                         sizeBytes: catalog.sizes[$0.id], selected: $0.id == selected, loaded: $0.path == loaded)
        }
    }

    private static func describe(_ state: ServerState) -> (String, String?) {
        switch state {
        case .stopped: return (ControlStatus.stopped, nil)
        case .starting: return (ControlStatus.starting, nil)
        case .running: return (ControlStatus.running, nil)
        case .failed(let message): return (ControlStatus.failed, message)
        }
    }

    // MARK: - start

    private func start(_ name: String?, reply: ControlReplySink) async {
        let target: String
        if let name {
            // As the proxy resolves a request's `model`: alias, folder or
            // display name, or a path inside the models folder.
            guard let path = catalog.resolve(modelName: name) else {
                let known = catalog.servedNames
                return reply.send(.failure("no model \"\(name)\" in LLMTray's models folder -- available: "
                                           + (known.isEmpty ? "none (llmtray pull <org/name> downloads one)" : known.joined(separator: ", "))))
            }
            target = path
        } else {
            guard let id = UserDefaults.standard[Pref.selectedModelID], catalog.model(id: id) != nil else {
                return reply.send(.failure("no model is selected -- name one (llmtray start <model>; llmtray models lists them)"))
            }
            target = id
        }
        // The selected model from now on, as picking it in the popover makes
        // it -- once it's being started, not when the start is refused.
        func select() { UserDefaults.standard[Pref.selectedModelID] = target }

        var sent: ServerState?
        // Every state change is an event line, the current state first.
        let watch = server.$state.receive(on: DispatchQueue.main).sink { state in
            guard state != sent else { return }
            sent = state
            let (name, message) = Self.describe(state)
            reply.send(ControlReply(event: ControlReply.Event.state, state: name, message: message))
        }
        defer { watch.cancel() }

        while !reply.isClosed {
            let plan = ControlStartPlan.decide(OperationAvailability(server: server, benchmark: benchmark),
                                               suspendedForMedia: server.suspendedForImageGeneration,
                                               loaded: server.loadedModelPath, target: target)
            switch plan {
            case .alreadyRunning:
                select()
                return reply.send(ControlReply(done: true, status: status()))
            case .refuse(let why):
                return reply.send(.failure(why))
            case .wait:
                // Starting already (the launch's auto-start, the chat's
                // send): its outcome first, then this model if it's another.
                await waitWhileStarting(reply)
                switch server.state {
                // Stopped meanwhile (Stop in the menu bar): not started again.
                case .stopped where !server.isIdleUnloaded: return reply.send(.failure("the server was stopped"))
                // Failed too: that was another start's outcome -- this
                // one is decided again (a failed server is started).
                default: continue
                }
            case .start:
                select()
                await startSelectedModel()
                await waitWhileStarting(reply)
                return finishStart(target, reply: reply)
            case .load:
                select()
                do {
                    try await server.switchLoadedModel(to: target, alias: catalog.alias(for: target))
                } catch {
                    return reply.send(.failure(error.localizedDescription))
                }
                return finishStart(target, reply: reply)
            }
        }
    }

    private func waitWhileStarting(_ reply: ControlReplySink) async {
        while server.isStarting, !reply.isClosed {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func finishStart(_ target: String, reply: ControlReplySink) {
        switch server.state {
        case .running where server.loadedModelPath == target:
            reply.send(ControlReply(done: true, status: status()))
        case .running:
            // A client or the chat asked for another one meanwhile.
            let loaded = server.loadedModelPath.map { catalog.requestName(for: $0) } ?? "another model"
            reply.send(.failure("\(loaded) was loaded instead, by another request"))
        case .failed(let message):
            reply.send(.failure(message))
        case .starting:
            break   // the client left while it loads: it goes on
        default:
            reply.send(.failure("the server stopped before the model was loaded"))
        }
    }

    // MARK: - pull

    private func pull(_ repo: String, reply: ControlReplySink) async {
        guard HubRepoName.isValid(repo) else {
            return reply.send(.failure("\"\(repo)\" isn't a Hugging Face repo -- expected org/name"))
        }
        let before = Set(downloads.state.items.map(\.id))
        downloads.addChatModel(repo: repo)
        // The new item, or the same download already waiting or running
        // (the queue doesn't take it twice).
        let mine = downloads.state.items.first { !before.contains($0.id) && $0.kind == .chatModel && $0.target == repo }
            ?? downloads.state.items.first { $0.kind == .chatModel && $0.target == repo && !$0.status.isFinished }
        guard let id = mine?.id else {
            return reply.send(.failure("the download couldn't be queued"))
        }
        var lastProgress: Double?
        var lastDetail: String?
        var announcedWait = false
        while !reply.isClosed {
            guard let item = downloads.state.item(id) else {
                return reply.send(.failure("the download was removed from LLMTray's queue"))
            }
            switch item.status {
            case .pending:
                if !announcedWait {
                    announcedWait = true
                    reply.send(ControlReply(event: ControlReply.Event.queued, message: "waiting for the downloads ahead of it"))
                }
            case .running(let progress):
                let detail = downloads.detail
                if detail != lastDetail || Self.moved(lastProgress, progress) {
                    lastDetail = detail
                    lastProgress = progress
                    reply.send(ControlReply(event: ControlReply.Event.progress, message: detail.isEmpty ? nil : detail, progress: progress))
                }
            case .done:
                let path = catalog.root + "/" + repo
                return reply.send(ControlReply(done: true, message: "downloaded \(repo)", path: path))
            case .failed(let message):
                return reply.send(.failure(message))
            case .cancelled:
                return reply.send(.failure("the download was cancelled"))
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        // The client left (Ctrl-C): the download goes on in the queue.
    }

    /// Progress worth a line: a tenth of a percent, or known for the first time.
    private static func moved(_ old: Double?, _ new: Double?) -> Bool {
        switch (old, new) {
        case (nil, nil): return false
        case let (old?, new?): return abs(new - old) >= 0.001
        default: return true
        }
    }

    // MARK: - image

    private func image(_ request: ControlCommand.ImageRequest, reply: ControlReplySink) async {
        // The selected model's profile, as the chat's turn would use it.
        let settings = ChatSettings.forModel(UserDefaults.standard[Pref.selectedModelID], supportsVision: false)
        let model: ImageGenModel
        if let name = request.model {
            guard let named = ImageGenModel.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
                return reply.send(.failure("no image model \"\(name)\" -- known: " + ImageGenModel.allCases.map(\.rawValue).joined(separator: ", ")))
            }
            model = named
        } else {
            model = settings.imageGenModel
        }
        let tabs = ChatTabs.shared
        // Never downloaded from here: features are turned on in Settings.
        guard tabs.mflux.isReady(model) else {
            return reply.send(.failure("image generation isn't set up for \(model.rawValue) (\(model.displayName)) -- "
                                       + "download it in LLMTray › Settings › Image generation"))
        }
        let prompt = String(request.prompt.prefix(4000))
        // The chat tool's default canvas, scaled by the quality setting; an
        // explicit size as given (mflux rounds it to 16 px, 256...2048).
        let side = Int(1024 * settings.imageQuality.scale)
        let width = request.width ?? side
        let height = request.height ?? side

        // Its turn in the app-wide queue, after any chat's image or song.
        let ticket: GenerationQueue.Ticket
        do {
            ticket = try await GenerationQueue.shared.acquire(
                isCancelled: { reply.isClosed },
                onPosition: { position in
                    guard let position else { return }
                    reply.send(ControlReply(event: ControlReply.Event.queued, position: position))
                }
            )
        } catch {
            return   // the client left while it waited
        }
        // A Settings download holds the generator too.
        while tabs.mflux.isBusy || tabs.music.isBusy, !reply.isClosed {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !reply.isClosed else { return ticket.release() }

        // As a chat's turn: the diffusion model's peak memory can rival the
        // chat model's, so it's unloaded first unless the profile says the
        // Mac fits both -- and only a model that's up comes back after.
        let unload = settings.unloadModelDuringImageGen && server.canAnswer
        if unload {
            // Announced before the unload: the chats' answers wait from now.
            tabs.isControlUnloadingModel = true
            reply.send(ControlReply(event: ControlReply.Event.progress, message: "unloading the chat model"))
            await server.unloadModel()
        }
        let steps = tabs.mflux.$stepProgress.receive(on: DispatchQueue.main).sink { progress in
            guard let progress, progress.total > 0 else { return }
            reply.send(ControlReply(event: ControlReply.Event.progress, message: "step \(progress.step) of \(progress.total)",
                                    progress: Double(progress.step) / Double(progress.total)))
        }
        let started = Date()
        let result: Result<Data, Error>
        do {
            result = .success(try await tabs.mflux.generate(prompt: prompt, width: width, height: height, model: model))
        } catch {
            result = .failure(error)
        }
        steps.cancel()
        var note = ""
        if unload {
            do { try await server.ensureModelLoaded() } catch {
                note = " -- the chat model couldn't be reloaded: \(error.localizedDescription)"
            }
            tabs.isControlUnloadingModel = false
        }
        // After the reload: the next in line starts from a loaded model, as
        // it expects (ChatClient's order).
        ticket.release()
        switch result {
        case .success(let png):
            reply.send(ControlReply(done: true, message: String(format: "%@, %.0f s", model.rawValue, Date().timeIntervalSince(started)) + note,
                                    image: png.base64EncodedString()))
        case .failure(let error):
            reply.send(.failure(error.localizedDescription + note))
        }
    }
}
#endif
