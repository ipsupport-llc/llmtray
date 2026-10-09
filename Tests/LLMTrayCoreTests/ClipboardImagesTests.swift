import XCTest
@testable import LLMTrayCore

final class ClipboardImagesTests: XCTestCase {
    func testSource() {
        // Finder copy of an image file: the file, though its name is text too.
        XCTAssertEqual(ClipboardImages.source(imageFiles: 1, hasText: true, hasImageData: true), .files)
        // A screenshot to the clipboard, Copy Image in a browser.
        XCTAssertEqual(ClipboardImages.source(imageFiles: 0, hasText: false, hasImageData: true), .imageData)
        // Text with a picture (a rich copy): its text.
        XCTAssertEqual(ClipboardImages.source(imageFiles: 0, hasText: true, hasImageData: true), .text)
        XCTAssertEqual(ClipboardImages.source(imageFiles: 0, hasText: true, hasImageData: false), .text)
        XCTAssertEqual(ClipboardImages.source(imageFiles: 0, hasText: false, hasImageData: false), .text)
    }

    func testPasteKey() {
        XCTAssertTrue(ClipboardImages.isPasteKey(characters: "v", keyCode: 9))
        XCTAssertTrue(ClipboardImages.isPasteKey(characters: "V", keyCode: 9))
        // Russian layout: the V key types "м".
        XCTAssertTrue(ClipboardImages.isPasteKey(characters: "м", keyCode: 9))
        // Dvorak: "v" is on another key, the V key types "k".
        XCTAssertTrue(ClipboardImages.isPasteKey(characters: "v", keyCode: 47))
        XCTAssertFalse(ClipboardImages.isPasteKey(characters: "k", keyCode: 9))
        XCTAssertFalse(ClipboardImages.isPasteKey(characters: "c", keyCode: 8))
        XCTAssertFalse(ClipboardImages.isPasteKey(characters: nil, keyCode: 9))
    }
}
