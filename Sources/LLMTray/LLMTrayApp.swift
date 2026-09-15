import SwiftUI
import AppKit
import Combine

@main
struct LLMTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // stdout is fully buffered (not line-buffered) once it's redirected
        // to a file/pipe instead of a terminal -- debug print() tracing
        // otherwise sits in that buffer and never shows up until the
        // process exits, which looks exactly like "nothing happened."
        setvbuf(stdout, nil, _IONBF, 0)
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

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var logWindow: NSWindow?
    private var hfWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var sigtermSource: DispatchSourceSignal?
    private var pulseTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }

    func applicationWillTerminate(_ notification: Notification) {
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
            toggleItem = NSMenuItem(title: "Stop Server", action: #selector(quickStop), keyEquivalent: "")
        } else {
            toggleItem = NSMenuItem(title: "Start Server", action: #selector(quickStart), keyEquivalent: "")
        }
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit LLMTray", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quickStart() {
        guard case .stopped = server.state else { return }
        let defaults = UserDefaults.standard
        let models = ModelDiscovery.scanModels(root: ModelDiscovery.currentModelsRoot())
        guard let savedID = defaults.string(forKey: "selectedModelID"),
              let model = models.first(where: { $0.id == savedID }) ?? models.first else { return }

        let port = defaults.object(forKey: "llmtray.port") as? Int ?? 8765
        let kvBits = defaults.object(forKey: "llmtray.kvBits") as? Int ?? 4
        let kvGroupSize = defaults.object(forKey: "llmtray.kvGroupSize") as? Int ?? 64
        let alias = ModelAliasStore.alias(for: model.id)
        server.start(modelPath: model.path, port: port, kvBits: kvBits, kvGroupSize: kvGroupSize, alias: alias)
    }

    @objc private func quickStop() {
        server.stop()
    }

    @objc private func quitApp() {
        // Routes through applicationWillTerminate -> killServerNow, same as
        // the SIGTERM path below.
        NSApp.terminate(nil)
    }

    // MARK: - Server log window

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
        server.$state
            .combineLatest(chat.$isStreaming, systemMonitor.$thermalState, server.$isBusy)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, isStreaming, _, isBusy in
                guard let self else { return }
                self.statusItem.button?.image = self.coloredStatusImage
                // isStreaming is immediate but only fires for this app's own
                // chat UI; isBusy is a ~1s-latency CPU-poll fallback that
                // also catches an external tool hitting the OpenAI-compatible
                // endpoint directly, which never touches ChatClient at all.
                self.updatePulse(isStreaming: isStreaming || isBusy)
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
        if chat.isStreaming || server.isBusy { return .green }
        return .primary
    }

    private var statusSymbol: String {
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
