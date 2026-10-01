import Foundation

/// The control socket's protocol (adr/0019): what `llmtray` and the app say
/// to each other over `<Application Support>/LLMTray/control.sock`.
/// Newline-delimited JSON. A request is one line, `{"v":1,"cmd":"..."}`
/// with the command's fields beside `cmd`; the reply is one or more lines,
/// the last always `{"done":true,...}` or `{"error":"..."}` -- streaming
/// commands send `{"event":...}` lines before it. Unknown fields are
/// ignored both ways, so either side can add one without the other
/// breaking.
public enum ControlProtocol {
    /// Bumped only for a change an older peer would misread; new optional
    /// fields don't need it.
    public static let version = 1
    public static let socketFileName = "control.sock"
    /// For tests and a second dev copy: the socket at this path instead.
    public static let socketPathEnvironment = "LLMTRAY_CONTROL_SOCKET"
    /// A request line: a prompt with room to spare. Longer is refused
    /// before it's buffered.
    public static let maxRequestBytes = 1 << 20
    /// A reply line: a 2048² PNG in base64 is well under this.
    public static let maxReplyBytes = 64 << 20
    /// `sockaddr_un.sun_path` is 104 bytes on macOS, its NUL included.
    public static let maxSocketPathBytes = 103

    /// `<applicationSupport>/LLMTray/control.sock` -- the same folder as
    /// RuntimePaths.externalRuntimeDir in the app.
    public static func socketPath(applicationSupport: String) -> String {
        (applicationSupport as NSString).appendingPathComponent("LLMTray/" + socketFileName)
    }

    /// Where the socket is for this user: the environment's override, else
    /// in their (non-sandboxed) Application Support.
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment[socketPathEnvironment], !override.isEmpty { return override }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Library/Application Support"
        return socketPath(applicationSupport: appSupport)
    }

    /// One line on the wire: compact JSON (which never contains a raw
    /// newline -- it escapes them in strings) and "\n".
    public static func line<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    /// Reads a request line. Every failure is a message for an `error` line.
    public static func decodeRequest(_ line: Data) -> Result<ControlRequest, ControlRequestError> {
        do {
            return .success(try JSONDecoder().decode(ControlRequest.self, from: line))
        } catch let error as ControlRequestError {
            return .failure(error)
        } catch {
            return .failure(.malformed)
        }
    }

    public static func decodeReply(_ line: Data) throws -> ControlReply {
        try JSONDecoder().decode(ControlReply.self, from: line)
    }
}

// MARK: - Requests

/// What the CLI asks for.
public enum ControlCommand: Equatable, Sendable {
    case status
    case models
    /// `model`: a request name, folder name or path (nil: the selected one).
    case start(model: String?)
    case stop
    /// A chat model by Hugging Face repo, "org/name".
    case pull(repo: String)
    case image(ImageRequest)

    public struct ImageRequest: Equatable, Sendable {
        public var prompt: String
        public var width: Int?
        public var height: Int?
        /// An image model's id (`gptqMixed`, `klein4b`, ...); nil: the profile's.
        public var model: String?

        public init(prompt: String, width: Int? = nil, height: Int? = nil, model: String? = nil) {
            self.prompt = prompt
            self.width = width
            self.height = height
            self.model = model
        }
    }

    /// The `cmd` on the wire.
    public var name: String {
        switch self {
        case .status: return "status"
        case .models: return "models"
        case .start: return "start"
        case .stop: return "stop"
        case .pull: return "pull"
        case .image: return "image"
        }
    }

    public static let names = ["status", "models", "start", "stop", "pull", "image"]
}

public enum ControlRequestError: Error, Equatable, LocalizedError {
    /// Not a JSON object, or a field of the wrong type.
    case malformed
    case missingVersion
    /// A request from a newer protocol than this app speaks.
    case unsupportedVersion(Int)
    case unknownCommand(String)
    case missingField(command: String, field: String)

    public var errorDescription: String? {
        switch self {
        case .malformed:
            return "malformed request: expected one JSON object per line, like {\"v\":\(ControlProtocol.version),\"cmd\":\"status\"}"
        case .missingVersion:
            return "malformed request: no protocol version (\"v\")"
        case .unsupportedVersion(let v):
            return "this LLMTray speaks control protocol \(ControlProtocol.version), the request is version \(v): update LLMTray"
        case .unknownCommand(let cmd):
            return "unknown command \"\(cmd)\" (known: \(ControlCommand.names.joined(separator: ", ")))"
        case .missingField(let command, let field):
            return "\(command): \"\(field)\" is required"
        }
    }
}

/// One request line: the protocol version and the command, its fields
/// flat beside `cmd`.
public struct ControlRequest: Equatable, Sendable, Codable {
    public var version: Int
    public var command: ControlCommand

    public init(_ command: ControlCommand, version: Int = ControlProtocol.version) {
        self.version = version
        self.command = command
    }

    private enum CodingKeys: String, CodingKey {
        case v, cmd, model, repo, prompt, width, height
    }

    public init(from decoder: Decoder) throws {
        // A JSON array or a bare value isn't a request at all.
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { throw ControlRequestError.malformed }
        func field<T: Decodable>(_ type: T.Type, _ key: CodingKeys) throws -> T? {
            do { return try c.decodeIfPresent(type, forKey: key) } catch { throw ControlRequestError.malformed }
        }
        guard let v = try field(Int.self, .v) else { throw ControlRequestError.missingVersion }
        // Older versions don't exist yet; a newer one may mean something
        // this app would get wrong.
        guard (1...ControlProtocol.version).contains(v) else { throw ControlRequestError.unsupportedVersion(v) }
        version = v
        guard let cmd = try field(String.self, .cmd) else { throw ControlRequestError.missingField(command: "request", field: "cmd") }
        func required(_ key: CodingKeys) throws -> String {
            guard let value = try field(String.self, key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ControlRequestError.missingField(command: cmd, field: key.rawValue)
            }
            return value
        }
        switch cmd {
        case "status": command = .status
        case "models": command = .models
        case "start": command = .start(model: try field(String.self, .model).flatMap { $0.isEmpty ? nil : $0 })
        case "stop": command = .stop
        case "pull": command = .pull(repo: try required(.repo))
        case "image":
            command = .image(.init(prompt: try required(.prompt), width: try field(Int.self, .width),
                                   height: try field(Int.self, .height), model: try field(String.self, .model)))
        default: throw ControlRequestError.unknownCommand(cmd)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .v)
        try c.encode(command.name, forKey: .cmd)
        switch command {
        case .status, .models, .stop: break
        case .start(let model): try c.encodeIfPresent(model, forKey: .model)
        case .pull(let repo): try c.encode(repo, forKey: .repo)
        case .image(let image):
            try c.encode(image.prompt, forKey: .prompt)
            try c.encodeIfPresent(image.width, forKey: .width)
            try c.encodeIfPresent(image.height, forKey: .height)
            try c.encodeIfPresent(image.model, forKey: .model)
        }
    }
}

// MARK: - Replies

/// The server as `status` reports it.
public struct ControlStatus: Codable, Equatable, Sendable {
    /// stopped / starting / running / failed; a newer app's other value
    /// reads as itself (String-backed, not an enum that would fail to decode).
    public var state: String
    /// Why it failed.
    public var message: String?
    /// The loaded model's request name and path (nil: none).
    public var model: String?
    public var modelPath: String?
    /// The model Start would load.
    public var selectedModel: String?
    /// The API port: the running one, else the configured one.
    public var port: Int
    /// The model was unloaded for idleness; the next request reloads it.
    public var idleUnloaded: Bool
    public var appVersion: String
    /// "http://127.0.0.1:<port>/v1".
    public var baseURL: String
    /// AppRequestToken's header and value: the CLI's chat requests count as
    /// the app's own (no model-switch prompt for the user's own terminal).
    public var appTokenHeader: String
    public var appToken: String

    public init(state: String, message: String? = nil, model: String? = nil, modelPath: String? = nil,
                selectedModel: String? = nil, port: Int, idleUnloaded: Bool, appVersion: String,
                baseURL: String, appTokenHeader: String, appToken: String) {
        self.state = state
        self.message = message
        self.model = model
        self.modelPath = modelPath
        self.selectedModel = selectedModel
        self.port = port
        self.idleUnloaded = idleUnloaded
        self.appVersion = appVersion
        self.baseURL = baseURL
        self.appTokenHeader = appTokenHeader
        self.appToken = appToken
    }

    public static let stopped = "stopped", starting = "starting", running = "running", failed = "failed"

    /// A request can be answered now or reloads the model by itself.
    public var canAnswer: Bool { state == Self.running || idleUnloaded }

    public static func baseURL(port: Int) -> String { "http://127.0.0.1:\(port)/v1" }
}

/// One installed chat model, as `models` lists it.
public struct ControlModel: Codable, Equatable, Sendable {
    public var path: String
    /// The `model` name requests use (its alias, or its folder name).
    public var name: String
    /// "publisher/model".
    public var displayName: String
    /// On disk; nil until the app has measured it.
    public var sizeBytes: Int64?
    public var selected: Bool
    public var loaded: Bool

    public init(path: String, name: String, displayName: String, sizeBytes: Int64? = nil, selected: Bool, loaded: Bool) {
        self.path = path
        self.name = name
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.selected = selected
        self.loaded = loaded
    }
}

/// One reply line. Which fields are set says what it is: `event` (more
/// lines follow), `done` or `error` (the last line).
public struct ControlReply: Codable, Equatable, Sendable {
    public var done: Bool?
    public var error: String?
    /// One of the `Event` names; another (a newer app's) is passed over.
    public var event: String?
    public var status: ControlStatus?
    public var models: [ControlModel]?
    /// A state event's state (ControlStatus' values), a done line's summary.
    public var state: String?
    public var message: String?
    /// 0...1 when known.
    public var progress: Double?
    /// Generations ahead in the queue.
    public var position: Int?
    /// The PNG, base64.
    public var image: String?
    /// A model's path (pull: where it landed).
    public var path: String?

    public init(done: Bool? = nil, error: String? = nil, event: String? = nil, status: ControlStatus? = nil,
                models: [ControlModel]? = nil, state: String? = nil, message: String? = nil, progress: Double? = nil,
                position: Int? = nil, image: String? = nil, path: String? = nil) {
        self.done = done
        self.error = error
        self.event = event
        self.status = status
        self.models = models
        self.state = state
        self.message = message
        self.progress = progress
        self.position = position
        self.image = image
        self.path = path
    }

    public enum Event {
        /// The server's state changed (`state`, `message`).
        public static let state = "state"
        /// A download or generation moved on (`progress`, `message`).
        public static let progress = "progress"
        /// Waiting for the generator (`position`).
        public static let queued = "queued"
    }

    /// No more lines follow.
    public var isFinal: Bool { done == true || error != nil }

    public static func failure(_ message: String) -> ControlReply { ControlReply(error: message) }
}

/// Splits a byte stream into lines, at most `maxLineBytes` each (the
/// newline not counted): a peer that never sends one can't grow the buffer
/// without bound.
public struct ControlLineBuffer {
    public struct LineTooLong: Error, Equatable {}

    private var pending = Data()
    public let maxLineBytes: Int

    public init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    /// The complete lines in what has arrived so far (a trailing "\r" and
    /// empty lines dropped); the rest waits for more.
    public mutating func append(_ data: Data) throws -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<newline]
            pending = Data(pending[pending.index(after: newline)...])
            guard line.count <= maxLineBytes else { throw LineTooLong() }
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
        }
        guard pending.count <= maxLineBytes else { throw LineTooLong() }
        return lines
    }

    /// Bytes received after the last newline.
    public var hasPartialLine: Bool { !pending.isEmpty }
}

// MARK: - Helpers both sides use

/// A Hugging Face model repo as `pull` takes it: "org/name", each part
/// letters, digits, "-", "_", "." (not starting with "." nor "..") -- what
/// the Hub allows, and nothing that could walk out of the models folder.
public enum HubRepoName {
    public static func isValid(_ repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 96 && !part.hasPrefix(".")
                && part.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-_.".unicodeScalars.contains($0) }
        }
    }
}

/// What `start` does, given where the server is (adr/0019 §3): the same
/// choices the tray makes for Start and for picking a model.
public enum ControlStartPlan: Equatable, Sendable {
    /// Already running this model.
    case alreadyRunning
    /// Stopped or failed: the tray's Start, with the (now) selected model.
    case start
    /// Running another model, or idle-unloaded: loaded as picking it does
    /// (ServerManager.switchLoadedModel -- one transition, requests drained).
    case load
    /// Starting: wait for the outcome, then decide again.
    case wait
    case refuse(String)

    /// `suspendedForMedia`: unloaded for an image, a song or Voice Lab --
    /// it comes back by itself, and a start now would load it next to them.
    public static func decide(_ availability: OperationAvailability, suspendedForMedia: Bool,
                              loaded: String?, target: String) -> ControlStartPlan {
        if suspendedForMedia {
            return .refuse("the model is unloaded while an image, music or Voice Lab runs -- it comes back when that's done")
        }
        switch availability.snapshot.server {
        case .starting: return .wait
        case .stopped, .failed: return .start
        case .idleUnloaded: return .load
        case .running:
            if loaded == target { return .alreadyRunning }
            guard availability.canSwitchModel else {
                return .refuse("auto-tune is running -- switch models once it's done")
            }
            return .load
        }
    }
}
