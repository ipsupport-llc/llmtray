import Foundation

/// What ⌘V in the chat's field takes from the clipboard (ChatComposer):
/// the field itself pastes only text.
public enum ClipboardImages {
    public enum Source: Equatable { case files, imageData, text }

    /// Image files copied in Finder win (their names come along as text);
    /// image data (a screenshot, Copy Image) only without text, so a rich
    /// copy of text with a picture still pastes its text.
    public static func source(imageFiles: Int, hasText: Bool, hasImageData: Bool) -> Source {
        if imageFiles > 0 { return .files }
        if hasImageData && !hasText { return .imageData }
        return .text
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
