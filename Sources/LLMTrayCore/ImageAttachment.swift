import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A chat attachment as the server takes it: PNG, the long side at most
/// `maxSide` pixels. The server refuses images over 16 MP or 20 MB (a
/// phone photo as PNG is both), and Gemma 4's vision encoder uses about
/// 2.6 MP at its largest budget, so nothing it would see is lost.
public enum ImageAttachment {
    public static let maxSide = 2048

    public static func pngData(_ image: CGImage, maxSide: Int = maxSide) -> Data? {
        let longSide = max(image.width, image.height)
        var output = image
        if longSide > maxSide {
            let scale = Double(maxSide) / Double(longSide)
            let width = max(1, Int((Double(image.width) * scale).rounded()))
            let height = max(1, Int((Double(image.height) * scale).rounded()))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            output = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
