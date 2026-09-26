import AppKit
import Foundation
import LLMTrayCore

/// Builds a bug report (report.txt, the server log's tail, recent crash
/// reports, zipped) and hands it to the system's mail compose sheet,
/// addressed to support. Chats are never part of it; the home folder shows
/// as "~".
@MainActor
enum BugReporter {
    static let address = "bugreport@ipsupport.us"
    static let product = "LLMTray"

    struct Options {
        var description = ""
        var includeServerLog = true
        var includeCrashReports = true
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { $0 == short ? short : "\(short) (\($0))" } ?? short
    }

    // MARK: - Gathering

    /// The report's text: everything but the log and the crash reports.
    /// `modelDetails`: from modelDetails() (it reads the model's folder,
    /// so not in a view's body). `attachments`: the other files, listed.
    static func report(_ options: Options, server: ServerManager, runtimeVersions: String,
                       modelDetails: [(String, String)], attachments: [String]) -> BugReport {
        let defaults = UserDefaults.standard
        let modelID = defaults[Pref.selectedModelID]
        let model = modelID.flatMap { ModelCatalog.shared.model(id: $0) }
        let profile = ProfileManager.shared.resolved(for: modelID)

        var app: [(String, String)] = [
            ("Version", version),
            ("Update channel", defaults[Pref.betaUpdates] ? "beta" : "stable"),
            ("Language", AppLanguage.effective(AppLanguage.current) ?? "system"),
            ("Chat tabs open", String(ChatTabs.shared.tabs.count)),
        ]
        app.append(("Image generation", profile.enableImageGeneration ? "on (\(profile.imageGenModel))" : "off"))

        let os = ProcessInfo.processInfo
        let system: [(String, String)] = [
            ("macOS", os.operatingSystemVersionString),
            ("Mac", sysctl("hw.model") ?? "?"),
            ("Chip", sysctl("machdep.cpu.brand_string") ?? "?"),
            ("Memory", ByteCountFormatter.string(fromByteCount: Int64(os.physicalMemory), countStyle: .memory)),
            ("GPU wired limit", sysctl("iogpu.wired_limit_mb").map { $0 == "0" ? "default" : "\($0) MB" } ?? "?"),
            ("Thermal state", thermal(os.thermalState)),
            ("Uptime", String(format: "%.1f h", os.systemUptime / 3600)),
        ]

        let runtime: [(String, String)] = [
            ("Pinned mlx-lm", RuntimePin.current?.ref ?? "?"),
            ("Python packages", runtimeVersions),
        ]

        var serverLines: [(String, String)] = [
            ("State", statusLine(server)),
            ("Port", String(defaults[Pref.port])),
            ("LAN access", defaults[Pref.allowLAN] ? "on" : "off"),
        ]
        if !server.launchedArguments.isEmpty {
            serverLines.append(("Launched with", BugReport.withoutSecrets(server.launchedArguments).joined(separator: " ")))
        }

        var modelLines: [(String, String)] = [("Selected", modelID ?? "none")]
        if let model {
            modelLines.append(("Name", model.displayName))
            modelLines += modelDetails
        }
        modelLines.append(("Profile", ProfileManager.shared.profile(for: modelID).name))

        return BugReport(
            product: product, version: version, description: options.description,
            sections: [
                .init("App", app), .init("System", system), .init("Runtime", runtime),
                .init("Server", serverLines), .init("Model", modelLines),
                .init("Attached", attachments.isEmpty ? [("Files", "report.txt only")] : attachments.map { ("File", $0) }),
            ]
        )
    }

    /// The installed server runtime's Python and package versions.
    static func runtimeVersions() async -> String {
        let script = """
            import platform, importlib.metadata as m
            out = ["python " + platform.python_version()]
            for p in ("mlx", "mlx-lm", "mlx-metal", "transformers"):
                try: out.append(p + " " + m.version(p))
                except Exception: pass
            print(", ".join(out))
            """
        let collected = LineCollector()
        do {
            // Line by line, in order (run()'s log chunks can arrive after it returns).
            try await ProcessRunner.runStreaming(MLXRuntimeInstaller.venvPython, ["-c", script]) { line in collected.add(line) }
        } catch {
            return "not available (\(error.localizedDescription))"
        }
        return collected.last ?? "?"
    }

    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var last: String? {
            lock.withLock { lines.last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The selected model's config fields and size, read off the main thread.
    static func modelDetails() async -> [(String, String)] {
        guard let id = UserDefaults.standard[Pref.selectedModelID],
              let path = ModelCatalog.shared.model(id: id)?.path else { return [] }
        // The catalog has the size already (counted off the main thread,
        // symlinks followed).
        let known = ModelCatalog.shared.sizes[path]
        let lines = await Task.detached(priority: .utility) { modelConfig(at: path, size: known).map { [$0.0, $0.1] } }.value
        return lines.map { ($0[0], $0[1]) }
    }

    /// A few fields of the model's config.json: what it is and how it's
    /// quantized, and its size.
    nonisolated static func modelConfig(at path: String, size known: Int64? = nil) -> [(String, String)] {
        let url = URL(fileURLWithPath: path).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [(String, String)] = []
        if let type = json["model_type"] { out.append(("Type", "\(type)")) }
        let quant = (json["quantization"] ?? json["quantization_config"]) as? [String: Any]
        if let quant {
            let bits = quant["bits"].map { "\($0)-bit" } ?? ""
            let group = quant["group_size"].map { "group \($0)" } ?? ""
            let mode = (quant["mode"] ?? quant["quant_method"]).map { "\($0)" } ?? ""
            out.append(("Quantization", [bits, group, mode].filter { !$0.isEmpty }.joined(separator: ", ")))
        }
        let size = known ?? (try? FileManager.default.subpathsOfDirectory(atPath: path))?.reduce(Int64(0)) { total, sub in
            let attrs = try? FileManager.default.attributesOfItem(atPath: path + "/" + sub)
            return total + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        if let size { out.append(("Size on disk", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
        return out
    }

    /// LLMTray's crash reports from the last two weeks, newest first.
    static func recentCrashReports(limit: Int = 5) -> [URL] {
        let dirs = [NSHomeDirectory() + "/Library/Logs/DiagnosticReports"]
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        var found: [(URL, Date)] = []
        for dir in dirs {
            let url = URL(fileURLWithPath: dir)
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "ips" {
                let name = file.lastPathComponent
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard date > cutoff else { continue }
                // The model server's crashes are Python's: ours when the
                // runtime under LLMTray's Application Support is loaded.
                if name.hasPrefix(product) || (name.hasPrefix("Python") && isOurPython(file)) {
                    found.append((file, date))
                }
            }
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private static func isOurPython(_ file: URL) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.contains("Application Support/LLMTray/") || text.contains("Application Support\\/LLMTray\\/")
    }

    // MARK: - Packaging and sending

    /// The server log as it's attached: its tail, without chat content,
    /// the home folder as "~".
    static func serverLogForReport(_ server: ServerManager) -> String {
        BugReport.withoutUserName(BugReport.redact(BugReport.withoutChatContent(BugReport.tail(server.log, maxBytes: 512 * 1024))))
    }

    /// The server log can go: there is one, and verbose logging (which puts
    /// the chats in it) wasn't on while it was written.
    static func canAttachServerLog(_ server: ServerManager) -> Bool {
        !server.log.isEmpty && !BugReport.hasVerboseRecords(server.log)
    }

    /// The crash reports as they're attached (name, redacted text), for the
    /// form to show.
    static func crashReportsForReport() -> [(name: String, text: String)] {
        recentCrashReports().compactMap { url in
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url.lastPathComponent, BugReport.withoutUserName(BugReport.redactCrashReport(content)))
        }
    }

    /// The files the zip will hold besides report.txt.
    static func attachments(_ options: Options, server: ServerManager) -> [String] {
        var files: [String] = []
        if options.includeServerLog, canAttachServerLog(server) { files.append("server.log") }
        if options.includeCrashReports { files += recentCrashReports().map { "crash-reports/" + $0.lastPathComponent } }
        return files
    }

    /// The report folder, zipped, in the app's caches. Each report its own
    /// (an earlier one may still be attached to an unsent email); ones
    /// older than a day are cleared.
    static func package(_ report: BugReport, options: Options, server: ServerManager) async throws -> URL {
        let fm = FileManager.default
        let root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("\(product)/BugReports")
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        for old in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < dayAgo { try? fm.removeItem(at: old) }
        }
        let stamp = ISO8601DateFormatter().string(from: report.createdAt).replacingOccurrences(of: ":", with: "")
        let name = "\(product)-bug-report-\(stamp)-\(UUID().uuidString.prefix(6))"
        let folder = root.appendingPathComponent(name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var text = report.text()
        if options.includeServerLog, canAttachServerLog(server) {
            try serverLogForReport(server).write(to: folder.appendingPathComponent("server.log"), atomically: true, encoding: .utf8)
        }
        if options.includeCrashReports {
            let crashes = recentCrashReports()
            if !crashes.isEmpty {
                let dir = folder.appendingPathComponent("crash-reports")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                var unreadable: [String] = []
                for crash in crashes {
                    guard let content = try? String(contentsOf: crash, encoding: .utf8),
                          (try? BugReport.withoutUserName(BugReport.redactCrashReport(content)).write(to: dir.appendingPathComponent(crash.lastPathComponent), atomically: true, encoding: .utf8)) != nil
                    else { unreadable.append(crash.lastPathComponent); continue }
                }
                if !unreadable.isEmpty {
                    text += "\nNot attached (couldn't be read): " + unreadable.joined(separator: ", ") + "\n"
                }
            }
        }
        try text.write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        let zip = root.appendingPathComponent(name + ".zip")
        try await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, zip.path])
        return zip
    }

    /// The mail compose sheet with the report attached. Without a mail
    /// service that takes attachments -- or if it fails to compose -- a
    /// plain mailto, with the file shown in Finder to attach by hand.
    /// `fallback` runs in that case (the view says so).
    static func compose(_ report: BugReport, attachment: URL, fallback: @escaping () -> Void) {
        // Redacted like the report: a pasted error's paths too.
        let described = BugReport.withoutUserName(BugReport.redact(report.description.trimmingCharacters(in: .whitespacesAndNewlines)))
        let body = """
            \(described)

            ---
            \(report.subject). The full report is attached (\(attachment.lastPathComponent)).
            """
        let plain = {
            mailto(report, body: body)
            NSWorkspace.shared.activateFileViewerSelecting([attachment])
            fallback()
        }
        guard let service = NSSharingService(named: .composeEmail) else { return plain() }
        service.recipients = [address]
        service.subject = report.subject
        let items: [Any] = [body, attachment]
        guard service.canPerform(withItems: items) else { return plain() }
        // Kept until it reports back: a released service drops the compose.
        let handler = ShareHandler(service: service, onFailure: plain)
        activeShare = handler
        service.delegate = handler
        service.perform(withItems: items)
    }

    private static var activeShare: ShareHandler?

    private final class ShareHandler: NSObject, NSSharingServiceDelegate {
        let service: NSSharingService
        let onFailure: () -> Void

        init(service: NSSharingService, onFailure: @escaping () -> Void) {
            self.service = service
            self.onFailure = onFailure
        }

        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            Task { @MainActor in BugReporter.activeShare = nil }
        }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
            Task { @MainActor in
                // Cancelled by the user: nothing to fall back to.
                if (error as NSError).code != NSUserCancelledError { self.onFailure() }
                BugReporter.activeShare = nil
            }
        }
    }

    private static func mailto(_ report: BugReport, body: String) {
        var mailto = URLComponents()
        mailto.scheme = "mailto"
        mailto.path = address
        mailto.queryItems = [
            URLQueryItem(name: "subject", value: report.subject),
            URLQueryItem(name: "body", value: body + "\n\n" + NSLocalizedString("(Please attach the report file shown in Finder.)", comment: "bug report mail")),
        ]
        // A literal "+" reads as a space to some mail apps.
        mailto.percentEncodedQuery = mailto.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        if let url = mailto.url { NSWorkspace.shared.open(url) }
    }

    // MARK: -

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        // Numbers come as 4 or 8 bytes, strings as C strings.
        if name == "iogpu.wired_limit_mb" {
            if size == 4 {
                var value: Int32 = 0
                guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
                return String(value)
            }
            var value: Int64 = 0
            guard size == 8, sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return String(value)
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func statusLine(_ server: ServerManager) -> String {
        switch server.state {
        case .stopped: return server.isIdleUnloaded ? "idle-unloaded" : "stopped"
        case .starting: return "starting"
        case .running(let port, let model): return "running \(model) on :\(port)"
        case .failed(let message): return "failed: \(message)"
        }
    }
}
