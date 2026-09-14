#!/usr/bin/env swift
// Generates docs/assets/og-image.png (1200x630) -- the preview card image
// social platforms / search results show when the site link is shared.
import AppKit

let size = NSSize(width: 1200, height: 630)
let canvas = NSImage(size: size)
canvas.lockFocus()

let rect = NSRect(origin: .zero, size: size)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.08, green: 0.28, blue: 0.19, alpha: 1.0),
    NSColor(calibratedRed: 0.04, green: 0.14, blue: 0.10, alpha: 1.0),
])
gradient?.draw(in: rect, angle: -60)

// Icon glyph, left side.
let iconSize: CGFloat = 220
let iconConfig = NSImage.SymbolConfiguration(pointSize: iconSize * 0.72, weight: .medium)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "brain.head.profile.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(iconConfig) {
    let origin = NSPoint(x: 90, y: (size.height - symbol.size.height) / 2)
    symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
}

func draw(_ text: String, font: NSFont, color: NSColor, at point: NSPoint) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    NSAttributedString(string: text, attributes: attrs).draw(at: point)
}

draw("LLMTray", font: .systemFont(ofSize: 84, weight: .bold), color: .white, at: NSPoint(x: 370, y: 340))
draw("Local LLMs from your macOS menu bar.", font: .systemFont(ofSize: 34, weight: .regular),
     color: NSColor(white: 1, alpha: 0.85), at: NSPoint(x: 372, y: 270))
draw("Small, fast, no bloat.", font: .systemFont(ofSize: 30, weight: .medium),
     color: NSColor(calibratedRed: 0.55, green: 0.9, blue: 0.7, alpha: 1.0), at: NSPoint(x: 372, y: 220))

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to encode PNG")
}
let outPath = "/tmp/og-image.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("written to \(outPath)")
