import Foundation

/// What ⌘V in the chat's field takes from the clipboard (ChatComposer):
/// the field itself pastes only text.
public enum ClipboardImages {
    public enum Source: Equatable { case files, imageData, text }

    /// Image files copied in Finder win (their names come along as text);
    /// image data (a screenshot, Copy Image) when there's no text with it,
    /// or only its address (Safari's Copy Image adds the image's URL as
    /// text). A rich copy of text with a picture still pastes its text.
    public static func source(imageFiles: Int, text: String?, hasImageData: Bool) -> Source {
        if imageFiles > 0 { return .files }
        guard hasImageData else { return .text }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .imageData }
        return isBareURL(text) ? .imageData : .text
    }

    /// One web or data address and nothing else.
    static func isBareURL(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where: \.isWhitespace), let url = URL(string: t),
              let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "data"].contains(scheme)
    }

    /// ⌘V on any layout: the "v" character, or the V key when the layout
    /// types something else there (Cyrillic, Greek ...). A layout with a
    /// Latin "v" elsewhere (Dvorak) is matched by the character.
    public static func isPasteKey(characters: String?, keyCode: UInt16) -> Bool {
        guard let c = characters?.lowercased() else { return false }
        if c == "v" { return true }
        let latin = c.unicodeScalars.allSatisfy { $0.isASCII }
        return keyCode == 9 && !latin   // kVK_ANSI_V
    }
}
