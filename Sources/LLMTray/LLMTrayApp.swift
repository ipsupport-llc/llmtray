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
        // Before any view's @AppStorage or the auto-start path reads them.
        KVSettings.migrateIfNeeded()
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
    private var logWindow: NSWindow?
    private var hfWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var sigtermSource: DispatchSourceSignal?
    private var pulseTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let hosting = NSHostingController(
            rootView: ContentView()
                .environmentObject(server)
                .environmentObject(chat)
                .environmentObject(benchmark)
        )
        // Tracks the SwiftUI content's own intrinsic size instead of a
        // fixed contentSize -- ContentView's chatArea shrinks toward a
        // minimum when the chat is empty and grows (up to its own cap) as
        // messages arrive, and this is what actually lets that resize the
        // popover window instead of leaving it pinned at one fixed height.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        self.popover = popover
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

    /// No `?? models.first` fallback on purpose: this also runs unattended
    /// at every launch (applicationDidFinishLaunching), and silently
    /// substituting "whatever's alphabetically first" for a model that
    /// can't be found is a bad failure mode to have happen with zero
    /// visual feedback -- confirmed live after a Sparkle update, where the
    /// saved selection briefly didn't resolve (selectedModelID and the
    /// models root were both still correctly persisted seconds later, so
    /// this reads as a startup-timing race rather than a lost setting) and
    /// it silently auto-loaded an unrelated 27B model instead of the
    /// intended one. One short retry covers exactly that kind of transient
    /// race; if it still can't find the model after that, surfacing a
    /// clear reason is safer than guessing.
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
    /// Cocoa's automatic "About <App>" menu item for free -- this wires the
    /// same standard system panel up manually via the quick menu instead,
    /// with a credits block for the two links there's currently nowhere
    /// else in the app to put (license, source, and the company site).
    @objc private func showAboutPanel() {
        let credits = NSMutableAttributedString()
        func appendLink(_ title: String, _ url: String) {
            let range = NSRange(location: credits.length, length: title.count)
            credits.append(NSAttributedString(string: title))
            credits.addAttribute(.link, value: url, range: range)
        }
        credits.append(NSAttributedString(string: "Apache License 2.0\n"))
        appendLink("Source on GitHub", "https://github.com/ipsupport-llc/llmtray")
        credits.append(NSAttributedString(string: "\n"))
        appendLink("ipsupport.us", "https://ipsupport.us")
        credits.addAttribute(
            .font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            range: NSRange(location: 0, length: credits.length)
        )
        credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))

        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
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
