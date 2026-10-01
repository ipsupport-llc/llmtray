#if !APP_STORE
import AppKit
import Foundation
import LLMTrayCore
import SwiftUI

/// Settings › General › Command-line tool (adr/0019 §5): a symlink
/// `~/.local/bin/llmtray` to this app's Contents/Helpers/llmtray -- a link,
/// not a copy, so a Sparkle update (which replaces the whole app) carries
/// it along. Never replaces a file that isn't LLMTray's own link.
@MainActor
final class CommandLineToolInstaller: ObservableObject {
    @Published private(set) var existing: CommandLineTool.Existing = .nothing
    @Published private(set) var error: String?
    /// The login shell's PATH lacks ~/.local/bin, or couldn't be read:
    /// the line to add (shown when unsure rather than not at all).
    @Published private(set) var pathHint: (file: String, line: String)?
    private var probe: Task<Void, Never>?

    var linkPath: String { (CommandLineTool.linkDirectory as NSString).expandingTildeInPath + "/" + CommandLineTool.linkName }
    var target: String { Bundle.main.bundlePath + "/" + CommandLineTool.bundleSubpath }
    /// A bundled app (not `swift run`): there's a binary to link to.
    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: target) }
    var isInstalled: Bool { existing == .symlink(destination: target) }

    func refresh() {
        existing = CommandLineTool.existing(at: linkPath)
        if isInstalled { checkPath() } else { pathHint = nil }
    }

    func install() {
        error = nil
        let fm = FileManager.default
        do {
            switch CommandLineTool.installPlan(existing: CommandLineTool.existing(at: linkPath), target: target) {
            case .alreadyInstalled:
                break
            case .create:
                try fm.createDirectory(atPath: (linkPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
            case .replace:
                // Our own link to another copy: swapped in place, never via
                // a moment with a half-written file there.
                let temporary = linkPath + ".llmtray-new"
                try? fm.removeItem(atPath: temporary)
                try fm.createSymbolicLink(atPath: temporary, withDestinationPath: target)
                guard rename(temporary, linkPath) == 0 else {
                    try? fm.removeItem(atPath: temporary)
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            case .refuseForeignLink(let destination):
                error = String(format: NSLocalizedString("%@ already exists and points to %@. Remove it first to install LLMTray's.",
                                                         comment: "CLI install: the link, where it points"), linkPath, destination)
            case .refuseFile:
                error = String(format: NSLocalizedString("%@ already exists and isn't LLMTray's. Remove it first to install LLMTray's.",
                                                         comment: "CLI install: the file"), linkPath)
            }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func uninstall() {
        error = nil
        switch CommandLineTool.uninstallPlan(existing: CommandLineTool.existing(at: linkPath)) {
        case .remove:
            do { try FileManager.default.removeItem(atPath: linkPath) } catch { self.error = error.localizedDescription }
        case .nothingInstalled:
            break
        case .refuseForeign:
            error = String(format: NSLocalizedString("%@ isn't LLMTray's link, so it was left as it is.", comment: "CLI uninstall: the file"), linkPath)
        }
        refresh()
    }

    /// Asks the user's login shell for its PATH (what a new Terminal window
    /// gets), off the main thread and for at most 5 s: a slow or broken
    /// shell profile shows the hint instead.
    private func checkPath() {
        probe?.cancel()
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let directory = (CommandLineTool.linkDirectory as NSString).expandingTildeInPath
        probe = Task { [weak self] in
            let path = try? await ProcessRunner.offMain { Self.loginShellPath(shell) }
            guard let self, !Task.isCancelled else { return }
            let onPath = path.flatMap { $0 }.map { CommandLineTool.isOnPath(directory, path: $0, home: NSHomeDirectory()) } ?? false
            self.pathHint = onPath ? nil : CommandLineTool.pathHint(shell: shell)
        }
    }

    nonisolated private static func loginShellPath(_ shell: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Login and interactive: both kinds of profile files, as a new
        // Terminal window reads them.
        process.arguments = ["-l", "-i", "-c", CommandLineTool.pathProbeCommand]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return CommandLineTool.parsePathProbe(String(decoding: output, as: UTF8.self))
    }
}

/// Install / Uninstall, and the PATH line when it's needed.
struct CommandLineToolSection: View {
    @StateObject private var installer = CommandLineToolInstaller()

    var body: some View {
        Section("Command-line tool") {
            LabeledContent {
                if installer.isInstalled {
                    Button("Uninstall") { installer.uninstall() }
                } else {
                    Button("Install") { installer.install() }
                        .disabled(!installer.isAvailable)
                }
            } label: {
                SettingLabel(title: "llmtray in the terminal", help: "Installs the llmtray command in ~/.local/bin: start and stop the server, list and download models, chat, and generate images from a terminal or a script. Run llmtray help for the commands.")
            }
            if !installer.isAvailable {
                Text("Only in the packaged app (not when run from a build folder).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = installer.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if installer.isInstalled, let hint = installer.pathHint {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: NSLocalizedString("~/.local/bin isn't on your shell's PATH yet. Add this line to %@, then open a new terminal window:",
                                                          comment: "CLI install: the shell profile file"), hint.file))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(verbatim: hint.line).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(hint.line, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .onAppear { installer.refresh() }
    }
}
#endif
