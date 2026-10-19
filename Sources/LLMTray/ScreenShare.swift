import AppKit
import LLMTrayCore
import ScreenCaptureKit
import Vision

extension Notification.Name {
    /// A window or screen pick starts: the chat steps aside (adr/0030).
    static let sharingWillPick = Notification.Name("LLMTray.sharingWillPick")
    /// It's over (picked or cancelled): the chat comes back.
    static let sharingDidPick = Notification.Name("LLMTray.sharingDidPick")
}

/// What a chat can be shown (adr/0030): a window or the screen through the
/// system's content-sharing picker -- one still, on the user's click --
/// and, outside the App Store build, the front tab of a browser.
@MainActor
final class ScreenShare: NSObject {
    static let shared = ScreenShare()

    /// A capture: the image, and what it was.
    struct Capture {
        let image: CGImage
        let context: SharedContext
    }

    private var pending: CheckedContinuation<SCContentFilter?, Never>?
    /// The apps in front before LLMTray, latest last (bundle ids): the
    /// browser whose tab "Attach Current Tab" means. Identity only.
    private var recentApps: [String] = []
    private var watching = false

    /// Starts noting which app is in front (bundle id only).
    func startWatchingApps() {
        guard !watching else { return }
        watching = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { ScreenShare.shared.noteActive(id) }
        }
        noteActive(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func noteActive(_ id: String?) {
        guard let id, id != Bundle.main.bundleIdentifier else { return }
        recentApps.removeAll { $0 == id }
        recentApps.append(id)
        if recentApps.count > 20 { recentApps.removeFirst() }
    }

    // MARK: Windows and the screen

    /// The system picker for one window (or one display), then one still
    /// of it. nil: cancelled, or it couldn't be captured.
    func capture(screen: Bool) async -> Capture? {
        NotificationCenter.default.post(name: .sharingWillPick, object: nil)
        defer { NotificationCenter.default.post(name: .sharingDidPick, object: nil) }
        guard let filter = await pick(screen: screen) else { return nil }
        let config = SCStreamConfiguration()
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(rect.width * scale))
        config.height = max(1, Int(rect.height * scale))
        config.showsCursor = false
        config.capturesAudio = false
        let box = FilterBox(filter)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: box.filter, configuration: config) else {
            return nil
        }
        return Capture(image: image, context: describe(filter, screen: screen))
    }

    private func pick(screen: Bool) async -> SCContentFilter? {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = screen ? .singleDisplay : .singleWindow
        config.allowsChangingSelectedContent = false
        if let id = Bundle.main.bundleIdentifier { config.excludedBundleIDs = [id] }
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        let filter = await withCheckedContinuation { continuation in
            pending?.resume(returning: nil)
            pending = continuation
            picker.present(using: screen ? .display : .window)
        }
        picker.remove(self)
        picker.isActive = false
        return filter
    }

    fileprivate func finish(_ filter: SCContentFilter?) {
        pending?.resume(returning: filter)
        pending = nil
    }

    /// What was picked, in words: the window's app and title where macOS
    /// says (15.2 on), else just "a window".
    private func describe(_ filter: SCContentFilter, screen: Bool) -> SharedContext {
        if screen { return SharedContext(kind: .screen, title: "", source: "") }
        if #available(macOS 15.2, *), let window = filter.includedWindows.first {
            return SharedContext(kind: .window, title: window.title ?? "",
                                 source: window.owningApplication?.applicationName ?? "")
        }
        return SharedContext(kind: .window, title: "", source: "")
    }

    /// The text in a capture, for a model that doesn't see: recognized on
    /// this Mac (Vision), in reading order.
    nonisolated static func recognizeText(_ image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                try? VNImageRequestHandler(cgImage: image).perform([request])
                let pieces = (request.results ?? []).compactMap { o -> ReadingOrder.Piece? in
                    guard let text = o.topCandidates(1).first?.string else { return nil }
                    let b = o.boundingBox
                    return ReadingOrder.Piece(text: text, x: b.minX, y: b.minY, width: b.width, height: b.height)
                }
                continuation.resume(returning: ReadingOrder.lines(pieces))
            }
        }
    }

    // MARK: Browser tabs

    #if !APP_STORE
    /// The browser "Attach Current Tab" reads: the latest one in front, of
    /// those still running.
    var currentBrowser: BrowserTab.Browser? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return recentApps.reversed().lazy.filter(running.contains).compactMap(BrowserTab.browser(bundleID:)).first
            ?? BrowserTab.browsers.first { running.contains($0.bundleID) }
    }

    enum TabError: Error {
        /// No browser window, or no answer.
        case noTab
        /// Automation for that browser was turned down (System Settings ›
        /// Privacy & Security › Automation).
        case notAllowed
    }

    /// The front tab of `browser`: title, address and text -- title and
    /// address only when a Chromium browser runs no scripts from Apple
    /// Events (`titleOnly` set then).
    func readTab(_ browser: BrowserTab.Browser) async -> Result<SharedContext, TabError> {
        let first = await Self.run(BrowserTab.script(for: browser))
        switch first {
        case .success(let answer):
            if let tab = BrowserTab.parse(answer, titleOnly: false) { return .success(tab) }
            return .failure(.noTab)
        case .failure(let error) where error.code == -1743 || error.code == -1744:
            return .failure(.notAllowed)
        case .failure:
            guard browser.family == .chromium,
                  case .success(let answer) = await Self.run(BrowserTab.script(for: browser, titleOnly: true)),
                  let tab = BrowserTab.parse(answer, titleOnly: true) else { return .failure(.noTab) }
            return .success(tab)
        }
    }

    /// Runs `source` off the main thread (the browser may take a while,
    /// and macOS's Automation prompt waits for the user). The error number
    /// when it fails.
    private nonisolated static func run(_ source: String) async -> Result<String, ScriptError> {
        await withCheckedContinuation { continuation in
            scriptQueue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let result, error == nil {
                    continuation.resume(returning: .success(result.stringValue ?? ""))
                } else {
                    continuation.resume(returning: .failure(ScriptError(code: (error?[NSAppleScript.errorNumber] as? Int) ?? -1)))
                }
            }
        }
    }

    struct ScriptError: Error { let code: Int }

    private nonisolated static let scriptQueue = DispatchQueue(label: "LLMTray.browserTab")
    #endif
}

/// The picked filter, handed from the picker's callback to the main actor
/// and on to the capture; nothing else holds it.
private struct FilterBox: @unchecked Sendable {
    let filter: SCContentFilter
    init(_ filter: SCContentFilter) { self.filter = filter }
}

extension ScreenShare: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let box = FilterBox(filter)
        Task { @MainActor in self.finish(box.filter) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
