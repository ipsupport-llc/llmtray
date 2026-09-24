#!/usr/bin/env swift
// Generates LLMTray's artwork from one original glyph (drawn here with
// plain Bezier paths -- no SF Symbols: Apple's license doesn't allow them
// in app icons or logos):
//   Resources/AppIcon.icns                      (via iconutil)
//   docs/assets/{favicon-16,favicon-32,apple-touch-icon,icon-512}.png
//   docs/assets/og-image.jpg                    (1200x630 share card; its
//     text in Inter, OFL -- fetched from Google Fonts while this runs, as
//     SF Pro's license doesn't cover graphics like this)
// Run from the repo root at dev time; the results are checked in.
//   swift scripts/generate_artwork.swift [preview.png]
import AppKit

/// Background color pair of the icon's rounded square (top, bottom).
let iconTop = NSColor(calibratedRed: 0.14, green: 0.44, blue: 0.28, alpha: 1)
let iconBottom = NSColor(calibratedRed: 0.05, green: 0.22, blue: 0.15, alpha: 1)
let groove = NSColor(calibratedRed: 0.10, green: 0.33, blue: 0.21, alpha: 1)

/// The brain, seen from above: two hemispheres of rounded lobes, split by
/// a straight gap, with a few grooves -- in the unit square scaled to `r`.
func drawBrain(in r: NSRect, fill: NSColor, grooveColor: NSColor) {
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
    // Lobes of the left hemisphere, mirrored for the right one.
    let lobes: [(CGFloat, CGFloat, CGFloat)] = [
        (0.36, 0.78, 0.13), (0.22, 0.66, 0.14), (0.17, 0.48, 0.14), (0.22, 0.31, 0.14),
        (0.35, 0.20, 0.13), (0.36, 0.40, 0.15), (0.37, 0.60, 0.15),
        // Small inner ones: a smooth edge along the gap where the big
        // lobes would leave notches.
        (0.40, 0.28, 0.10), (0.40, 0.50, 0.10), (0.40, 0.72, 0.10),
    ]
    // Grooves: S-curves from near the gap outward.
    let grooves: [[(CGFloat, CGFloat)]] = [
        [(0.42, 0.80), (0.33, 0.74), (0.30, 0.66), (0.20, 0.62)],
        [(0.43, 0.52), (0.33, 0.55), (0.28, 0.45), (0.16, 0.44)],
        [(0.42, 0.28), (0.34, 0.33), (0.29, 0.25), (0.22, 0.22)],
    ]
    let halfGap: CGFloat = 0.022
    for mirrored in [false, true] {
        func x(_ v: CGFloat) -> CGFloat { mirrored ? 1 - v : v }
        // The hemisphere: its lobes (nonzero winding = their union), cut
        // off along the gap.
        let outline = NSBezierPath()
        outline.windingRule = .nonZero
        for (cx, cy, radius) in lobes {
            let rr = radius * r.width
            let c = p(x(cx), cy)
            outline.append(NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)))
        }
        NSGraphicsContext.saveGraphicsState()
        let half = mirrored
            ? NSRect(x: p(0.5 + halfGap, 0).x, y: r.minY - r.height, width: r.width, height: 3 * r.height)
            : NSRect(x: r.minX - r.width, y: r.minY - r.height, width: p(0.5 - halfGap, 0).x - (r.minX - r.width), height: 3 * r.height)
        NSBezierPath(rect: half).addClip()
        fill.setFill()
        outline.fill()
        outline.addClip()
        grooveColor.setStroke()
        for g in grooves {
            let path = NSBezierPath()
            path.move(to: p(x(g[0].0), g[0].1))
            path.curve(to: p(x(g[3].0), g[3].1), controlPoint1: p(x(g[1].0), g[1].1), controlPoint2: p(x(g[2].0), g[2].1))
            path.lineWidth = r.width * 0.034
            path.lineCapStyle = .round
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

func image(_ size: NSSize, _ draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func icon(_ px: Int) -> NSBitmapImageRep {
    image(NSSize(width: px, height: px)) { rect in
        let s = rect.width
        // macOS icon grid: the rounded square is inset from the canvas.
        let tile = rect.insetBy(dx: s * 0.09, dy: s * 0.09)
        let radius = tile.width * 0.225
        NSGradient(colors: [iconTop, iconBottom])?.draw(in: NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius), angle: -90)
        drawBrain(in: tile.insetBy(dx: tile.width * 0.15, dy: tile.width * 0.15), fill: .white, grooveColor: groove)
    }
}

func write(_ rep: NSBitmapImageRep, _ path: String, _ type: NSBitmapImageRep.FileType = .png) {
    let props: [NSBitmapImageRep.PropertyKey: Any] = type == .jpeg ? [.compressionFactor: 0.9] : [:]
    try! rep.representation(using: type, properties: props)!.write(to: URL(fileURLWithPath: path))
}

if CommandLine.arguments.count > 1 {
    write(icon(1024), CommandLine.arguments[1])
    print("preview written to \(CommandLine.arguments[1])")
    exit(0)
}

let iconset = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    write(icon(size), "\(iconset)/icon_\(size)x\(size).png")
    write(icon(size * 2), "\(iconset)/icon_\(size)x\(size)@2x.png")
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")

write(icon(16), "docs/assets/favicon-16.png")
write(icon(32), "docs/assets/favicon-32.png")
write(icon(180), "docs/assets/apple-touch-icon.png")
write(icon(512), "docs/assets/icon-512.png")

/// Inter at weight 400 / 500 / 700, registered for this process only.
func interFonts() -> [Int: NSFontDescriptor] {
    let css = try! String(contentsOf: URL(string: "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;700")!, encoding: .utf8)
    var fonts: [Int: NSFontDescriptor] = [:]
    for block in css.components(separatedBy: "@font-face").dropFirst() {
        guard let w = block.range(of: #"font-weight: (\d+)"#, options: .regularExpression),
              let u = block.range(of: #"https://[^)]+\.ttf"#, options: .regularExpression),
              let weight = Int(block[w].split(separator: " ").last ?? "") else { continue }
        let file = URL(fileURLWithPath: NSTemporaryDirectory() + "Inter-\(weight).ttf")
        try! Data(contentsOf: URL(string: String(block[u]))!).write(to: file)
        CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        if let d = (CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor])?.first {
            fonts[weight] = d as NSFontDescriptor
        }
    }
    precondition(fonts.count == 3, "couldn't fetch Inter from Google Fonts")
    return fonts
}
let inter = interFonts()
func interFont(_ size: CGFloat, _ weight: Int) -> NSFont { NSFont(descriptor: inter[weight]!, size: size)! }

let og = image(NSSize(width: 1200, height: 630)) { rect in
    NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.28, blue: 0.19, alpha: 1),
        NSColor(calibratedRed: 0.04, green: 0.14, blue: 0.10, alpha: 1),
    ])?.draw(in: rect, angle: -60)
    drawBrain(in: NSRect(x: 90, y: (rect.height - 230) / 2, width: 230, height: 230),
              fill: .white, grooveColor: NSColor(calibratedRed: 0.07, green: 0.23, blue: 0.16, alpha: 1))
    func text(_ s: String, _ font: NSFont, _ color: NSColor, _ at: NSPoint) {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]).draw(at: at)
    }
    text("LLMTray", interFont(84, 700), .white, NSPoint(x: 370, y: 340))
    text("Local LLMs from your macOS menu bar.", interFont(34, 400), NSColor(white: 1, alpha: 0.85), NSPoint(x: 372, y: 270))
    text("Small, fast, no bloat.", interFont(30, 500),
         NSColor(calibratedRed: 0.55, green: 0.9, blue: 0.7, alpha: 1), NSPoint(x: 372, y: 220))
}
write(og, "docs/assets/og-image.jpg", .jpeg)
print("written: Resources/AppIcon.icns, docs/assets/{favicon-16,favicon-32,apple-touch-icon,icon-512}.png, og-image.jpg")
