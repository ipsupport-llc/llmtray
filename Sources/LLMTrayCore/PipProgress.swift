import Foundation

/// What `pip install` (run without --quiet, with --progress-bar off) is
/// doing, from its output lines: a setup that takes minutes shows which
/// package it's on instead of a bare "Installing…".
public enum PipProgress {
    /// `python -m pip install <arguments>`, each step's detail handed to
    /// `report` on the main actor. Throws ProcessRunner.Failure like run().
    public static func install(_ python: String, _ arguments: [String],
                               report: @escaping @MainActor @Sendable (String) -> Void) async throws {
        // The main queue, in order: every detail is shown before this
        // returns, so none comes after the caller clears its status.
        let delivered = { await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } } }
        do {
            try await ProcessRunner.runStreaming(python, ["-m", "pip", "install", "--progress-bar", "off"] + arguments) { line in
                guard let detail = detail(for: line) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { report(detail) } }
            }
        } catch {
            await delivered()
            throw error
        }
        await delivered()
    }

    /// The detail for one line of pip's output, or nil for a line that
    /// says nothing new (metadata, requirement checks, blank lines).
    public static func detail(for line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("Collecting ") {
            let name = package(fromRequirement: String(text.dropFirst("Collecting ".count)))
            return name.isEmpty ? nil : String(format: NSLocalizedString("checking %@", comment: "pip install detail: a package being resolved"), name)
        }
        if let prefix = ["Downloading ", "Using cached ", "Resuming download "].first(where: text.hasPrefix) {
            let parts = text.dropFirst(prefix.count).split(separator: " ", maxSplits: 1).map(String.init)
            guard let file = parts.first, !file.hasSuffix(".metadata") else { return nil }
            // A wheel or sdist names its package; an archive by URL (a
            // commit's <sha>.tar.gz) doesn't.
            let name = package(fromFile: file)
            // "(34.5 MB)" after the file name; resumed: "(12.0 MB/34.5 MB)", its total.
            let size = parts.count > 1
                ? parts[1].split(separator: "(").last?.split(separator: ")").first?.split(separator: "/").last.map(String.init)
                : nil
            switch (name.isEmpty, size) {
            case (false, let size?):
                return String(format: NSLocalizedString("downloading %@ (%@)", comment: "pip install detail: a package and its size"), name, size)
            case (false, nil):
                return String(format: NSLocalizedString("downloading %@", comment: "pip install detail: a package"), name)
            case (true, let size?):
                return String(format: NSLocalizedString("downloading (%@)", comment: "pip install detail: an archive's size"), size)
            case (true, nil):
                return NSLocalizedString("downloading", comment: "pip install detail")
            }
        }
        if text.hasPrefix("Building wheel for ") {
            let name = text.dropFirst("Building wheel for ".count).split(separator: " ").first.map(String.init) ?? ""
            return name.isEmpty ? nil : String(format: NSLocalizedString("building %@", comment: "pip install detail: a package compiled"), name)
        }
        if text.hasPrefix("Installing collected packages:") {
            let count = text.dropFirst("Installing collected packages:".count).split(separator: ",").count
            return String(format: NSLocalizedString("installing %d packages", comment: "pip install detail: the final step"), count)
        }
        return nil
    }

    /// "mlx<1,>=0.29 (from mflux==0.21.0)" -> "mlx"; "mflux==0.21.0" -> "mflux".
    static func package(fromRequirement requirement: String) -> String {
        let first = requirement.split(separator: " ").first.map(String.init) ?? ""
        let end = first.firstIndex { "<>=!~;[@(".contains($0) } ?? first.endIndex
        return String(first[..<end])
    }

    /// "mlx-0.29.1-cp314-cp314-macosx_15_0_arm64.whl" -> "mlx";
    /// "hf_xet-1.6.0-...whl" -> "hf_xet"; "pkg-1.0.tar.gz" -> "pkg".
    static func package(fromFile file: String) -> String {
        let name = (file as NSString).lastPathComponent
        // A distribution's name ends where its version starts: the first
        // "-" followed by a digit.
        var previous: Character?
        for (offset, char) in name.enumerated() {
            if previous == "-", char.isNumber { return String(name.prefix(offset - 1)) }
            previous = char
        }
        return ""
    }
}
