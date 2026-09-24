import AppKit
import SwiftUI

/// The panes of the Settings window, in toolbar order.
enum SettingsPane: String, CaseIterable {
    case general, models, profiles, server, benchmark, updates

    /// Localized via Localizable.strings (keys are the English titles).
    var title: String {
        switch self {
        case .general: return NSLocalizedString("General", comment: "Settings pane")
        case .models: return NSLocalizedString("Models", comment: "Settings pane")
        case .profiles: return NSLocalizedString("Profiles", comment: "Settings pane")
        case .server: return NSLocalizedString("Server", comment: "Settings pane")
        case .benchmark: return NSLocalizedString("Benchmark", comment: "Settings pane")
        case .updates: return NSLocalizedString("Updates", comment: "Settings pane")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .models: return "square.stack.3d.up"
        case .profiles: return "slider.horizontal.3"
        case .server: return "server.rack"
        case .benchmark: return "speedometer"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }
}

/// Which profile the Profiles pane shows -- set when it's opened via
/// "Edit Profile…" from the popover.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var profileID: String = "default"
}

/// A real preferences window (toolbar tabs, like Safari/Xcode) instead of
/// settings crammed into the chat popover. NSTabViewController rather than
/// a SwiftUI `Settings` scene: in an accessory (no-Dock) app that scene
/// can't be opened reliably on macOS 13 (it needs `openSettings`, 14+).
@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()
    private let navigation = SettingsNavigation()

    struct Dependencies {
        let server: ServerManager
        let chat: ChatClient
        let runtime: RuntimeManager
        let benchmark: BenchmarkRunner
        let checkForAppUpdates: () -> Void
    }

    init(_ deps: Dependencies) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)

        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let root = Self.view(for: pane, deps: deps)
                .environmentObject(deps.server)
                .environmentObject(deps.chat)
                .environmentObject(deps.runtime)
                .environmentObject(deps.benchmark)
                .environmentObject(ProfileManager.shared)
                .environmentObject(navigation)
                .frame(minWidth: 640, minHeight: 460)
            let item = NSTabViewItem(viewController: NSHostingController(rootView: root))
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            item.identifier = pane.rawValue
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.setContentSize(NSSize(width: 720, height: 560))
        window.setFrameAutosaveName("LLMTraySettings")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @ViewBuilder
    private static func view(for pane: SettingsPane, deps: Dependencies) -> some View {
        switch pane {
        case .general: GeneralPane()
        case .models: ModelsPane()
        case .profiles: ProfilesPane()
        case .server: ServerPane()
        case .benchmark: BenchmarkPane()
        case .updates: UpdatesPane(checkForAppUpdates: deps.checkForAppUpdates)
        }
    }

    func show(pane: SettingsPane? = nil, profileID: String? = nil) {
        if let pane, let i = SettingsPane.allCases.firstIndex(of: pane) {
            tabs.selectedTabViewItemIndex = i
        }
        if let profileID { navigation.profileID = profileID }
        ProfileManager.shared.reload()
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    /// userInfo: "pane" (SettingsPane raw value), "profileID" -- both optional.
    static let showSettings = Notification.Name("llmtray.showSettings")
}

// MARK: - Shared building blocks

/// The "?" next to every setting: hover shows what it does.
struct SettingHelp: View {
    let text: LocalizedStringKey

    var body: some View {
        Image(systemName: "questionmark.circle")
            .foregroundStyle(.secondary)
            .imageScale(.small)
            .help(Text(text))
            .accessibilityLabel(Text(text))
    }
}

/// Label + "?" for a Form row.
struct SettingLabel: View {
    let title: LocalizedStringKey
    let help: LocalizedStringKey

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            SettingHelp(text: help)
        }
    }
}

/// "The running server was started with other settings" + Restart.
struct RestartBanner: View {
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var chat: ChatClient
    @ObservedObject private var profiles = ProfileManager.shared
    @AppStorage("llmtray.verboseServerLogging") private var verboseLogging = false

    var body: some View {
        // profiles / verboseLogging are observed so this re-evaluates on
        // every edit; the comparison itself lives in ServerManager.
        let _ = (profiles.profiles, verboseLogging)
        if server.pendingLaunchChange {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Server settings changed -- restart to apply them.")
                Spacer()
                Button("Restart Server") {
                    Task { try? await server.restartToApplyLaunchSettings() }
                }
                .disabled(server.isBusy || chat.isBusy)
                .help(Text(server.isBusy || chat.isBusy
                           ? "Wait for the current request to finish -- a restart would cut it off."
                           : "Restarts the model process with the new settings (a few seconds to reload)."))
            }
            .font(.callout)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
    }
}
