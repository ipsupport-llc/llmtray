import SwiftUI
import LLMTrayCore
import AppKit
import Combine
import Sparkle

@main
struct LLMTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // stdout is fully buffered (not line-buffered) once it's redirected
        // to a file/pipe instead of a terminal -- debug print() tracing
        // otherwise sits in that buffer and never shows up until the
        // process exits, which looks exactly like "nothing happened."
        setvbuf(stdout, nil, _IONBF, 0)
        // Developer entry point: `LLMTray --run-tool <name> '<json args>'`
        // runs one chat tool, prints its result and exits -- for checking
        // the tools against the live services without a model.
        if CommandLine.arguments.contains("--dump-tool-definitions") {
            ToolRunnerCLI.dumpDefinitions()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--run-tool"), CommandLine.arguments.count > i + 1 {
            ToolRunnerCLI.run(name: CommandLine.arguments[i + 1],
                              json: CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : "{}")
        }
        // Before any view's @AppStorage or the auto-start path reads them.
        KVSettings.migrateIfNeeded()
        Self.keepNetworkCachesOffDisk()
        // A write to a pipe or socket whose reader is gone must fail, not
        // kill the app (SIGPIPE's default).
        signal(SIGPIPE, SIG_IGN)
    }

    /// Nothing the app fetches is cached on disk (chat traffic, tool
    /// queries), and what earlier versions left there -- tool requests in
    /// the shared URL cache, DuckDuckGo / Wikipedia cookies -- is removed.
    private static func keepNetworkCachesOffDisk() {
        URLCache.shared.removeAllCachedResponses()
        URLCache.shared = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 0)
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) }
    }

    // MenuBarExtra only gives one click behavior for both mouse buttons, and
    // there's no public way to tell left- from right-click inside it -- the
    // right-click quick menu needs a raw NSStatusItem, so the whole menu bar
    // presence (icon, popover, quick menu) lives in AppDelegate instead.
    // This scene is required by SwiftUI but renders nothing.
    var body: some Scene {
        Settings {
            EmptyView()
        }
        // The app menu only shows while the chat is detached (the app is
        // .regular then). SwiftUI's defaults don't fit this app: Settings…
        // would open the empty scene above, About the standard panel
        // without the licenses, Help a "help isn't available" alert.
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About LLMTray") { NotificationCenter.default.post(name: .showAbout, object: nil) }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { NotificationCenter.default.post(name: .showSettings, object: nil) }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .help) {}
        }
    }
}

/// Hides the app from the Dock and Cmd+Tab, owns the status bar item, and
/// makes sure the child mlx_lm.server process actually dies with the app on
/// any shutdown path. Marked @MainActor because AppKit always calls
/// NSApplicationDelegate methods (and button/menu actions) on the main
/// thread anyway, and it owns several @MainActor-isolated properties
/// (server, chat, systemMonitor) that would otherwise need bridging at
/// every call site.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let server = ServerManager()
    private let chat = ChatClient()
    private let systemMonitor = SystemMonitor()
    private let hfBrowser = HFModelBrowser()
    // Shared by the popover and the Settings window (both show auto-tune /
    // runtime state, and "auto-tune is running" must lock both).
    private let runtime = RuntimeManager()
    private let benchmark = BenchmarkRunner()
    private lazy var settingsWindow = SettingsWindowController(.init(
        server: server, chat: chat, runtime: runtime, benchmark: benchmark,
        checkForAppUpdates: { [weak self] in self?.updaterController.checkForUpdates(nil) }
    ))
    // startingUpdater begins Sparkle's own automatic background check
    // schedule immediately (governed by SUEnableAutomaticChecks in
    // Info.plist) -- separate from the manual "Check for Updates…" menu
    // item below, which just calls checkForUpdates() on demand. Gated on
    // actually having a real Info.plist (SUFeedURL etc.) so this doesn't
    // also try (and fail) to start against the bare `.build/debug/LLMTray`
    // binary used for local dev iteration, which has none.
    private let updateChannels = UpdateChannelDelegate()
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
        updaterDelegate: updateChannels, userDriverDelegate: nil
    )

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private lazy var chatPresentation = ChatPresentation(chat: chat)
    private lazy var chatWindow = ChatWindowController { [weak self] in self?.attachChat() }
    private var logWindow: NSWindow?
    private var hfWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var sigtermSource: DispatchSourceSignal?
    private var pulseTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One LLMTray at a time (the /Applications copy started at login and
        // another from the DMG would both load a model): hand over and quit.
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0 != .current && !$0.isTerminated }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        // Full build: the bundled runtime goes to Application Support now,
        // not on the first Start -- an update installed before that (the
        // feed carries the thin build) would take it away.
        let server = self.server
        Task { try? await MLXRuntimeInstaller.copyOutBundledRuntime(pinnedRef: nil, log: { server.appendLog($0) }) }
        _ = updaterController  // lazy: created (and its background checks started) at launch
        // Sparkle's automatic checks are periodic (about once a day), not per
        // launch. This quiet background check runs at every launch unless
        // turned off; it only shows UI when an update actually exists.
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
           UserDefaults.standard[Pref.checkUpdatesAtLaunch] {
            updaterController.updater.checkForUpdatesInBackground()
        }
        NSApp.setActivationPolicy(.accessory)
        installSignalHandlers()
        setupStatusItem()
        setupPopover()
        observeStateForIcon()
        NotificationCenter.default.addObserver(
            self, selector: #selector(showServerLogWindow), name: .showServerLog, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(showHFBrowserWindow), name: .showHFBrowser, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(detachChatSoon), name: .detachChat, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(showAboutPanel), name: .showAbout, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(showSettingsFromNotification(_:)), name: .showSettings, object: nil
        )
        // The `Settings { EmptyView() }` scene below exists only because
        // SwiftUI's App protocol requires *some* Scene -- but macOS can
        // still materialize it as a real, visible, empty "LLMTray Settings"
        // window (seen via window-state restoration once anything ever
        // triggered it, e.g. an accidental Cmd+,). Filtering by its exact
        // title (rather than closing every NSApp.windows entry) matters:
        // closing indiscriminately here previously took down the popover's
        // own not-yet-shown internal window along with it, leaving the
        // status item non-interactive for the rest of the run.
        DispatchQueue.main.async {
            NSApp.windows.filter { $0.title == "LLMTray Settings" }.forEach { $0.close() }
        }

        // Starts the server automatically instead of making "click Start
        // Server" the first thing every session requires -- reuses the
        // same quickStart() the right-click menu's "Start Server" item
        // already calls, so this is exactly the last model/settings the
        // user had, not a fresh default. Opt-out, not opt-in (defaults to
        // true if never set) -- this has always been the behavior, so
        // making the key's *absence* mean "off" would silently change it
        // for every existing install the first time this shipped.
        if UserDefaults.standard[Pref.autoStartOnLaunch] {
            quickStart()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        chat.saveNow()
        ProfileManager.shared.flushPendingWrites()
        killServerNow()
    }

    // MARK: - Status item (left click = chat popover, right click = quick menu)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = coloredStatusImage
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        self.popover = popover
        popover.contentViewController = makePopoverChat()
    }

    /// A fresh chat view. The popover and the chat window never share one
    /// (see ChatPresentation); the state that must carry over lives there.
    private func makeChatController() -> NSHostingController<AnyView> {
        NSHostingController(rootView: AnyView(ContentView()
            .environmentObject(server)
            .environmentObject(chat)
            .environmentObject(benchmark)
            .environmentObject(chatPresentation)
            .environmentObject(chatPresentation.composer)))
    }

    private func makePopoverChat() -> NSViewController {
        let hosting = makeChatController()
        // Tracks the SwiftUI content's own intrinsic size instead of a
        // fixed contentSize -- ContentView's chatArea shrinks toward a
        // minimum when the chat is empty and grows (up to its own cap) as
        // messages arrive, and this is what actually lets that resize the
        // popover window instead of leaving it pinned at one fixed height.
        hosting.sizingOptions = [.preferredContentSize]
        return hosting
    }

    // MARK: - Detachable chat window

    /// The header button posts .detachChat synchronously, from inside the
    /// popover's own view: detaching releases that view, so it waits until
    /// the button's action has returned.
    @objc private func detachChatSoon() {
        DispatchQueue.main.async { [weak self] in self?.detachChat() }
    }

    /// Moves the chat out of the popover into its own window.
    private func detachChat() {
        guard !chatPresentation.isDetached else {
            showChatWindow()
            return
        }
        popover.performClose(nil)
        // The popover's chat view goes away (only one exists at a time);
        // NSPopover still wants a content controller, never shown while
        // detached (the status item raises the window instead).
        let placeholder = NSViewController()
        placeholder.view = NSView()
        popover.contentViewController = placeholder
        chatPresentation.isDetached = true
        setDockIconVisible(true)
        let hosting = makeChatController()
        // The user sizes the window, not the content: tracking
        // preferredContentSize (as the popover must) makes an NSWindow snap
        // back to it. ChatWindowController enforces the minimum size.
        hosting.sizingOptions = []
        chatWindow.show(hosting)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The chat window was closed: the chat goes back into the popover.
    private func attachChat() {
        guard chatPresentation.isDetached else { return }
        chatWindow.removeContent()
        chatPresentation.isDetached = false
        popover.contentViewController = makePopoverChat()
        setDockIconVisible(false)
    }

    private func showChatWindow() {
        chatWindow.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Dock icon + Cmd+Tab while the chat has its own window; menu-bar-only
    /// (the app's normal state) otherwise -- even with Settings or the log
    /// still open: closing the chat window is what removes the Dock icon.
    /// (detachChat activates the app right after, which a fresh .regular
    /// app needs before macOS shows its menu bar.)
    private func setDockIconVisible(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }

    /// Clicking the Dock icon (it only exists while detached) raises the chat.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if chatPresentation.isDetached { showChatWindow() }
        return true
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if chatPresentation.isDetached {
            showChatWindow()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// A short menu for the common case -- toggle the server and quit --
    /// without opening the full chat window. Attaching NSStatusItem.menu
    /// makes AppKit handle this one click itself (statusItemClicked never
    /// fires for it), so the menu is detached again right after: leaving it
    /// attached would swallow the *next* left click too and stop the popover
    /// from ever opening via the button's own action.
    private func showQuickMenu() {
        let menu = NSMenu()

        let toggleItem: NSMenuItem
        if isServerRunning {
            toggleItem = NSMenuItem(title: NSLocalizedString("Stop Server", comment: ""), action: #selector(quickStop), keyEquivalent: "")
        } else {
            toggleItem = NSMenuItem(title: NSLocalizedString("Start Server", comment: ""), action: #selector(quickStart), keyEquivalent: "")
        }
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // Sparkle needs a real .app bundle's Info.plist (SUFeedURL etc.) to
        // do anything -- the bare `.build/debug/LLMTray` binary used for
        // local dev iteration has none, so "Check for Updates…" would just
        // fail with a confusing "updater failed to start" dialog (and
        // report the app's name as "debug", the executable's containing
        // folder, since there's no real CFBundleName to read either).
        // Hiding the item entirely there is clearer than showing it and
        // having it error out.
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            let updateItem = NSMenuItem(
                title: NSLocalizedString("Check for Updates…", comment: ""), action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: ""
            )
            updateItem.target = updaterController
            menu.addItem(updateItem)
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(title: NSLocalizedString("Settings…", comment: ""), action: #selector(showSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let logItem = NSMenuItem(title: NSLocalizedString("Server Log", comment: ""), action: #selector(showServerLogWindow), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: NSLocalizedString("About LLMTray", comment: ""), action: #selector(showAboutPanel), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: NSLocalizedString("Quit LLMTray", comment: ""), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quickStart() {
        guard case .stopped = server.state else { return }
        Task { await attemptStart(retriesLeft: 1) }
    }

    /// No fallback to another model when the saved one isn't found: after an
    /// update that once silently loaded an unrelated 27B model (a startup
    /// race). One short retry, then a visible error -- adr/0003.
    private func attemptStart(retriesLeft: Int) async {
        let defaults = UserDefaults.standard
        guard let savedID = defaults[Pref.selectedModelID] else { return }
        // A fresh scan each attempt: the retry exists for a startup race.
        ModelCatalog.shared.rescan()
        guard let model = ModelCatalog.shared.model(id: savedID) else {
            if retriesLeft > 0 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await attemptStart(retriesLeft: retriesLeft - 1)
            } else {
                server.reportFailure("Couldn't find the last-selected model (\((savedID as NSString).lastPathComponent)) -- pick one from the menu.")
            }
            return
        }

        let port = defaults[Pref.port]
        // KV bits, drafter etc. come from the model's profile at launch
        // (ServerManager.launchServerProcess), including the KV-shared
        // model guard auto-start used to skip.
        server.start(modelPath: model.path, port: port, alias: ModelCatalog.shared.alias(for: model.id))
    }

    @objc private func quickStop() {
        server.stop()
    }

    /// LSUIElement apps (no Dock icon, no standard app menu bar) don't get
    /// Cocoa's automatic "About <App>" item: the quick menu opens this
    /// window instead -- the app, its links, and every license that applies
    /// (AboutView).
    @objc private func showAboutPanel() {
        if aboutWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("About LLMTray", comment: "")
            window.isReleasedWhenClosed = false
            window.center()
            aboutWindow = window
        }
        // Fresh each time: it lists what's installed right now.
        if aboutWindow?.isVisible != true {
            aboutWindow?.contentView = NSHostingView(rootView: AboutView())
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        // Routes through applicationWillTerminate -> killServerNow, same as
        // the SIGTERM path below.
        NSApp.terminate(nil)
    }

    // MARK: - Server log window

    // MARK: - Settings window

    @objc private func showSettingsWindow() {
        popover.performClose(nil)
        settingsWindow.show()
    }

    @objc private func showSettingsFromNotification(_ note: Notification) {
        popover.performClose(nil)
        let pane = (note.userInfo?["pane"] as? String).flatMap(SettingsPane.init(rawValue:))
        settingsWindow.show(pane: pane, profileID: note.userInfo?["profileID"] as? String)
    }

    @objc private func showServerLogWindow() {
        if logWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "LLMTray — Server Log"
            // Keep the window instance alive across closes so reopening it
            // is instant and doesn't lose scroll position mid-session.
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ServerLogView(server: server))
            window.center()
            logWindow = window
        }
        logWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - HF model browser window

    @objc private func showHFBrowserWindow() {
        if hfWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "LLMTray — Browse Hugging Face Models"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HFBrowserView(browser: hfBrowser))
            window.center()
            hfWindow = window
        }
        hfWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var isServerRunning: Bool {
        if case .running = server.state { return true }
        return false
    }

    // MARK: - Icon coloring

    /// Plain `Image(systemName:)` inside a MenuBarExtra label always renders
    /// as an AppKit "template" image -- forced monochrome regardless of
    /// SwiftUI color modifiers. Building the NSImage directly and setting
    /// isTemplate = false opts this icon out of that forced tinting so
    /// green/red actually show. That constraint carries over even though
    /// this is now a plain NSStatusItem button rather than MenuBarExtra.
    private func observeStateForIcon() {
        // combineLatest tops out at 4 publishers per call -- isGeneratingImage
        // is folded in via a second, nested combineLatest instead of trying
        // to cram a 5th into one. Without it, the icon stopped pulsing
        // during image generation: the tool-call-carrying response has
        // already finished streaming (isStreaming == false) by the time
        // mflux is actually running, so that phase looked identical to idle.
        server.$state
            .combineLatest(chat.$isStreaming, systemMonitor.$thermalState, server.$isBusy)
            .combineLatest(chat.$isGeneratingImage)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] combined, isGeneratingImage in
                let (_, isStreaming, _, isBusy) = combined
                guard let self else { return }
                self.statusItem.button?.image = self.coloredStatusImage
                // isStreaming is immediate but only fires for this app's own
                // chat UI; isBusy is a ~1s-latency CPU-poll fallback that
                // also catches an external tool hitting the OpenAI-compatible
                // endpoint directly, which never touches ChatClient at all.
                self.updatePulse(isStreaming: isStreaming || isBusy || isGeneratingImage)
            }
            .store(in: &cancellables)
    }

    /// Color alone can't carry both signals once thermal state (orange/red)
    /// outranks "is generating" (green) -- so activity is layered on as a
    /// breathing alpha animation on the button itself, visible under any
    /// color the icon currently has.
    private func updatePulse(isStreaming: Bool) {
        guard isStreaming else {
            pulseTimer?.invalidate()
            pulseTimer = nil
            statusItem.button?.alphaValue = 1.0
            return
        }
        guard pulseTimer == nil else { return }
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // Timer fires on RunLoop.main, so this is guaranteed to be the
            // main thread even though the closure isn't statically
            // MainActor-isolated.
            MainActor.assumeIsolated {
                guard let self, let button = self.statusItem.button else { return }
                let period = 1.2
                let phase = (2 * Double.pi / period) * Date().timeIntervalSince(start)
                button.alphaValue = 0.55 + 0.45 * (0.5 + 0.5 * sin(phase))
            }
        }
        // .common so the pulse keeps animating even while a menu/popover is
        // tracking (default run loop mode pauses during those).
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    private var coloredStatusImage: NSImage {
        let config = NSImage.SymbolConfiguration(paletteColors: [NSColor(statusColor)])
        let base = NSImage(systemSymbolName: statusSymbol, accessibilityDescription: "LLMTray status")
            ?? NSImage()
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = false
        return image
    }

    /// Thermal state still wins on color (a hot/throttling machine is the
    /// more urgent thing to see) -- but green for "generating" is back,
    /// layered under it, so a normal busy state actually reads as green
    /// instead of just a colorless white blink. The breathing alpha from
    /// updatePulse still runs on top regardless of which color wins, so
    /// green pulses rather than sitting flat.
    private var statusColor: Color {
        if systemMonitor.isThrottling { return .red }
        if systemMonitor.isWarm { return .orange }
        if chat.isStreaming || server.isBusy || chat.isGeneratingImage { return .green }
        return .primary
    }

    private var statusSymbol: String {
        // Image generation unloads the chat model to make room (the server
        // state reads .stopped meanwhile), but LLMTray is busy, not stopped.
        if chat.isGeneratingImage { return "brain.head.profile.fill" }
        switch server.state {
        case .running: return "brain.head.profile.fill"
        case .starting: return "brain.head.profile"
        default: return "brain"
        }
    }

    // MARK: - SIGTERM handling

    /// Cmd+Q / the Quit menu item go through NSApp.terminate(_:), which
    /// AppKit turns into applicationWillTerminate above -- but a raw
    /// `kill`/`pkill` (SIGTERM, the default signal both send) does NOT run
    /// any NSApplicationDelegate method; a Cocoa app's default disposition
    /// for SIGTERM is to just die immediately. That's exactly how this app
    /// gets restarted during development, and it's what orphaned the child
    /// mlx_lm.server process (twice, confirmed via `ps` -- each holding a
    /// ~17GB model resident, enough to push the whole machine into swap).
    /// Route SIGTERM through a GCD dispatch source instead of leaving the
    /// default disposition in place, so it also gets a chance to clean up.
    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            // The event handler closure itself isn't statically MainActor-
            // isolated even though the .main queue guarantees it runs on
            // the main thread -- assumeIsolated bridges that gap for this
            // one call site.
            MainActor.assumeIsolated {
                ProfileManager.shared.flushPendingWrites()
                self?.killServerNow()
                exit(0)
            }
        }
        source.resume()
        sigtermSource = source
    }

    private func killServerNow() {
        server.terminateImmediately()
    }
}

/// Opts into Sparkle's "beta" channel when the user enabled beta updates
/// (General settings). Pre-release builds (tags vX.Y.Z-beta.N) are
/// published as a separate appcast item tagged <sparkle:channel>beta, which
/// Sparkle ignores unless this returns it -- stable users never see them.
/// Read on every check, so the toggle takes effect without a restart.
final class UpdateChannelDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard[Pref.betaUpdates] ? ["beta"] : []
    }
}
