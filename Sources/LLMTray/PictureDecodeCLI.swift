import Foundation
import LLMTrayCore

/// `LLMTray --decode-picture <in> --out <dir> --side <px> [--thumb <px>]
/// [--parent <pid>]` (see LLMTrayApp.init): decodes one untrusted picture
/// (adr/0020, "Project pictures") in a child supervised like extraction --
/// a hostile HEIC or TIFF can hang or blow up only this. Writes
/// `picture.jpg` or `picture.png` (and `thumb.png`) into `<dir>`, which the
/// app made fresh, and prints one JSON line.
enum PictureDecodeCLI {
    static func run(arguments: [String]) -> Never {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        guard let input = value("--decode-picture"), let out = value("--out"), let side = value("--side").flatMap(Int.init),
              side > 0, side <= 4096 else {
            FileHandle.standardError.write(Data("usage: LLMTray --decode-picture <in> --out <dir> --side <px> [--thumb <px>]\n".utf8))
            exit(64)
        }
        ExtractorCLI.exitWithParent(expected: value("--parent").flatMap { pid_t($0) })
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        switch PictureDecoder.decode(URL(fileURLWithPath: input), side: side, thumbnailSide: value("--thumb").flatMap(Int.init)) {
        case .success(let d):
            do {
                try d.data.write(to: dir.appendingPathComponent(d.isJPEG ? "picture.jpg" : "picture.png"), options: .withoutOverwriting)
                if let thumb = d.thumbnail { try thumb.write(to: dir.appendingPathComponent("thumb.png"), options: .withoutOverwriting) }
            } catch {
                say(["error": "write"]); exit(1)
            }
            say(["width": d.width, "height": d.height, "jpeg": d.isJPEG])
            exit(0)
        case .failure(.notAPicture): say(["error": "not a picture"]); exit(1)
        case .failure(.tooManyPixels(let mp)): say(["error": "over \(ProjectPictures.maxMegapixels) megapixels (\(mp))"]); exit(1)
        case .failure(.cantDecode): say(["error": "can't be decoded"]); exit(1)
        }
    }

    static func say(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object) { print(String(decoding: data, as: UTF8.self)) }
    }
}

/// The parent side: a fresh folder, the child (10 s, 1 GB, 4 KB of
/// stdout), the outputs read back (at most 16 MB), the folder deleted.
enum PictureDecoding {
    struct Result: Sendable {
        var width: Int
        var height: Int
        var data: Data
        var isJPEG: Bool
        var thumbnail: Data?
    }

    static func decode(_ url: URL, side: Int, thumbnailSide: Int? = nil) async -> Swift.Result<Result, PictureDecodeError> {
        guard let executable = Bundle.main.executablePath else { return .failure(.failed("no executable")) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("llmtray-picture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil else {
            return .failure(.failed("no folder"))
        }
        var args = ["--decode-picture", url.path, "--out", dir.path, "--side", String(side), "--parent", String(getpid())]
        if let thumbnailSide { args += ["--thumb", String(thumbnailSide)] }
        let line = DocumentRenderer.LineBox()
        let supervision = ProcessRunner.Supervision(timeout: 10, maxStdoutBytes: 4096,
                                                    maxFootprintBytes: 1024 * 1024 * 1024, jetsamLimitBytes: 1024 * 1024 * 1024)
        guard let exit = try? await ProcessRunner.runSupervised(executable, args, supervision: supervision, onLine: { line.set($0); return true }) else {
            return .failure(.failed("not started"))
        }
        if let limit = exit.limit { return .failure(.failed(limit == .timeout ? "took over 10 s" : limit.rawValue)) }
        guard let data = line.value.data(using: .utf8), let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.failed("no answer"))
        }
        if let error = answer["error"] as? String { return .failure(error == "not a picture" ? .notAPicture : .failed(error)) }
        guard let w = answer["width"] as? Int, let h = answer["height"] as? Int, let jpeg = answer["jpeg"] as? Bool else {
            return .failure(.failed("no size"))
        }
        func read(_ name: String) -> Data? {
            let u = dir.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? Int.max
            return size <= 16 * 1024 * 1024 ? try? Data(contentsOf: u) : nil
        }
        guard let picture = read(jpeg ? "picture.jpg" : "picture.png") else { return .failure(.failed("no picture")) }
        return .success(Result(width: w, height: h, data: picture, isJPEG: jpeg, thumbnail: read("thumb.png")))
    }
}

enum PictureDecodeError: Error, Equatable {
    case notAPicture
    case failed(String)
}
