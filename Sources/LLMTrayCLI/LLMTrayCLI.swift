import Darwin
import Foundation
import LLMTrayCore

/// `llmtray` (adr/0019): LLMTray from the terminal. Control goes over the
/// app's socket (ControlClient), `chat` to its OpenAI endpoint like any
/// other client. Exit status: 0 ok, 1 error, 2 usage; 130 after Ctrl-C.
@main
enum LLMTrayCLI {
    static func main() {
        // A write to a closed pipe (`llmtray chat ... | head`) ends the
        // write, not the process mid-line.
        signal(SIGPIPE, SIG_IGN)
        let command: CLICommand
        switch CommandLineArguments.parse(Array(CommandLine.arguments.dropFirst())) {
        case .success(let parsed): command = parsed
        case .failure(let usage):
            Output.err("llmtray: \(usage.message)")
            Output.err("Run `llmtray help\(usage.command.map { " " + $0 } ?? "")` for usage.")
            exit(2)
        }
        do {
            try run(command)
            exit(Interrupt.happened ? 130 : 0)
        } catch let error as CLIError {
            Output.err("llmtray: \(error.description)")
            exit(1)
        } catch let usage as CLIUsageError {
            Output.err("llmtray: \(usage.message)")
            exit(2)
        } catch {
            Output.err("llmtray: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run(_ command: CLICommand) throws {
        switch command {
        case .version:
            Output.out("llmtray \(CLIInfo.version)")
        case .help(let topic):
            Output.out(CommandLineArguments.help(topic))
        case .status(let json):
            let status = try statusNow()
            Output.out(json ? try prettyJSON(status) : CommandLineOutput.status(status))
        case .models(let json):
            let models = try AppConnection.connect().run(.models).models ?? []
            Output.out(json ? try prettyJSON(models) : CommandLineOutput.models(models))
        case .start(let model):
            let status = try start(model)
            Output.out("running \(status.model ?? "the model") at \(status.baseURL)")
        case .stop:
            try AppConnection.connect().run(.stop)
            Output.out("stopped")
        case .api:
            let client = try AppConnection.connect()
            let status = try client.run(.status).status
            guard let status else { throw CLIError("LLMTray sent no status") }
            Output.out(CommandLineOutput.api(status, exampleModel: status.model ?? status.selectedModel))
        case .pull(let repo):
            try pull(repo)
        case .image(let options):
            try image(options)
        case .chat(let options):
            try ChatCommand(options: options).run()
        }
    }

    static func statusNow() throws -> ControlStatus {
        guard let status = try AppConnection.connect().run(.status).status else { throw CLIError("LLMTray sent no status") }
        return status
    }

    /// Starts (or switches to) `model`, the state changes on stderr; the
    /// status once it's running.
    @discardableResult
    static func start(_ model: String?, quiet: Bool = false) throws -> ControlStatus {
        let done = try AppConnection.connect().run(.start(model: model)) { event in
            guard !quiet, event.event == ControlReply.Event.state, let state = event.state else { return }
            switch state {
            case ControlStatus.starting: Output.err("loading \(model ?? "the selected model")…")
            default: break
            }
        }
        guard let status = done.status else { throw CLIError("LLMTray sent no status") }
        return status
    }

    // MARK: - pull, image

    static func pull(_ repo: String) throws {
        let client = try AppConnection.connect()
        Interrupt.onInterrupt {
            Output.err("\nstopped watching -- the download goes on in LLMTray")
        }
        let line = ProgressLine()
        let done = try client.run(.pull(repo: repo)) { event in
            if event.event == ControlReply.Event.queued {
                line.note(event.message ?? "waiting")
            } else if event.event == ControlReply.Event.progress {
                line.show(event.progress, event.message)
            }
        }
        line.end()
        Output.out("downloaded \(repo)" + (done.path.map { " to \($0)" } ?? ""))
    }

    static func image(_ options: CLICommand.ImageOptions) throws {
        let output = options.output ?? CommandLineOutput.defaultImageName(at: Date())
        let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        // Checked before minutes of generation, not after.
        guard FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
            throw CLIError("can't write to \(url.deletingLastPathComponent().path)")
        }
        let client = try AppConnection.connect()
        Interrupt.onInterrupt {
            Output.err("\nstopped waiting -- an image already being made is finished by LLMTray, but not saved")
        }
        let line = ProgressLine()
        let done = try client.run(.image(.init(prompt: options.prompt, width: options.width, height: options.height, model: options.model))) { event in
            if event.event == ControlReply.Event.queued, let position = event.position {
                line.note("waiting for the image generator: \(position) ahead")
            } else if event.event == ControlReply.Event.progress {
                if event.progress == nil { line.note(event.message ?? "") } else { line.show(event.progress, event.message) }
            }
        }
        line.end()
        guard let base64 = done.image, let png = Data(base64Encoded: base64) else { throw CLIError("LLMTray sent no image") }
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            throw CLIError("couldn't save \(url.path): \(error.localizedDescription)")
        }
        if let message = done.message, Output.stderrIsTerminal { Output.err(message) }
        Output.out(url.path)
    }

    private static func prettyJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// A status line that updates in place on a terminal (stderr). Off one (a
/// log, a pipe) every tick would be a line of its own: there it prints
/// what it's doing when that changes and the progress every 10%.
final class ProgressLine {
    private var last: String?
    private var lastDecile: Int?
    private var shown = false

    /// Waiting, unloading...: always worth a line.
    func note(_ text: String) {
        guard text != last else { return }
        if Output.stderrIsTerminal {
            Output.err("\r\u{1B}[2K" + text, terminator: "")
            shown = true
        } else {
            Output.err(text)
        }
        last = text
        lastDecile = nil
    }

    func show(_ fraction: Double?, _ detail: String?) {
        let text = CommandLineOutput.progress(fraction, detail)
        guard text != last else { return }
        if Output.stderrIsTerminal {
            Output.err("\r\u{1B}[2K" + text, terminator: "")
            shown = true
        } else {
            let decile = fraction.map { Int(($0 * 10).rounded(.down)) }
            if last == nil || decile != lastDecile { Output.err(text) }
            lastDecile = decile
        }
        last = text
    }

    func end() {
        if shown { Output.err("") }
        shown = false
    }
}

/// Ctrl-C: whatever the command needs to undo, then exit 130. On a global
/// queue, so it fires while the main thread blocks on a read.
/// `exits` false: the command winds down by itself once `handler` has
/// cancelled its work (chat: the request ends, the main thread returns)
/// and exits 130 then -- exiting here would race it.
enum Interrupt {
    private static var source: DispatchSourceSignal?
    private static let lock = NSLock()
    private static var interrupted = false

    static var happened: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    static func onInterrupt(exits: Bool = true, _ handler: @escaping () -> Void) {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            lock.lock()
            interrupted = true
            lock.unlock()
            handler()
            if exits { exit(130) }
        }
        source.resume()
        self.source = source
    }
}
