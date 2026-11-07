import Foundation

/// Voice conversation (adr/0031): what's shared between the app and its
/// tests -- the voice-mode prompt, backchannel and filler phrases.
public enum VoiceConversationText {
    /// Joins the model's profile prompt while voice mode is on.
    public static let prompt = """
    You are in a spoken conversation: everything you write is read aloud by a voice, and the user speaks to you.
    Answer the way people talk: short, natural sentences, usually one to three of them. No lists, headings, tables, \
    code blocks, links or emoji. Spell out numbers, units and abbreviations the way they are said (for example \
    "Drive", not "Dr"). If the question is unclear, ask back briefly. Give long, detailed answers only when asked.
    You may open with a short reaction in your own words ("Hmm, look...", "Right, got it"), varied and not every time.
    Answer in the language the user speaks.
    """

    /// Short replies that mean "go on" while the model talks: they don't
    /// interrupt (lowercased, punctuation dropped).
    public static let backchannels: Set<String> = [
        "ага", "угу", "ну", "да", "да да", "ага ага", "угу угу", "так", "понятно", "ясно", "хорошо", "окей", "ок", "м", "мм", "хм",
        "uh huh", "mhm", "mm", "mm hmm", "yeah", "yes", "yep", "right", "ok", "okay", "i see", "sure", "got it", "hmm",
    ]

    /// A turn heard while the model talks is a backchannel when it's one of
    /// those, or at most two short words that are.
    public static func isBackchannel(_ text: String) -> Bool {
        let words = text.lowercased().replacingOccurrences(of: #"[^\p{L}\s]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.count <= 3 else { return false }
        return backchannels.contains(words.joined(separator: " "))
            || words.allSatisfy { backchannels.contains($0) }
    }

    /// What the microphone heard is the model's own voice coming back
    /// past echo cancellation (adr/0031): echo is a stretch of what was
    /// played, so a heard word counts when it and a neighbour come in the
    /// same order there. At least 80% of the words have to; a single word
    /// has to be there itself. Words compare by their first five letters
    /// (the recognizer gets endings wrong).
    public static func isEcho(_ text: String, of spoken: [String]) -> Bool {
        let heard = words(text).map(stem)
        guard !heard.isEmpty else { return false }
        let played = spoken.map { words($0).map(stem) }
        let singles = Set(played.joined())
        guard !singles.isEmpty else { return false }
        if heard.count == 1 { return singles.contains(heard[0]) }
        var pairs = Set<String>()
        for line in played where line.count > 1 {
            for i in 1..<line.count { pairs.insert(line[i - 1] + " " + line[i]) }
        }
        var covered = [Bool](repeating: false, count: heard.count)
        for i in 1..<heard.count where pairs.contains(heard[i - 1] + " " + heard[i]) {
            covered[i - 1] = true
            covered[i] = true
        }
        return Double(covered.filter { $0 }.count) >= 0.8 * Double(heard.count)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func stem(_ word: String) -> String { String(word.prefix(5)) }

    /// Fillers for a pause (the model is thinking), per language.
    public static func thinking(_ language: String) -> [String] {
        switch language {
        case "ru": return ["Хм…", "Сейчас подумаю.", "Секунду.", "Так, дай подумать.", "Минутку."]
        case "uk": return ["Хм…", "Секунду.", "Зараз подумаю."]
        case "de": return ["Hm…", "Moment.", "Einen Augenblick."]
        case "es": return ["Mmm…", "Un momento.", "Déjame pensar."]
        case "fr": return ["Hmm…", "Un instant.", "Laisse-moi réfléchir."]
        default: return ["Hmm…", "One moment.", "Let me think.", "Just a second."]
        }
    }

    /// The kind of a built-in tool, for its filler; nil: a general one.
    public enum ToolKind: String, CaseIterable, Sendable { case files, search, image, music, mail, calendar, web, memory, general }

    public static func toolKind(_ name: String) -> ToolKind {
        let n = name.lowercased()
        if n.contains("image") || n.contains("draw") { return .image }
        if n.contains("music") || n.contains("song") { return .music }
        if n.contains("mail") || n.contains("message") { return .mail }
        if n.contains("calendar") || n.contains("event") { return .calendar }
        if n.contains("memory") || n.contains("remember") { return .memory }
        if n.contains("web") || n.contains("fetch") || n.contains("browse") || n.contains("url") { return .web }
        if n.contains("search") || n.contains("find") { return .search }
        if n.contains("file") || n.contains("folder") || n.contains("read") || n.contains("project") { return .files }
        return .general
    }

    public static func tool(_ kind: ToolKind, _ language: String) -> String {
        let ru = language == "ru"
        switch kind {
        case .files: return ru ? "Гляну в файлах." : "Let me check the files."
        case .search: return ru ? "Сейчас поищу." : "Let me look that up."
        case .image: return ru ? "Сейчас нарисую." : "Drawing it now."
        case .music: return ru ? "Сейчас сочиню." : "Making it now."
        case .mail: return ru ? "Гляну в почте." : "Checking your mail."
        case .calendar: return ru ? "Гляну в календаре." : "Checking your calendar."
        case .web: return ru ? "Сейчас открою." : "Opening it now."
        case .memory: return ru ? "Запомню." : "Noting that."
        case .general: return ru ? "Секунду, сейчас посмотрю." : "One moment, let me check."
        }
    }

    /// Every filler of a language, for the pool made in the silences.
    public static func allFillers(_ language: String) -> [String] {
        let tools = ToolKind.allCases.map { tool($0, language) }
        return thinking(language) + tools
    }
}

/// The recognizer a voice conversation uses (adr/0031): the user picks.
public enum VoiceRecognizer: String, CaseIterable, Sendable {
    /// Parakeet TDT 0.6B v3 through mlx-audio, 8-bit at load (default).
    case parakeet
    /// Whisper large-v3-turbo through mlx-audio.
    case whisper
    /// macOS's own recognizer, on-device only (needs Dictation on, and a
    /// language with on-device support).
    case apple
}

/// One download a voice conversation needs, into the models folder under
/// its repo's name (adr/0031).
public struct VoiceInputFile: Hashable, Sendable {
    public var repo: String
    public var name: String
    public var patterns: [String]?
    /// A second repo's files into the same folder (Whisper's tokenizer).
    public var extraRepo: String?
    public var extraPatterns: [String]?
    public var downloadBytes: Int64
    public var license: String
    /// Present once the folder is complete.
    public var marker: String

    /// Silero VAD v6 (MIT): where speech starts and stops.
    public static let vad = VoiceInputFile(
        repo: "mlx-community/silero-vad-v6", name: "Silero VAD v6", patterns: ["config.json", "model.safetensors"],
        downloadBytes: 1_200_000, license: "MIT", marker: "model.safetensors")
    /// Smart Turn v3 (BSD-2-Clause, pipecat-ai): whether a pause ends the turn.
    public static let turn = VoiceInputFile(
        repo: "mlx-community/smart-turn-v3", name: "Smart Turn v3", patterns: ["config.json", "model.safetensors"],
        downloadBytes: 32_010_367, license: "BSD-2-Clause", marker: "model.safetensors")
    /// Parakeet TDT 0.6B v3 (CC BY 4.0, NVIDIA): 25 European languages;
    /// quantized to 8 bits when loaded (same words on the test set).
    public static let parakeet = VoiceInputFile(
        repo: "mlx-community/parakeet-tdt-0.6b-v3", name: "Parakeet TDT 0.6B v3",
        patterns: ["config.json", "model.safetensors", "tokenizer.model", "tokenizer.vocab", "vocab.txt"],
        downloadBytes: 2_509_041_541, license: "CC BY 4.0", marker: "model.safetensors")
    /// Whisper large-v3-turbo (MIT, OpenAI): 99 languages, slower.
    public static let whisper = VoiceInputFile(
        repo: "mlx-community/whisper-large-v3-turbo", name: "Whisper large-v3-turbo",
        patterns: ["config.json", "weights.safetensors"],
        extraRepo: "openai/whisper-large-v3-turbo",
        extraPatterns: ["added_tokens.json", "merges.txt", "normalizer.json", "preprocessor_config.json", "special_tokens_map.json",
                        "tokenizer.json", "tokenizer_config.json", "vocab.json", "generation_config.json"],
        downloadBytes: 1_613_977_880 + 4_617_219, license: "MIT", marker: "tokenizer.json")

    public static let all: [VoiceInputFile] = [vad, turn, parakeet, whisper]

    /// What a recognizer needs, turn-taking included.
    public static func needed(for recognizer: VoiceRecognizer) -> [VoiceInputFile] {
        switch recognizer {
        case .parakeet: return [vad, turn, parakeet]
        case .whisper: return [vad, turn, whisper]
        case .apple: return [vad, turn]
        }
    }
}
