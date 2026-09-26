import AppKit
import LLMTrayCore
import SwiftUI

extension Notification.Name {
    /// Opens AppDelegate's About window (the app menu's About item).
    static let showAbout = Notification.Name("LLMTray.showAbout")
}

/// About LLMTray: the app, and every license that applies -- what's
/// bundled (Licenses.json, generated at build time by
/// scripts/generate_licenses.py) and what's installed on this Mac (the
/// Python runtimes and the downloaded models, read live).
@MainActor
final class AboutLicenses: ObservableObject {
    @Published private(set) var groups: [LicenseCatalog.Group] = []
    @Published private(set) var scanning = true

    func load() {
        let bundled = Bundle.main.url(forResource: "Licenses", withExtension: "json").flatMap(LicenseCatalog.load)
        groups = bundled?.groups ?? [LicenseCatalog.Group(id: "missing", title: "Bundled software", entries: [
            LicenseCatalog.Entry(name: "Licenses.json", license: "not in this build",
                                 text: "This build has no generated license list: scripts/build_app.sh writes it (with THIRD_PARTY_NOTICES.txt) into the app's Resources."),
        ])]
        let runtimeDir = RuntimePaths.externalRuntimeDir
        let modelPaths = ModelCatalog.shared.models.map { ($0.path, $0.path.split(separator: "/").suffix(2).joined(separator: "/")) }
        // Image models live under their own names; their repo is known.
        let imageModels = ImageGenModel.allCases.map { (runtimeDir + "/mflux_models/" + $0.rawValue, $0.hfRepo) }
            .filter { FileManager.default.fileExists(atPath: $0.0) }
        let musicModels = MusicManager.modelPaths.filter { FileManager.default.fileExists(atPath: $0.0) }
        let musicVenv = MusicManager.venvDir
        let serverVenv = MLXRuntimeInstaller.venvDir
        scanning = true
        Task.detached(priority: .userInitiated) {
            var live: [LicenseCatalog.Group] = []
            func venvGroup(_ id: String, _ title: String, _ path: String) {
                guard let site = PythonPackageLicenses.sitePackages(venv: URL(fileURLWithPath: path)) else { return }
                let entries = PythonPackageLicenses.scan(sitePackages: site)
                if !entries.isEmpty { live.append(LicenseCatalog.Group(id: id, title: title, entries: entries)) }
            }
            // Also with a bundled runtime (Full): an in-app runtime update,
            // or a Thin install before, runs from here instead.
            venvGroup("server-runtime", "Server runtime (installed on this Mac)", serverVenv)
            venvGroup("image-runtime", "Image generation (installed on this Mac)", runtimeDir + "/mflux_venv")
            venvGroup("music-runtime", "Music generation (installed on this Mac)", musicVenv)
            let models = Self.modelEntries(modelPaths + imageModels + musicModels)
            if !models.isEmpty { live.append(LicenseCatalog.Group(id: "models", title: "Downloaded models", entries: models)) }
            await MainActor.run { [live] in
                self.groups += live
                self.scanning = false
            }
        }
    }

    /// A model's license is its publisher's: shown from its card, with
    /// where to read it.
    nonisolated private static func modelEntries(_ models: [(path: String, repo: String)]) -> [LicenseCatalog.Entry] {
        models.map { path, name in
            let readme = path + "/README.md"
            let card = try? String(contentsOfFile: readme, encoding: .utf8)
            let license = card.flatMap(ModelCardLicense.parse) ?? (card == nil ? "no model card" : "not stated")
            let hub = "https://huggingface.co/\(name)"
            let text = "License: \(license)\n\nA model's license is set by its publisher: read it on the model card before using the model, "
                + "especially commercially.\n\nModel card: \(card == nil ? hub : readme)\nFolder: \(path)"
            return LicenseCatalog.Entry(name: name, license: license, url: hub, text: text)
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

struct AboutView: View {
    @StateObject private var licenses = AboutLicenses()
    @State private var selection: String?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { $0 == short ? short : "\(short) (\($0))" } ?? short
    }

    private var selected: LicenseCatalog.Entry? {
        for group in licenses.groups {
            if let entry = group.entries.first(where: { key($0, in: group) == selection }) { return entry }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("LLMTray").font(.title2.bold())
                    Text(String(format: NSLocalizedString("Version %@", comment: ""), version)).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Text("Apache License 2.0").foregroundStyle(.secondary)
                        Link(destination: URL(string: "https://github.com/ipsupport-llc/llmtray")!) { Text("Source on GitHub") }
                        Link(destination: URL(string: "https://ipsupport.us")!) { Text(verbatim: "ipsupport.us") }
                        Button("Report a Bug…") { NotificationCenter.default.post(name: .showBugReport, object: nil) }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            HSplitView {
                List(selection: $selection) {
                    ForEach(licenses.groups) { group in
                        Section(group.title) {
                            ForEach(group.entries, id: \.self.id) { entry in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.version.map { "\(entry.name) \($0)" } ?? entry.name)
                                    Text(entry.license).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .tag(key(entry, in: group))
                            }
                        }
                    }
                    if licenses.scanning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reading what's installed…").foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minWidth: 220, idealWidth: 260)
                Group {
                    if let entry = selected {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.version.map { "\(entry.name) \($0)" } ?? entry.name).font(.headline)
                            HStack {
                                Text(entry.license).foregroundStyle(.secondary)
                                if let url = entry.url.flatMap(URL.init(string:)) { Link(url.host ?? url.absoluteString, destination: url) }
                            }
                            .font(.callout)
                            // Some are big (torch's ~370KB): a text view lays
                            // them out lazily, SwiftUI Text would hang.
                            LicenseTextView(text: entry.text).id(selection)
                        }
                        .padding(12)
                    } else {
                        Text("Select a component to see its license.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 320)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .onAppear {
            licenses.load()
            if selection == nil, let group = licenses.groups.first, let entry = group.entries.first {
                selection = key(entry, in: group)
            }
        }
    }

    /// Unique across groups (a package can be in two venvs).
    private func key(_ entry: LicenseCatalog.Entry, in group: LicenseCatalog.Group) -> String {
        group.id + "/" + entry.id
    }
}

/// Read-only, selectable, scrolling monospaced text.
private struct LicenseTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            view.textContainerInset = NSSize(width: 0, height: 4)
            view.string = text
        }
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.scrollToBeginningOfDocument(nil)
    }
}
