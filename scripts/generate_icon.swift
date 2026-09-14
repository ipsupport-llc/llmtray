#!/usr/bin/env swift
// Generates Resources/AppIcon.icns: a brain glyph on a rounded, gradient
// square -- run once at dev time (not part of the build), check the
// resulting .icns into the repo like any other asset.
import AppKit

let sizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]
let iconsetDir = "/tmp/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try! FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

func renderIcon(size: Int) -> NSImage {
    let canvas = NSImage(size: NSSize(width: size, height: size))
    canvas.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = CGFloat(size) * 0.22
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.14, green: 0.44, blue: 0.28, alpha: 1.0),
        NSColor(calibratedRed: 0.05, green: 0.22, blue: 0.15, alpha: 1.0),
    ])
    gradient?.draw(in: path, angle: -90)

    // Chaining two separate withSymbolConfiguration calls replaces the
    // config rather than merging it -- the second (color-only) call was
    // silently resetting point size back to the tiny system default.
    // .applying(_:) actually merges size + color into one configuration.
    let combinedConfig = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.56, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "brain.head.profile.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(combinedConfig) {
        let symSize = symbol.size
        let origin = NSPoint(x: (CGFloat(size) - symSize.width) / 2, y: (CGFloat(size) - symSize.height) / 2)
        symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    canvas.unlockFocus()
    return canvas
}

func writePNG(_ image: NSImage, size: Int, to path: String) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("failed to encode PNG at size \(size)")
    }
    try! png.write(to: URL(fileURLWithPath: path))
}

for size in sizes {
    let img = renderIcon(size: size)
    writePNG(img, size: size, to: "\(iconsetDir)/icon_\(size)x\(size).png")
    if size <= 512 {
        let img2x = renderIcon(size: size * 2)
        writePNG(img2x, size: size * 2, to: "\(iconsetDir)/icon_\(size)x\(size)@2x.png")
    }
}

print("iconset written to \(iconsetDir)")
