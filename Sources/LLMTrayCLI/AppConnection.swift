import Darwin
import Foundation
import LLMTrayCore

/// LLMTrayCore's client, its failures as the CLI's errors.
struct ControlClient {
    let socket: ControlSocketClient

    init(_ socket: ControlSocketClient) { self.socket = socket }

    @discardableResult
    func run(_ command: ControlCommand, onEvent: (ControlReply) -> Void = { _ in }) throws -> ControlReply {
        do {
            return try socket.run(command, onEvent: onEvent)
        } catch let failure as ControlSocketClient.Failure {
            throw CLIError(failure.description)
        }
    }
}

/// An error for stderr, exit status 1.
struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Reaching the app, starting it first when it isn't running.
enum AppConnection {
    /// The standalone's: the CLI comes only with that build (adr/0019).
    static let bundleID = AppIdentity.standaloneBundleID
    static let launchTimeout: TimeInterval = 20

    static func connect() throws -> ControlClient {
        let path = ControlProtocol.socketPath()
        if let client = ControlSocketClient.connect(path: path) { return ControlClient(client) }
        // A socket path of one's own (tests, a dev copy): that app is
        // started by whoever set it, not by `open`.
        if ProcessInfo.processInfo.environment[ControlProtocol.socketPathEnvironment] != nil {
            throw CLIError("nothing answers at \(path) (\(ControlProtocol.socketPathEnvironment))")
        }
        try launchApp()
        let deadline = Date().addingTimeInterval(launchTimeout)
        while Date() < deadline {
            usleep(250_000)
            if let client = ControlSocketClient.connect(path: path) { return ControlClient(client) }
        }
        throw CLIError("LLMTray didn't answer within \(Int(launchTimeout)) s. Is it a version with the command-line tool? "
                       + "(The App Store version doesn't include it.)")
    }

    /// In the background (`-g`: not brought to the front; `-j`: hidden):
    /// the app bundle this binary is inside of when it is (so `llmtray`
    /// starts its own LLMTray, not another copy), else by bundle id.
    private static func launchApp() throws {
        var arguments = ["-g", "-j"]
        if let bundle = CLIInfo.appBundle {
            arguments.append(bundle)
        } else {
            arguments += ["-b", bundleID]
        }
        if isatty(STDERR_FILENO) != 0 { Output.err("Starting LLMTray…") }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = arguments
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        do {
            try open.run()
        } catch {
            throw CLIError("couldn't start LLMTray: \(error.localizedDescription)")
        }
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            throw CLIError("LLMTray isn't running and couldn't be started -- is it installed? (open \(arguments.joined(separator: " ")) failed)")
        }
    }
}

/// This binary and the app it came with.
enum CLIInfo {
    /// The resolved path of this executable (through ~/.local/bin/llmtray's link).
    static var executable: String {
        let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }

    static var appBundle: String? { CommandLineTool.appBundle(containing: executable) }

    /// The app's version, from the bundle it's in; "dev" for a bare build.
    static var version: String {
        guard let bundle = appBundle,
              let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist"),
              let version = info["CFBundleShortVersionString"] as? String else { return "dev" }
        return version
    }
}

/// Unbuffered writes (an answer shows as it streams). write(2), not
/// FileHandle: FileHandle raises an Objective-C exception -- a crash -- on
/// a closed pipe. stdout closed (`llmtray chat ... | head -1`): done, as
/// `head`'s other side would be; any other failure (a full disk) is one.
enum Output {
    static func out(_ text: String, terminator: String = "\n") {
        guard !write(STDOUT_FILENO, text + terminator) else { return }
        if errno == EPIPE { exit(0) }
        err("llmtray: couldn't write the output: \(String(cString: strerror(errno)))")
        exit(1)
    }

    static func err(_ text: String, terminator: String = "\n") {
        _ = write(STDERR_FILENO, text + terminator)
    }

    private static func write(_ fd: Int32, _ text: String) -> Bool {
        var bytes = Array(text.utf8)
        return bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    static var stdoutIsTerminal: Bool { isatty(STDOUT_FILENO) != 0 }
    static var stderrIsTerminal: Bool { isatty(STDERR_FILENO) != 0 }
}
