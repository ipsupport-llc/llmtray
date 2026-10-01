import SwiftUI

/// LLMTray's own mark, small: the app icon's brain on its green tile, for
/// the assistant's messages. Drawn, not an SF Symbol (Apple's license keeps
/// those out of logos) and not the .icns (a `swift build` binary has none):
/// the same glyph as scripts/generate_artwork.swift's `drawBrain` -- change
/// both together. The tile reads the same in light and dark.
struct BrainMark: View {
    var size: CGFloat = 14

    private static let tileTop = Color(red: 0.14, green: 0.44, blue: 0.28)
    private static let tileBottom = Color(red: 0.05, green: 0.22, blue: 0.15)
    private static let groove = Color(red: 0.10, green: 0.33, blue: 0.21)

    /// Lobes of the left hemisphere (x, y from the bottom, radius), in the
    /// unit square; mirrored for the right one.
    private static let lobes: [(CGFloat, CGFloat, CGFloat)] = [
        (0.36, 0.78, 0.13), (0.22, 0.66, 0.14), (0.17, 0.48, 0.14), (0.22, 0.31, 0.14),
        (0.35, 0.20, 0.13), (0.36, 0.40, 0.15), (0.37, 0.60, 0.15),
        (0.40, 0.28, 0.10), (0.40, 0.50, 0.10), (0.40, 0.72, 0.10),
    ]
    /// Grooves: S-curves from near the gap outward (start, two controls, end).
    private static let grooves: [[(CGFloat, CGFloat)]] = [
        [(0.42, 0.80), (0.33, 0.74), (0.30, 0.66), (0.20, 0.62)],
        [(0.43, 0.52), (0.33, 0.55), (0.28, 0.45), (0.16, 0.44)],
        [(0.42, 0.28), (0.34, 0.33), (0.29, 0.25), (0.22, 0.22)],
    ]
    private static let halfGap: CGFloat = 0.022

    var body: some View {
        Canvas { context, canvas in
            let tile = CGRect(origin: .zero, size: canvas)
            let radius = tile.width * 0.225
            context.fill(Path(roundedRect: tile, cornerRadius: radius, style: .continuous),
                         with: .linearGradient(Gradient(colors: [Self.tileTop, Self.tileBottom]),
                                               startPoint: CGPoint(x: tile.midX, y: tile.minY), endPoint: CGPoint(x: tile.midX, y: tile.maxY)))
            Self.drawBrain(in: tile.insetBy(dx: tile.width * 0.15, dy: tile.width * 0.15), context: context)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The generator's drawing, in SwiftUI's flipped coordinates (y down).
    private static func drawBrain(in r: CGRect, context: GraphicsContext) {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + (1 - y) * r.height) }
        for mirrored in [false, true] {
            func x(_ v: CGFloat) -> CGFloat { mirrored ? 1 - v : v }
            var outline = Path()
            for (cx, cy, radius) in lobes {
                let rr = radius * r.width
                let c = p(x(cx), cy)
                outline.addEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
            }
            let half = mirrored
                ? CGRect(x: p(0.5 + halfGap, 0).x, y: r.minY - r.height, width: r.width, height: 3 * r.height)
                : CGRect(x: r.minX - r.width, y: r.minY - r.height, width: p(0.5 - halfGap, 0).x - (r.minX - r.width), height: 3 * r.height)
            var ctx = context
            ctx.clip(to: Path(half))
            ctx.fill(outline, with: .color(.white))
            ctx.clip(to: outline)
            for g in grooves {
                var path = Path()
                path.move(to: p(x(g[0].0), g[0].1))
                path.addCurve(to: p(x(g[3].0), g[3].1), control1: p(x(g[1].0), g[1].1), control2: p(x(g[2].0), g[2].1))
                ctx.stroke(path, with: .color(groove), style: StrokeStyle(lineWidth: r.width * 0.034, lineCap: .round))
            }
        }
    }
}
