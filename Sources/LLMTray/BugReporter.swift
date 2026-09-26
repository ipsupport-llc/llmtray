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
    static func report(_ options: Options, server: ServerManager, runtimeVersions: String) -> BugReport {
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
            serverLines.append(("Launched with", server.launchedArguments.joined(separator: " ")))
        }

        var modelLines: [(String, String)] = [("Selected", modelID ?? "none")]
        if let model {
            modelLines.append(("Name", model.displayName))
            modelLines += modelConfig(at: model.path)
        }
        modelLines.append(("Profile", ProfileManager.shared.profile(for: modelID).name))

        return BugReport(
            product: product, version: version, description: options.description,
            sections: [
                .init("App", app), .init("System", system), .init("Runtime", runtime),
                .init("Server", serverLines), .init("Model", modelLines),
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
            try await ProcessRunner.run(MLXRuntimeInstaller.venvPython, ["-c", script]) { line in collected.lines.append(line) }
        } catch {
            return "not available (\(error.localizedDescription))"
        }
        return collected.lines.last { !$0.isEmpty } ?? "?"
    }

    @MainActor private final class LineCollector { var lines: [String] = [] }

    /// A few fields of the model's config.json: what it is and how it's
    /// quantized.
    static func modelConfig(at path: String) -> [(String, String)] {
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
        let size = (try? FileManager.default.subpathsOfDirectory(atPath: path))?.reduce(Int64(0)) { total, sub in
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
            for file in files where file.lastPathComponent.hasPrefix(product) {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if date > cutoff { found.append((file, date)) }
            }
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    // MARK: - Packaging and sending

    /// The report folder, zipped, in the app's caches (removed on the next
    /// report).
    static func package(_ report: BugReport, options: Options, server: ServerManager) async throws -> URL {
        let fm = FileManager.default
        let root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("\(product)/BugReports")
        try? fm.removeItem(at: root)
        let name = "\(product)-bug-report-\(Int(report.createdAt.timeIntervalSince1970))"
        let folder = root.appendingPathComponent(name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try report.text().write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        if options.includeServerLog, !server.log.isEmpty {
            let log = BugReport.redact(BugReport.tail(server.log, maxBytes: 512 * 1024))
            try log.write(to: folder.appendingPathComponent("server.log"), atomically: true, encoding: .utf8)
        }
        if options.includeCrashReports {
            let crashes = recentCrashReports()
            if !crashes.isEmpty {
                let dir = folder.appendingPathComponent("crash-reports")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for crash in crashes {
                    let text = (try? String(contentsOf: crash, encoding: .utf8)).map { BugReport.redact($0) }
                    try? text?.write(to: dir.appendingPathComponent(crash.lastPathComponent), atomically: true, encoding: .utf8)
                }
            }
        }
        let zip = root.appendingPathComponent(name + ".zip")
        try await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, zip.path])
        return zip
    }

    /// The mail compose sheet with the report attached. Without a mail
    /// service that takes attachments: a plain mailto and the file shown in
    /// Finder, to attach by hand. Returns false in that case.
    @discardableResult
    static func compose(_ report: BugReport, attachment: URL) -> Bool {
        let body = """
            \(report.description.trimmingCharacters(in: .whitespacesAndNewlines))

            ---
            \(report.subject). The full report is attached (\(attachment.lastPathComponent)).
            """
        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = [address]
            service.subject = report.subject
            let items: [Any] = [body, attachment]
            if service.canPerform(withItems: items) {
                service.perform(withItems: items)
                return true
            }
        }
        var mailto = URLComponents()
        mailto.scheme = "mailto"
        mailto.path = address
        mailto.queryItems = [
            URLQueryItem(name: "subject", value: report.subject),
            URLQueryItem(name: "body", value: body + "\n\n" + NSLocalizedString("(Please attach the report file shown in Finder.)", comment: "bug report mail")),
        ]
        if let url = mailto.url { NSWorkspace.shared.open(url) }
        NSWorkspace.shared.activateFileViewerSelecting([attachment])
        return false
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
