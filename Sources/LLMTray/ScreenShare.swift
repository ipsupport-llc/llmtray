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
    /// A pick or a capture is under way: one at a time, app-wide (the
    /// picker and the chat stepping aside are one each).
    private(set) var isBusy = false
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

    enum CaptureError: Error {
        /// Another pick is under way.
        case busy
        /// Cancelled in the picker.
        case cancelled
        /// Picked, but no picture came (the window closed meanwhile…).
        case failed
    }

    /// The system picker for one window (or one display), then one still
    /// of it.
    func capture(screen: Bool) async -> Result<Capture, CaptureError> {
        guard !isBusy else { return .failure(.busy) }
        isBusy = true
        defer { isBusy = false }
        NotificationCenter.default.post(name: .sharingWillPick, object: nil)
        defer { NotificationCenter.default.post(name: .sharingDidPick, object: nil) }
        guard let filter = await pick(screen: screen) else { return .failure(.cancelled) }
        let config = SCStreamConfiguration()
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(rect.width * scale))
        config.height = max(1, Int(rect.height * scale))
        config.showsCursor = false
        config.capturesAudio = false
        let box = FilterBox(filter)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: box.filter, configuration: config) else {
            return .failure(.failed)
        }
        return .success(Capture(image: image, context: describe(filter, screen: screen)))
    }

    private func pick(screen: Bool) async -> SCContentFilter? {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = screen ? .singleDisplay : .singleWindow
        config.allowsChangingSelectedContent = false
        if let id = Bundle.main.bundleIdentifier { config.excludedBundleIDs = [id] }
        picker.defaultConfiguration = config
        picker.add(self)
        // One pick at a time (isBusy): nothing pending here. Pending before
        // the picker starts, so a failure to start finds it.
        let filter = await withCheckedContinuation { continuation in
            pending = continuation
            picker.isActive = true
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
        // Quit since the menu was drawn: asking it would launch it again.
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == browser.bundleID }) else {
            return .failure(.noTab)
        }
        switch await Self.run(BrowserTab.script(for: browser)) {
        case .success(let answer):
            return BrowserTab.parse(answer, titleOnly: false).map { .success($0) } ?? .failure(.noTab)
        case .failure(let error):
            // A Chromium browser refuses the page script alone when its
            // JavaScript from Apple Events is off -- with the same error
            // as Automation turned down, in some: its title and address
            // are asked for anyway, and only their refusal is Automation's.
            guard browser.family == .chromium else { return .failure(Self.isDenial(error.code) ? .notAllowed : .noTab) }
            switch await Self.run(BrowserTab.script(for: browser, titleOnly: true)) {
            case .success(let answer):
                return BrowserTab.parse(answer, titleOnly: true).map { .success($0) } ?? .failure(.noTab)
            case .failure(let error):
                return .failure(Self.isDenial(error.code) ? .notAllowed : .noTab)
            }
        }
    }

    struct ScriptError: Error { let code: Int }

    /// Automation turned down (errAEEventNotPermitted, or the user
    /// declined the prompt).
    private static func isDenial(_ code: Int) -> Bool { code == -1743 || code == -1744 }

    /// Runs `source` in osascript, a process of its own: NSAppleScript is
    /// for the main thread, and there it would hold the app while the
    /// browser answers or macOS's Automation prompt waits. macOS asks for
    /// LLMTray (the responsible app). The error number when it fails.
    private nonisolated static func run(_ source: String) async -> Result<String, ScriptError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-"]
                let input = Pipe(), output = Pipe(), errors = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = errors
                do { try process.run() } catch {
                    continuation.resume(returning: .failure(ScriptError(code: -1)))
                    return
                }
                input.fileHandleForWriting.write(Data(source.utf8))
                try? input.fileHandleForWriting.close()
                // Read before waiting: a long page fills the pipe.
                let out = output.fileHandleForReading.readDataToEndOfFile()
                let err = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    // osascript ends what it prints with a newline.
                    var text = String(decoding: out, as: UTF8.self)
                    if text.hasSuffix("\n") { text.removeLast() }
                    continuation.resume(returning: .success(text))
                } else {
                    continuation.resume(returning: .failure(ScriptError(code: BrowserTab.errorNumber(String(decoding: err, as: UTF8.self)) ?? -1)))
                }
            }
        }
    }
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
