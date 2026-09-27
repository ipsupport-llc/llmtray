import Foundation
import LLMTrayCore

/// The `generate_music` tool: a song (sung lyrics) or an instrumental from a
/// style description, through ACE-Step 1.5 (MusicManager). One per user
/// turn, like images.
@MainActor
final class MusicToolRunner: ChatTool {
    static let toolName = "generate_music"
    let name = MusicToolRunner.toolName
    let music: MusicManager

    init(music: MusicManager) {
        self.music = music
    }

    static let schema = ToolSchema(toolName, "Compose music with a local model: a song with sung lyrics, or an instrumental. "
                                   + "Only when the latest message asks for music (song, track, beat, jingle, melody); never for "
                                   + "greetings, small talk or questions about music.", [
        .init("prompt", .string, "Style in English: genre, mood, tempo, instruments, voice.", required: true,
              aliases: ["style", "description", "caption", "tags", "genre"]),
        .init("lyrics", .string, "Lines with [Verse]/[Chorus] markers; write them if the user gave none. Empty = instrumental.",
              aliases: ["words", "text", "song_lyrics"]),
        .init("duration", .integer, "Seconds, 10-120, default 30.", aliases: ["seconds", "length", "duration_seconds"]),
        .init("language", .string, "Lyrics language code, default en.", aliases: ["lang", "lyrics_language"]),
        .init("creativity", .number, "0-1; omit for the user's setting.", aliases: ["temperature"]),
        .init("adherence", .number, "0-1, how closely to follow the style; omit for the user's setting.", aliases: ["guidance"]),
    ])
    var schema: ToolSchema? { Self.schema }
    var definition: [String: Any] { Self.schema.definition }

    private(set) var songsThisTurn = 0
    let maxSongsPerTurn = 1

    func startTurn() {
        songsThisTurn = 0
    }

    /// This round will actually run the generator (see ImageToolRunner's).
    /// A call with no style to make is refused without the chat model's
    /// unload/reload (nor is one while the model isn't installed: see ChatClient).
    func willGenerate(_ calls: [ToolCall], settings: ChatSettings) -> Bool {
        calls.contains { $0.name == Self.toolName && !Self.prompt(ChatToolbox.parseArguments($0.argumentsJSON)).isEmpty }
            && songsThisTurn < maxSongsPerTurn && settings.enableMusicGeneration
    }

    static func prompt(_ arguments: [String: Any]) -> String {
        String(((arguments["prompt"] as? String) ?? "").prefix(1000)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isOffered(_ settings: ChatSettings) -> Bool {
        settings.enableMusicGeneration
    }

    /// Model-supplied: clamped (and a missing or odd value is 30 s).
    static func duration(_ value: Any?) -> Int {
        min(max((value as? Int) ?? 30, 10), 120)
    }

    /// A model-supplied 0...1 value, or nil.
    static func unit(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else { return nil }
        return min(max(number, 0), 1)
    }

    /// A language code the model gave, or "en": two or three letters only.
    static func language(_ value: Any?) -> String {
        let code = ((value as? String) ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        return code.range(of: #"^[a-z]{2,3}$"#, options: .regularExpression) != nil ? code : "en"
    }

    func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        guard context.settings.enableMusicGeneration else {
            return .text(
                "Music generation is turned off in LLMTray's settings, so no music was made. Do not call "
                    + "generate_music; answer in text, and if the user wants music, tell them to enable music generation in settings first."
            )
        }
        guard songsThisTurn < maxSongsPerTurn else {
            return .refused(
                "Not making another piece -- one was already made for this request and shown to the user. Do not call "
                    + "generate_music again unless the user sends a new message asking for different music."
            )
        }
        let prompt = Self.prompt(arguments)
        guard !prompt.isEmpty else {
            return .text("Describe the style in `prompt` (genre, mood, instruments, voice).")
        }
        let lyrics = String(((arguments["lyrics"] as? String) ?? "").prefix(4000))
        let duration = Self.duration(arguments["duration"])
        do {
            let start = Date()
            let settings = context.settings
            let song = try await music.generate(
                caption: prompt, lyrics: lyrics, duration: duration, language: Self.language(arguments["language"]),
                model: settings.musicModel,
                creativity: Self.unit(arguments["creativity"]) ?? settings.musicCreativity,
                adherence: Self.unit(arguments["adherence"]) ?? settings.musicAdherence,
                bitrate: settings.musicBitrate
            )
            let audio = song.audio
            songsThisTurn += 1
            return .generatedAudio(
                audio, seconds: Date().timeIntervalSince(start), prompt: prompt,
                text: "Music generated (\(duration) s\(lyrics.isEmpty ? ", instrumental" : ", with the lyrics sung")) and already "
                    + "shown to the user as a player directly above your reply. You can't hear it. Do not write links, "
                    + "markdown or placeholders for it. Reply briefly in plain text (e.g. what you asked for), or say nothing "
                    + "else. Do not call generate_music again for this request unless the user asks for different music."
            )
        } catch {
            return .text("Music generation failed: \(error.localizedDescription)")
        }
    }
}
