import Foundation

/// Kaggle Models as a second place to download models from (adr/0032): its
/// public API (www.kaggle.com/api/v1), read without an account; a token only
/// for gated or private models. Here: the API's shapes and URLs, the mirror
/// of our own Hugging Face releases, and which source a download uses. The
/// downloads themselves are the app's.
public enum Kaggle {
    public static let host = "www.kaggle.com"
    static let api = "https://www.kaggle.com/api/v1"

    /// One model variation on Kaggle: owner/model/framework/variation (the
    /// API's "instance"), each with numbered versions.
    public struct Handle: Hashable, Codable, Sendable {
        public var owner: String
        public var model: String
        public var framework: String
        public var variation: String

        public init(owner: String, model: String, framework: String, variation: String) {
            self.owner = owner
            self.model = model
            self.framework = framework
            self.variation = variation
        }

        /// "owner/model/framework/variation", as kaggle.com writes it (a
        /// trailing "/<version>" is ignored).
        public init?(_ text: String) {
            let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 || (parts.count == 5 && Int(parts[4]) != nil),
                  parts.prefix(4).allSatisfy({ !$0.isEmpty && Kaggle.isSlug($0) }) else { return nil }
            self.init(owner: parts[0], model: parts[1], framework: parts[2], variation: parts[3])
        }

        public var path: String { "\(owner)/\(model)/\(framework)/\(variation)" }

        /// The model's page on kaggle.com.
        public var pageURL: URL? { URL(string: "https://www.kaggle.com/models/\(path)") }

        /// Its folder under the models folder: the Hugging Face repo it
        /// mirrors (so it is the same model to LLMTray, wherever it came
        /// from), else "<owner>/<model>-<variation>".
        public var folderID: String {
            Mirror.hubRepo(for: self) ?? "\(owner)/\(model)-\(variation)"
        }
    }

    /// Letters, digits, '-', '_' and '.': what Kaggle allows in a slug, and
    /// all that may go into a URL path or a folder name here.
    static func isSlug(_ s: String) -> Bool {
        s != "." && s != ".." && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    // MARK: - URLs

    public enum Sort: String, CaseIterable, Sendable {
        case hotness, downloadCount, voteCount, publishTime
    }

    /// Model search; `owner` narrows it to one account.
    public static func searchURL(_ query: String, owner: String? = nil, sort: Sort = .hotness, pageSize: Int = 50, pageToken: String? = nil) -> URL? {
        var comps = URLComponents(string: api + "/models/list")
        var items = [URLQueryItem(name: "search", value: query), URLQueryItem(name: "sortBy", value: sort.rawValue),
                     URLQueryItem(name: "pageSize", value: String(pageSize))]
        if let owner { items.append(URLQueryItem(name: "owner", value: owner)) }
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        comps?.queryItems = items
        return comps?.url
    }

    /// A variation's details, the current version among them.
    public static func instanceURL(_ handle: Handle) -> URL? {
        URL(string: "\(api)/models/\(handle.path)/get")
    }

    /// One page of a version's files.
    public static func filesURL(_ handle: Handle, version: Int, pageToken: String? = nil) -> URL? {
        var comps = URLComponents(string: "\(api)/models/\(handle.path)/\(version)/files")
        comps?.queryItems = [URLQueryItem(name: "pageSize", value: "100")] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
        return comps?.url
    }

    /// One file of a version. Answers with a redirect to a signed storage
    /// link that takes byte ranges.
    public static func fileURL(_ handle: Handle, version: Int, path: String) -> URL? {
        let encoded = path.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "\(api)/models/\(handle.path)/\(version)/download/\(encoded)")
    }

    // MARK: - Responses

    public struct Instance: Decodable, Hashable, Sendable {
        public let slug: String
        public let framework: String
        public let versionNumber: Int?
        public let totalUncompressedBytes: Int64?
        public let licenseName: String?
        /// Its overview, Markdown (ours: the Hugging Face card).
        public let overview: String?
    }

    public struct Model: Decodable, Hashable, Sendable {
        /// "owner/model".
        public let ref: String
        public let title: String?
        public let subtitle: String?
        public let isPrivate: Bool?
        public let instances: [Instance]?
    }

    public struct ModelPage: Decodable, Sendable {
        public let models: [Model]?
        public let nextPageToken: String?
    }

    public struct File: Decodable, Hashable, Sendable {
        public let name: String
        public let size: Int64?
    }

    public struct FilePage: Decodable, Sendable {
        public let files: [File]?
        public let nextPageToken: String?
    }

    /// The API's error body: {"code":403,"message":"User has not consented to terms of use."}.
    public struct APIError: Decodable, Sendable {
        public let code: Int?
        public let message: String?
    }

    /// A search result LLMTray can download: one variation of a model.
    public struct Result: Hashable, Sendable {
        public let handle: Handle
        public let title: String
        public let version: Int?
        public let bytes: Int64?
        public let license: String?
        public let overview: String?
    }

    /// The variations in a page of models that are MLX builds -- the only
    /// kind this runtime loads (as the Hugging Face search keeps to the mlx
    /// library). Kaggle has no MLX framework: they are "other" or
    /// "transformers" variations saying MLX in their own or the model's
    /// name; our mirror's always count.
    public static func mlxResults(_ page: ModelPage) -> [Result] {
        (page.models ?? []).flatMap { model -> [Result] in
            let ref = model.ref.split(separator: "/").map(String.init)
            guard ref.count == 2 else { return [] }
            return (model.instances ?? []).compactMap { instance in
                let handle = Handle(owner: ref[0], model: ref[1], framework: instance.framework, variation: instance.slug)
                guard isSlug(handle.owner), isSlug(handle.model), isSlug(handle.framework), isSlug(handle.variation) else { return nil }
                let mirrored = Mirror.hubRepo(for: handle) != nil
                let saysMLX = [instance.slug, model.ref, model.title ?? ""].contains { $0.localizedCaseInsensitiveContains("mlx") }
                guard mirrored || (["other", "transformers"].contains(instance.framework) && saysMLX) else { return nil }
                return Result(handle: handle, title: model.title ?? model.ref, version: instance.versionNumber,
                              bytes: instance.totalUncompressedBytes, license: instance.licenseName, overview: instance.overview)
            }
        }
    }

    /// The files of a version a download wants: every one, or those matching
    /// any of `patterns` (huggingface_hub's allow_patterns: shell globs on
    /// the path, where '*' crosses '/').
    public static func select(_ files: [File], patterns: [String]?) -> [File] {
        guard let patterns, !patterns.isEmpty else { return files }
        return files.filter { file in patterns.contains { glob($0, matches: file.name) } }
    }

    /// fnmatch without FNM_PATHNAME: '*' and '?' match '/' too, as in
    /// Python's fnmatch that allow_patterns uses.
    static func glob(_ pattern: String, matches name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }

    // MARK: - Our mirror

    /// Our Hugging Face releases (roman220220) copied to Kaggle
    /// (romanromenskyi), one variation per repo: the same files, so a model
    /// from either is the same model. MLX builds only (this runtime can't
    /// load GGUF); a retired one (VoiceChat) left out.
    public enum Mirror {
        public static let owner = "romanromenskyi"

        static let table: [(hub: String, model: String, variation: String)] = [
            ("roman220220/gemma-4-26B-A4B-it-gptq-mlx-jang", "gemma-4-26b-a4b-it-ipsupport", "mlx-gptq-jang"),
            ("roman220220/gemma-4-26B-A4B-it-assistant-mlx-8bit", "gemma-4-26b-a4b-it-ipsupport", "mlx-mtp-drafter-8bit"),
            ("roman220220/gemma-4-31B-it-qat-mlx", "gemma-4-31b-it-ipsupport", "mlx-qat"),
            ("roman220220/gemma-4-12B-it-qat-mlx", "gemma-4-12b-it-ipsupport", "mlx-qat"),
            ("roman220220/gemma-4-E4B-it-qat-mlx", "gemma-4-e4b-it-ipsupport", "mlx-qat"),
            ("roman220220/gemma-4-E2B-it-qat-phone-mlx", "gemma-4-e2b-it-ipsupport", "mlx-qat-phone"),
            ("roman220220/gemma-4-E2B-it-qat-mlx", "gemma-4-e2b-it-ipsupport", "mlx-qat"),
            ("roman220220/Nemotron-3.5-Lightning-30B-A3B-JANG-GPTQ-ipsupport-code-lora", "nemotron-3-5-lightning-30b-a3b-ipsupport", "mlx-jang-gptq-code-lora"),
            ("roman220220/Nemotron-3.5-Lightning-30B-A3B-JANG-GPTQ-ipsupport-code-lora-MTP", "nemotron-3-5-lightning-30b-a3b-ipsupport", "mlx-jang-gptq-code-lora-mtp"),
            ("roman220220/nemotron-30b-a3b-gptq-jang-component", "nemotron-3-5-lightning-30b-a3b-ipsupport", "mlx-gptq-jang"),
            ("roman220220/nemotron-30b-a3b-gptq3bit-g64", "nemotron-3-5-lightning-30b-a3b-ipsupport", "mlx-gptq-3bit"),
            ("roman220220/NVIDIA-Nemotron-3-Nano-4B-JANG-GPTQ-ipsupport-code-lora", "nemotron-3-nano-4b-ipsupport", "mlx-jang-gptq-code-lora"),
            ("roman220220/flux2-klein-4b-mlx-mixed", "flux-2-klein-4b-ipsupport", "mlx-gptq-mixed"),
            ("roman220220/z-image-turbo-gptq-mlx-mixed", "z-image-turbo-ipsupport", "mlx-gptq-mixed"),
            ("roman220220/z-image-turbo-gptq-mlx-4bit", "z-image-turbo-ipsupport", "mlx-gptq-4bit"),
            ("roman220220/z-image-turbo-gptq-mlx-8bit", "z-image-turbo-ipsupport", "mlx-gptq-8bit"),
            ("roman220220/ACE-Step1.5-sft-MLX-gptq-4bit", "ace-step-1-5-sft-ipsupport", "mlx-gptq-4bit"),
            ("roman220220/ACE-Step1.5-sft-MLX-8bit", "ace-step-1-5-sft-ipsupport", "mlx-8bit"),
            ("roman220220/ACE-Step1.5-sft-MLX-bf16", "ace-step-1-5-sft-ipsupport", "mlx-bf16"),
            ("roman220220/FrogNano-4B-2609-gptq-mlx-jang", "frognano-4b-2609-ipsupport", "mlx-gptq-jang"),
            ("roman220220/Ornith-1.5-35B-A3B-gptq-mlx-jang", "ornith-1-5-35b-a3b-ipsupport", "mlx-gptq-jang"),
            ("roman220220/Ornith-1.5-35B-A3B-gptq-mlx-jang-small", "ornith-1-5-35b-a3b-ipsupport", "mlx-gptq-jang-small"),
            ("roman220220/chatterbox-multilingual-v3-mlx-8bit", "chatterbox-multilingual-v3-ipsupport", "mlx-8bit"),
            ("roman220220/Dory1.0-4B-gptq-mlx-jang", "dory-1-0-4b-ipsupport", "mlx-gptq-jang"),
            ("roman220220/Nemotron-3.5-Bolt-E4B-gptq-mlx-jang", "nemotron-3-5-bolt-e4b-ipsupport", "mlx-gptq-jang"),
        ]

        /// The Kaggle copy of a Hugging Face repo (case as the Hub ignores it).
        public static func handle(forHubRepo repo: String) -> Handle? {
            table.first { $0.hub.caseInsensitiveCompare(repo) == .orderedSame }
                .map { Handle(owner: owner, model: $0.model, framework: "other", variation: $0.variation) }
        }

        /// The Hugging Face repo a Kaggle variation copies.
        public static func hubRepo(for handle: Handle) -> String? {
            guard handle.owner == owner, handle.framework == "other" else { return nil }
            return table.first { $0.model == handle.model && $0.variation == handle.variation }?.hub
        }
    }
}

/// Where model downloads come from (Settings › Models): Hugging Face, with
/// our Kaggle mirror when Hugging Face can't be reached, or Kaggle first --
/// for networks that block huggingface.co (adr/0032).
public enum ModelDownloadSource: String, CaseIterable, Sendable {
    case automatic
    case kaggle

    /// The Kaggle copy to download `repo` from, or nil for Hugging Face.
    /// `hubReachable` is asked only when it matters (it's a request).
    public func kaggleCopy(of repo: String, hubReachable: () async -> Bool) async -> Kaggle.Handle? {
        guard let handle = Kaggle.Mirror.handle(forHubRepo: repo) else { return nil }
        switch self {
        case .kaggle: return handle
        case .automatic: return await hubReachable() ? nil : handle
        }
    }
}
