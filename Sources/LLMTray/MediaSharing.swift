import AppKit
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

    /// The WAV as a file (Finder, Messages, a DAW paste it) and as data.
    static func copyAudio(_ data: Data, prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.wav.identifier))
        if let url = try? exportFile(data, name: fileName(prompt, fallback: "music"), ext: "wav") {
            item.setString(url.absoluteString, forType: .fileURL)
        }
        pasteboard.writeObjects([item])
    }

    /// From the prompt, like Save…'s (ImageActions.slugify, which is
    /// main-actor: the share sheet asks for the file off it).
    /// PNG bytes: as they are, or re-encoded (a streamed answer's image
    /// can be a JPEG).
    static func png(_ data: Data) -> Data {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
    }

    static func fileName(_ prompt: String, fallback: String) -> String {
        let slug = prompt.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let name = String(String(slug).split(separator: "-").joined(separator: "-").prefix(48))
        return name.isEmpty ? fallback : name
    }

    /// A fresh folder each time: two shares of same-named clips don't clash.
    /// Earlier exports are removed once they're an hour old (long done
    /// being pasted or sent).
    static func exportFile(_ data: Data, name: String, ext: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LLMTray-share", isDirectory: true)
        let old = Date().addingTimeInterval(-3600)
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
        FileRepresentation(exportedContentType: .wav) { clip in
            SentTransferredFile(try MediaSharing.exportFile(clip.data, name: MediaSharing.fileName(clip.prompt, fallback: "music"), ext: "wav"))
        }
    }
}
