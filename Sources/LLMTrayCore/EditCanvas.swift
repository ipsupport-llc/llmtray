import Foundation

/// The canvas an edited image is generated at: the source image's aspect
/// ratio, about 1024x1024 worth of pixels times the quality scale, each
/// side a multiple of 16 (the model's patch size) within 256...2048.
public enum EditCanvas {
    public static func size(sourceWidth: Int, sourceHeight: Int, scale: Double) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (1024, 1024) }
        let area = 1024.0 * 1024.0 * scale * scale
        let aspect = Double(sourceWidth) / Double(sourceHeight)
        // At most 8:1 either way: a strip image doesn't make a 16 px side.
        let clamped = min(max(aspect, 1.0 / 8), 8)
        var width = (area * clamped).squareRoot(), height = (area / clamped).squareRoot()
        // Scaled as a whole, not per side: clamping one side alone would
        // change the aspect ratio. Up to 8:1 fits 256...2048 both ways.
        let fit = min(2048 / max(width, height), 1) * max(256 / min(width, height), 1)
        width *= fit
        height *= fit
        func side(_ v: Double) -> Int { min(max(Int((v / 16).rounded()) * 16, 256), 2048) }
        return (side(width), side(height))
    }
}
