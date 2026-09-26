import AppKit
import LLMTrayCore
import SwiftUI
import UniformTypeIdentifiers

/// Copy and Share for what the chat made: an answer's text, an image, a
/// song. Share hands a file named after the prompt to the system's share
/// sheet (AirDrop, Messages, Mail, ...); the file is written only then, in
/// the temporary folder, as the user asked to send it out (like Save…).
enum MediaSharing {
    static func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// A song sent out as .m4a: a WAV from before is encoded first.
    static func m4a(_ data: Data) -> Data {
        AudioCodec.format(of: data) == .m4a ? data : (try? AudioCodec.m4a(from: data)) ?? data
    }

    /// The song as a file (Finder, Messages, a DAW paste it) and as data.
    static func copyAudio(_ data: Data, prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let audio = m4a(data)
        let format = AudioCodec.format(of: audio)
        item.setData(audio, forType: NSPasteboard.PasteboardType((format == .wav ? UTType.wav : UTType.mpeg4Audio).identifier))
        if let url = try? exportFile(audio, name: fileName(prompt, fallback: "music"), ext: format.fileExtension) {
            item.setString(url.absoluteString, forType: .fileURL)
        }
        pasteboard.writeObjects([item])
    }

    /// PNG bytes: as they are, or re-encoded (a streamed answer's image
    /// can be a JPEG).
    static func png(_ data: Data) -> Data {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
    }

    /// From the prompt, like Save…'s (ImageActions.slugify, which is
    /// main-actor: the share sheet asks for the file off it).
    static func fileName(_ prompt: String, fallback: String) -> String {
        let slug = prompt.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let name = String(String(slug).split(separator: "-").joined(separator: "-").prefix(48))
        return name.isEmpty ? fallback : name
    }

    /// A fresh folder each time: two shares of same-named clips don't clash.
    /// Earlier exports are removed once they're a day old (a copied song's
    /// file must outlive the paste).
    static func exportFile(_ data: Data, name: String, ext: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LLMTray-share", isDirectory: true)
        let old = Date().addingTimeInterval(-86_400)
        for dir in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if let created = try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate, created < old {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name).appendingPathExtension(ext)
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// A generated image for the share sheet: the PNG itself, not a re-encode.
struct SharedImage: Transferable {
    let data: Data
    let prompt: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { image in
            SentTransferredFile(try MediaSharing.exportFile(MediaSharing.png(image.data), name: MediaSharing.fileName(image.prompt, fallback: "image"), ext: "png"))
        }
    }
}

/// A generated song for the share sheet.
struct SharedAudio: Transferable {
    let data: Data
    let prompt: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Audio) { clip in
            // An old WAV that won't encode fails the share rather than go out mislabelled.
            let audio = AudioCodec.format(of: clip.data) == .m4a ? clip.data : try AudioCodec.m4a(from: clip.data)
            return SentTransferredFile(try MediaSharing.exportFile(audio, name: MediaSharing.fileName(clip.prompt, fallback: "music"), ext: "m4a"))
        }
    }
}
