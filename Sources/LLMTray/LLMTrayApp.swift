import SwiftUI
import LLMTrayCore
import AppKit
import Combine
#if !APP_STORE
import Sparkle
#endif

@main
struct LLMTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // stdout is fully buffered (not line-buffered) once it's redirected
        // to a file/pipe instead of a terminal -- debug print() tracing
        // otherwise sits in that buffer and never shows up until the
        // process exits, which looks exactly like "nothing happened."
        setvbuf(stdout, nil, _IONBF, 0)
        // Before anything creates the data folder: whether this is a first
        // run decides the usage-statistics default (adr/0015).
        TelemetryDefault.settle(defaults: .standard,
                                dataFolderExists: FileManager.default.fileExists(atPath: RuntimePaths.externalRuntimeDir))
        // `LLMTray --extract <path> [--caps <json>]`: the document extractor
        // child (ExtractorCLI) -- first, before anything opens a connection
        // or touches settings.
        if CommandLine.arguments.contains("--extract") {
            ExtractorCLI.run(arguments: CommandLine.arguments)
        }
        // Developer entry point: `LLMTray --run-tool <name> '<json args>'`
        // runs one chat tool, prints its result and exits -- for checking
        // the tools against the live services without a model.
        if let i = CommandLine.arguments.firstIndex(of: "--dump-tool-definitions") {
            ToolRunnerCLI.dumpDefinitions(defaultToolsOnly: CommandLine.arguments.dropFirst(i + 1).first == "default")
        }
        // `--check-tool-call <name> '<json>'`: how the app reads a call
        // (repairs, or the error the model would get), without running it.
        if let i = CommandLine.arguments.firstIndex(of: "--check-tool-call"), CommandLine.arguments.count > i + 1 {
            ToolRunnerCLI.check(name: CommandLine.arguments[i + 1],
                                json: CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : "{}")
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
                Button("What's New…") { NotificationCenter.default.post(name: .showWhatsNew, object: nil) }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { NotificationCenter.default.post(name: .showSettings, object: nil) }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .help) {
                Button("Report a Bug…") { NotificationCenter.default.post(name: .showBugReport, object: nil) }
            }
            // No File menu (the only scene is Settings), so no Close ⌘W:
            // the chat window, Settings and the logs close with it here. A
            // menu shortcut, unlike a key-down check, also matches with Caps
            // Lock on and on non-Latin layouts. Only titled windows: the
            // popover's own window isn't one.
            CommandGroup(before: .windowSize) {
                Button("New Chat") { ChatTabs.shared.newChat() }
                    .keyboardShortcut("n")
                Button("New Temporary Chat") { ChatTabs.shared.newTemporaryChat() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Tab") { ChatTabs.shared.newTab() }
                    .keyboardShortcut("t")
                // In the chat window it closes the tab on screen; the window
                // goes with its last one.
                Button("Close") {
                    guard let window = NSApp.keyWindow, window.styleMask.contains(.closable) else { return }
                    let tabs = ChatTabs.shared
                    if window.identifier == ChatWindowController.identifier, tabs.tabs.count > 1 {
                        tabs.close(tabs.selectedIndex)
                    } else {
                        window.performClose(nil)
                    }
                }
                .keyboardShortcut("w")
                Button("Show Next Tab") { ChatTabs.shared.selectNext(1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Show Previous Tab") { ChatTabs.shared.selectNext(-1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Menu("Select Tab") {
                    ForEach(1...9, id: \.self) { n in
                        Button("Tab \(n)") { ChatTabs.shared.select(n - 1) }
                            .keyboardShortcut(KeyEquivalent(Character("\(n)")))
                    }
                }
                Divider()
            }
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
    private let tabs = ChatTabs.shared
    private let systemMonitor = SystemMonitor()
    private let hfBrowser = HFModelBrowser()
    // Shared by the popover and the Settings window (both show auto-tune /
    // runtime state, and "auto-tune is running" must lock both).
    private let runtime = RuntimeManager()
    private let benchmark = BenchmarkRunner()
    /// The wizard's downloads (adr/0013), shown in the popover.
    private lazy var downloadQueue = DownloadQueue(browser: hfBrowser)
    private let setupWizard = SetupWizardWindowController()
    #if !APP_STORE
    /// `llmtray`'s socket (adr/0019): up from launch to quit.
    private lazy var controlCommands = ControlCommands(
        server: server, downloads: downloadQueue, benchmark: benchmark,
        startSelectedModel: { [weak self] in await self?.attemptStart(retriesLeft: 1) }
    )
    private lazy var controlServer = ControlSocketServer(path: ControlCommands.socketPath) { [weak self] command, reply in
        await self?.controlCommands.handle(command, reply: reply)
    }
    #endif
    private lazy var settingsWindow = SettingsWindowController(.init(
        server: server, chat: tabs.imageModels, runtime: runtime, benchmark: benchmark,
        checkForAppUpdates: { [weak self] in self?.checkForAppUpdates() }
    ))
    #if APP_STORE
    /// The App Store updates this build: its page is where a newer one is.
    private func checkForAppUpdates() {
        NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
    }
    #else
    private func checkForAppUpdates() { updaterController.checkForUpdates(nil) }
    #endif
    // startingUpdater begins Sparkle's own automatic background check
    // schedule immediately (governed by SUEnableAutomaticChecks in
    // Info.plist) -- separate from the manual "Check for Updates…" menu
    // item below, which just calls checkForUpdates() on demand. Gated on
    // actually having a real Info.plist (SUFeedURL etc.) so this doesn't
    // also try (and fail) to start against the bare `.build/debug/LLMTray`
    // binary used for local dev iteration, which has none.
    #if !APP_STORE
    private let updateChannels = UpdateChannelDelegate()
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
        updaterDelegate: updateChannels, userDriverDelegate: nil
    )
    #endif

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private lazy var chatPresentation = ChatPresentation(tabs: tabs, server: server)
    private lazy var chatWindow = ChatWindowController { [weak self] in self?.attachChat() }
    private var logWindow: NSWindow?
    private var hfWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var bugReportWindow: NSWindow?
    private lazy var voiceLabWindow = VoiceLabWindowController()
    private var cancellables: Set<AnyCancellable> = []
    private var sigtermSource: DispatchSourceSignal?
    private var pulseTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if APP_STORE
        BundledRuntime.configureEnvironment()
        // Granted folders open again before anything reads them (the
        // models folder, folder grants): runners inherit the access.
        SandboxAccess.restore()
        // Tips bought while the Support window was closed (adr/0017).
        TipJar.shared.start()
        #endif
        #if APP_STORE
        // A relaunch (SettingsPane.relaunch): the old instance is exiting.
        if let i = CommandLine.arguments.firstIndex(of: "--after-pid"), CommandLine.arguments.count > i + 1,
           let pid = pid_t(CommandLine.arguments[i + 1]) {
            let deadline = Date().addingTimeInterval(15)
            while kill(pid, 0) == 0, Date() < deadline { usleep(100_000) }
        }
        #endif
        // One LLMTray at a time (the /Applications copy started at login and
        // another from the DMG would both load a model): hand over and quit.
        // The other build (adr/0018: its own bundle id) counts too -- the
        // port, the models, the memory -- but can't be handed over to.
        if handOverToRunningCopy() { return }
        // Image, music and voice models from the app's old folder join the
        // models folder (a rename on one volume), before anything uses them.
        let moved = MediaModels.moveIntoModelsFolder()
        if !moved.isEmpty { NSLog("LLMTray: moved into the models folder: %@", moved.joined(separator: ", ")) }
        #if !APP_STORE
        // After the single-instance check: the copy that stays owns the socket.
        do { try controlServer.start() } catch {
            NSLog("LLMTray: the command-line tool's socket isn't available: %@", error.localizedDescription)
        }
        #endif
        // Full build: the bundled runtime goes to Application Support now,
        // not on the first Start -- an update installed before that (the
        // feed carries the thin build) would take it away.
        let server = self.server
        #if !APP_STORE
        Task { try? await MLXRuntimeInstaller.copyOutBundledRuntime(pinnedRef: nil, log: { server.appendLog($0) }) }
        _ = updaterController  // lazy: created (and its background checks started) at launch
        // Sparkle's automatic checks are periodic (about once a day), not per
        // launch. This quiet background check runs at every launch unless
        // turned off; it only shows UI when an update actually exists.
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
           UserDefaults.standard[Pref.checkUpdatesAtLaunch] {
            updaterController.updater.checkForUpdatesInBackground()
        }
        #endif
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
            self, selector: #selector(showBugReport), name: .showBugReport, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(showReview), name: .showReview, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(showSupport), name: .showSupport, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(showSetupWizard), name: .showSetupWizard, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(showWhatsNew), name: .showWhatsNew, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(showVoiceLab), name: .showVoiceLab, object: nil
        )
        // Voice Lab (adr/0016) unloads and reloads the chat model.
        VoiceLabSession.shared.attach(server: server)
        // The wizard's chat model starts the server once it's in place.
        downloadQueue.onFinished = { [weak self] in self?.downloadFinished($0) }
        ReviewPrompter.shared.recordLaunch()
        // Project files (adr/0012): nothing unless turned on in Settings.
        ProjectIndexer.shared.start(server: server)
        // Folder access (adr/0014): interrupted plans put right, when it's on.
        FolderAccessManager.shared.start()
        UsageTelemetry.shared.start()   // nothing unless the user opted in
        NotificationCenter.default.addObserver(
            self, selector: #selector(showSettingsFromNotification(_:)), name: .showSettings, object: nil
        )
        // The `Settings { EmptyView() }` scene below exists only because
        // SwiftUI's App protocol requires *some* Scene -- but macOS can
        // still materialize it as a real, visible, empty settings window
        // (window-state restoration, e.g. after the relaunch a language
        // change asks for, or at launch on its own). Wherever it turns up
        // it's closed. Matched by
        // SwiftUI's identifier for that window, not its title: the title is
        // localized ("LLMTray Settings" matched English only), and closing
        // every NSApp.windows entry previously took down the popover's own
        // not-yet-shown internal window, leaving the status item
        // non-interactive for the rest of the run.
        // Key, or just shown: in an accessory app it's shown without
        // becoming key, and didUpdate is the only public notification then.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(replaceSettingsScene), name: name, object: nil)
        }
        DispatchQueue.main.async { [self] in
            closeSettingsScene()
            let pane = UserDefaults.standard[Pref.settingsPaneAfterRelaunch].flatMap(SettingsPane.init(rawValue:))
            UserDefaults.standard[Pref.settingsPaneAfterRelaunch] = nil
            if let pane { settingsWindow.show(pane: pane) }
        }

        // A fresh install (adr/0013): the setup wizard, before the
        // auto-start below (which has no model to start then).
        let defaults = UserDefaults.standard
        let firstRun = SetupWizard.opensAutomatically(completedVersion: defaults[Pref.onboardingCompleted],
                                                      selectedModelID: defaults[Pref.selectedModelID],
                                                      saved: SetupWizardModel.loadSaved())
        if firstRun {
            openSetupWizard(automatic: true)
        }
        // A newer minor version: its notes, once (not on a fresh install --
        // the wizard is that -- and not over the wizard: after it closes).
        switch WhatsNew.launchAction(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                                     lastSeen: defaults[Pref.whatsNewLastSeen], freshInstall: firstRun) {
        case .show:
            if setupWizard.isOpen {
                setupWizard.onClose = { [weak self] in
                    self?.setupWizard.onClose = nil
                    WhatsNewWindow.show()
                }
            } else {
                WhatsNewWindow.show()
            }
        case .record(let version):
            defaults[Pref.whatsNewLastSeen] = version
        case .nothing:
            break
        }

        // Starts the server automatically instead of making "click Start
        // Server" the first thing every session requires -- reuses the
        // same quickStart() the right-click menu's "Start Server" item
        // already calls, so this is exactly the last model/settings the
        // user had, not a fresh default. Opt-out, not opt-in (defaults to
        // true if never set) -- this has always been the behavior, so
        // making the key's *absence* mean "off" would silently change it
        // for every existing install the first time this shipped.
        //
        // First, what an earlier LLMTray that crashed or was force-quit
        // left running is stopped (ServerManager.reapOrphans) -- also with
        // auto-start off, and before the new model loads next to the old
        // one's memory.
        Task { @MainActor [weak self] in
            await server.reapOrphans()
            // What the wizard queued and a relaunch interrupted goes on --
            // after the reap: a chat model already in place starts the
            // server at once.
            self?.downloadQueue.resume()
            // Not under a resumed setup wizard (its Apps step changes the
            // port): it starts the chosen model when it's closed.
            if UserDefaults.standard[Pref.autoStartOnLaunch], self?.setupWizard.isOpen != true {
                self?.quickStart()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tabs.saveAll()
        ProjectIndexer.shared.shutdown()
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
        NSHostingController(rootView: AnyView(ChatRoot()
            .environmentObject(server)
            .environmentObject(benchmark)
            .environmentObject(downloadQueue)
            .environmentObject(chatPresentation)))
    }

    /// The popover while the chat has its own window: its header alone.
    private func makeTrayControls() -> NSViewController {
        let hosting = NSHostingController(rootView: AnyView(TrayRoot()
            .environmentObject(server)
            .environmentObject(benchmark)
            .environmentObject(downloadQueue)
            .environmentObject(chatPresentation)))
        hosting.sizingOptions = [.preferredContentSize]
        return hosting
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
        // Found the window: the popover's tip about it has nothing to tell.
        UserDefaults.standard[Pref.chatWindowTipShown] = true
        guard !chatPresentation.isDetached else {
            showChatWindow()
            return
        }
        popover.performClose(nil)
        // The popover's chat view goes away (only one exists at a time):
        // while detached the popover holds the server, model and tool
        // controls, which the chat window leaves out.
        popover.contentViewController = makeTrayControls()
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
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// A short menu for the common case -- the chat, its model and profile,
    /// toggle the server and quit -- without opening the full chat window. Attaching NSStatusItem.menu
    /// makes AppKit handle this one click itself (statusItemClicked never
    /// fires for it), so the menu is detached again right after: leaving it
    /// attached would swallow the *next* left click too and stop the popover
    /// from ever opening via the button's own action.
    private func showQuickMenu() {
        let menu = NSMenu()

        // The chat and its model, without opening the popover first.
        let openItem = NSMenuItem(title: NSLocalizedString("Open Chat", comment: "tray menu"), action: #selector(quickOpenChat), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = [.command, .shift]
        openItem.target = self
        menu.addItem(openItem)
        let newItem = NSMenuItem(title: NSLocalizedString("New Chat", comment: "tray menu"), action: #selector(quickNewChat), keyEquivalent: "n")
        newItem.target = self
        menu.addItem(newItem)
        menu.addItem(modelMenuItem())
        menu.addItem(profileMenuItem())

        menu.addItem(.separator())

        let toggleItem: NSMenuItem
        if isServerRunning {
            toggleItem = NSMenuItem(title: NSLocalizedString("Stop Server", comment: ""), action: #selector(quickStop), keyEquivalent: "")
        } else {
            toggleItem = NSMenuItem(title: NSLocalizedString("Start Server", comment: ""), action: #selector(quickStart), keyEquivalent: "")
        }
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: NSLocalizedString("Settings…", comment: ""), action: #selector(showSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        // Only once it's turned on and its model is here (Settings > Voice).
        if VoiceModelStore.shared.isEnabled, VoiceModelStore.shared.isDownloaded(VoiceModelStore.shared.selected) {
            let voiceItem = NSMenuItem(title: NSLocalizedString("Voice Lab…", comment: ""), action: #selector(showVoiceLab), keyEquivalent: "")
            voiceItem.target = self
            menu.addItem(voiceItem)
        }
        let logItem = NSMenuItem(title: NSLocalizedString("Server Log", comment: ""), action: #selector(showServerLogWindow), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        // What's used now and then goes one level down.
        let help = NSMenu()
        func add(_ title: String, _ action: Selector, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target ?? self
            help.addItem(item)
        }
        add(NSLocalizedString("Set Up LLMTray…", comment: ""), #selector(showSetupWizard))
        add(NSLocalizedString("What's New…", comment: ""), #selector(showWhatsNew))
        // Sparkle needs a real .app bundle's Info.plist (SUFeedURL etc.):
        // the bare `.build/debug/LLMTray` binary has none, and the item
        // would only fail with "updater failed to start".
        #if !APP_STORE
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            add(NSLocalizedString("Check for Updates…", comment: ""), #selector(SPUStandardUpdaterController.checkForUpdates(_:)), target: updaterController)
        }
        #endif
        help.addItem(.separator())
        add(NSLocalizedString("Report a Bug…", comment: ""), #selector(showBugReport))
        add(NSLocalizedString("Rate LLMTray…", comment: ""), #selector(showReview))
        add(NSLocalizedString("Support LLMTray…", comment: ""), #selector(showSupport))
        let helpItem = NSMenuItem(title: NSLocalizedString("Help", comment: "tray menu: submenu"), action: nil, keyEquivalent: "")
        helpItem.submenu = help
        menu.addItem(helpItem)

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

    /// Select Model ▸ -- what the popover's picker lists, the selected one
    /// checked, disabled when the picker is (ModelSelection).
    private func modelMenuItem() -> NSMenuItem {
        let selected = UserDefaults.standard[Pref.selectedModelID]
        let canSwitch = OperationAvailability(server: server, benchmark: benchmark).canSwitchModel
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for model in ModelCatalog.shared.models {
            let item = NSMenuItem(title: model.displayName, action: #selector(quickSelectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.id
            item.state = model.id == selected ? .on : .off
            item.isEnabled = canSwitch
            submenu.addItem(item)
        }
        if submenu.items.isEmpty {
            let none = NSMenuItem(title: NSLocalizedString("No Models", comment: "tray menu: no models downloaded"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        let item = NSMenuItem(title: NSLocalizedString("Select Model", comment: "tray menu: submenu"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Profiles ▸ -- the selected model's, checked; picking one assigns it
    /// as the popover's profile picker does.
    private func profileMenuItem() -> NSMenuItem {
        let profiles = ProfileManager.shared
        let modelID = UserDefaults.standard[Pref.selectedModelID]
        let current = profiles.profileID(for: modelID)
        let canAssign = ModelSelection.canAssignProfile(to: modelID, server: server, benchmark: benchmark)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for profile in profiles.profiles {
            let item = NSMenuItem(title: profile.name, action: #selector(quickAssignProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            item.state = profile.id == current ? .on : .off
            item.isEnabled = canAssign
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: NSLocalizedString("Profiles", comment: "tray menu: submenu"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// The full chat window -- the menu's way of saying LLMTray is more than
    /// its popover (a left click already opens that). Raised if it's open.
    @objc private func quickOpenChat() {
        detachChatSoon()
    }

    /// A new chat, in the chat window.
    @objc private func quickNewChat() {
        tabs.newChat()
        detachChatSoon()
    }

    /// As picking it in the popover: selected, and loaded now while
    /// another model runs (ModelSelection).
    @objc private func quickSelectModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard[Pref.selectedModelID] = id
        guard let model = ModelSelection.modelToLoad(afterPicking: id, server: server, benchmark: benchmark) else { return }
        let server = self.server
        Task { try? await server.switchLoadedModel(to: model.path, alias: ModelCatalog.shared.alias(for: model.id)) }
    }

    @objc private func quickAssignProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ModelSelection.assignProfile(id, to: UserDefaults.standard[Pref.selectedModelID], server: server, benchmark: benchmark)
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

    // MARK: - Setup wizard

    /// From Settings or the menu: from the current settings.
    @objc private func showSetupWizard() {
        openSetupWizard(automatic: false)
    }

    private func openSetupWizard(automatic: Bool) {
        popover.performClose(nil)
        setupWizard.show(automatic: automatic, queue: downloadQueue, server: server) { [weak self] in self?.startSelectedModel() }
    }

    /// The selected model, started -- or, with another one running, loaded
    /// in its place (as picking it in the popover does).
    private func startSelectedModel() {
        switch server.state {
        case .stopped, .failed:
            Task { await attemptStart(retriesLeft: 1) }
        case .running:
            // As picking it in the popover: not mid-turn or under a benchmark
            // (the header's Load is there after).
            guard let model = ModelSelection.modelToLoad(afterPicking: UserDefaults.standard[Pref.selectedModelID],
                                                         server: server, benchmark: benchmark) else { return }
            let server = self.server
            Task { try? await server.switchLoadedModel(to: model.path, alias: ModelCatalog.shared.alias(for: model.id)) }
        default:
            break
        }
    }

    /// The chat model the wizard picked is in place: selected, and the
    /// server started with it (the usual start path). Cancelled: it won't
    /// come; failed: a retry may still bring it.
    private func downloadFinished(_ item: DownloadQueueState.Item) {
        let defaults = UserDefaults.standard
        guard item.kind == .chatModel, item.target == defaults[Pref.onboardingStartServerFor] else { return }
        if item.status == .cancelled {
            defaults[Pref.onboardingStartServerFor] = nil
            return
        }
        // Not under the open wizard (its Apps step changes the port): it
        // starts the model when it's closed or finished.
        guard !setupWizard.isOpen else { return }
        switch item.status {
        case .done:
            defaults[Pref.onboardingStartServerFor] = nil
            ModelCatalog.shared.rescan()
            let path = ModelCatalog.shared.root + "/" + item.target
            guard ModelCatalog.shared.model(id: path) != nil else { return }
            defaults[Pref.selectedModelID] = path
            startSelectedModel()
        case .cancelled:
            defaults[Pref.onboardingStartServerFor] = nil
        default:
            break
        }
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

    /// A fresh form each time it's opened.
    @objc private func showBugReport() {
        if bugReportWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("Report a Bug", comment: "")
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.center()
            bugReportWindow = window
        }
        if bugReportWindow?.isVisible != true {
            bugReportWindow?.contentView = NSHostingView(rootView: BugReportView().environmentObject(server))
        }
        popover.performClose(nil)
        bugReportWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showWhatsNew() {
        popover.performClose(nil)
        WhatsNewWindow.show()
    }

    @objc private func showVoiceLab() {
        popover.performClose(nil)
        voiceLabWindow.show()
    }

    /// Also after a review was sent: another one is welcome.
    @objc private func showReview() {
        popover.performClose(nil)
        ReviewWindow.show()
    }

    @objc private func showSupport() {
        popover.performClose(nil)
        SupportWindow.show()
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

    /// Closes the empty SwiftUI Settings scene window if it's there; true
    /// when it was visible.
    @discardableResult
    private func closeSettingsScene() -> Bool {
        let scene = NSApp.windows.filter { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }
        let visible = scene.contains { $0.isVisible }
        scene.forEach {
            $0.isRestorable = false
            $0.close()
        }
        return visible
    }

    @objc private func replaceSettingsScene(_ note: Notification) {
        guard let window = note.object as? NSWindow, window.isVisible,
              window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" else { return }
        // After the notification: closing a window inside its own
        // didBecomeKey is asking for trouble.
        // Just closed: SwiftUI puts it up at launch on its own (Settings
        // opened every launch when it was replaced by the real one), and
        // the app menu's Settings… opens the real one directly.
        DispatchQueue.main.async { [self] in closeSettingsScene() }
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
        // combineLatest tops out at 4 publishers per call -- isGeneratingMedia
        // is folded in via a second, nested combineLatest instead of trying
        // to cram a 5th into one. Without it, the icon stopped pulsing
        // during image generation: the tool-call-carrying response has
        // already finished streaming (isStreaming == false) by the time
        // mflux is actually running, so that phase looked identical to idle.
        server.$state
            .combineLatest(tabs.$isAnyStreaming, systemMonitor.$thermalState, server.$isBusy)
            .combineLatest(tabs.$isAnyGeneratingMedia)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] combined, isGeneratingMedia in
                let (_, isStreaming, _, isBusy) = combined
                guard let self else { return }
                self.statusItem.button?.image = self.coloredStatusImage
                // isStreaming is immediate but only fires for this app's own
                // chat UI; isBusy is a ~1s-latency CPU-poll fallback that
                // also catches an external tool hitting the OpenAI-compatible
                // endpoint directly, which never touches ChatClient at all.
                self.updatePulse(isStreaming: isStreaming || isBusy || isGeneratingMedia)
            }
            .store(in: &cancellables)
        // A project indexing (adr/0012): a small dot on the icon.
        ProjectIndexer.shared.$progress
            .map(ProjectIndexer.isIndexing)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] indexing in
                guard let self else { return }
                self.isIndexingProjects = indexing
                self.statusItem.button?.image = self.coloredStatusImage
            }
            .store(in: &cancellables)
    }

    /// Any project indexing: the icon carries a dot.
    private var isIndexingProjects = false

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
        guard isIndexingProjects else { return image }
        // The dot in the corner, drawn over the symbol (its colors kept).
        let dotted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            let d = max(4, rect.width * 0.28)
            let dot = NSRect(x: rect.maxX - d, y: rect.minY, width: d, height: d)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        dotted.isTemplate = false
        dotted.accessibilityDescription = NSLocalizedString("LLMTray status, indexing project files", comment: "the menu bar icon while a project indexes")
        return dotted
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
        if tabs.isAnyStreaming || server.isBusy || tabs.isAnyGeneratingMedia { return .green }
        return .primary
    }

    private var statusSymbol: String {
        // Image generation unloads the chat model to make room (the server
        // state reads .stopped meanwhile), but LLMTray is busy, not stopped.
        if tabs.isAnyGeneratingMedia { return "brain.head.profile.fill" }
        switch server.state {
        case .running: return "brain.head.profile.fill"
        case .starting: return "brain.head.profile"
        default: return "brain"
        }
    }

    // MARK: - Single instance

    /// True when this copy is quitting for another running LLMTray: the
    /// same build is brought forward; the other build (the App Store one,
    /// or the one from ipsupport.us) is named in an alert, since it can't
    /// take over this one's launch.
    private func handOverToRunningCopy() -> Bool {
        let running = AppIdentity.bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            + NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        let live = running.filter { !$0.isTerminated }
        let conflict = AppIdentity.conflict(
            ownBundleID: Bundle.main.bundleIdentifier, ownPID: ProcessInfo.processInfo.processIdentifier,
            running: live.map { AppIdentity.Running(bundleID: $0.bundleIdentifier, pid: $0.processIdentifier) })
        switch conflict {
        case nil:
            return false
        case .sameBuild(let pid):
            live.first { $0.processIdentifier == pid }?.activate()
        case .otherBuild(let id, _):
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Another LLMTray is running", comment: "single instance alert title")
            alert.informativeText = id == AppIdentity.appStoreBundleID
                ? NSLocalizedString("The App Store version of LLMTray is open. Quit it first (its menu bar icon › Quit), then open this one again: the two would use the same port and load models twice.", comment: "single instance alert: the App Store build runs")
                : NSLocalizedString("The version of LLMTray from ipsupport.us is open. Quit it first (its menu bar icon › Quit), then open this one again: the two would use the same port and load models twice.", comment: "single instance alert: the standalone build runs")
            alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        NSApp.terminate(nil)
        return true
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
        #if !APP_STORE
        controlServer.stop()
        #endif
        VoiceLabSession.shared.terminateNow()
        server.terminateImmediately()
    }
}

/// Opts into Sparkle's "beta" channel when the user enabled beta updates
/// (General settings). Pre-release builds (tags vX.Y.Z-beta.N) are
/// published as a separate appcast item tagged <sparkle:channel>beta, which
/// Sparkle ignores unless this returns it -- stable users never see them.
/// Read on every check, so the toggle takes effect without a restart.
#if !APP_STORE
final class UpdateChannelDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard[Pref.betaUpdates] ? ["beta"] : []
    }
}
#endif
