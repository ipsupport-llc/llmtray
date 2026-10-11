import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decodes an untrusted picture (adr/0020, "Project pictures") -- in the
/// decoder child only (`LLMTray --decode-picture`): never at full size.
/// The header's pixel count first (refused above `maxMegapixels`), frame 0
/// only, then straight to at most `side` pixels, re-encoded without its
/// metadata (no GPS or camera data goes anywhere).
public enum PictureDecoder {
    public struct Decoded: Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// The re-encoded picture: PNG, or JPEG for a photo (no alpha).
        public var data: Data
        public var isJPEG: Bool
        public var thumbnail: Data?
    }

    public enum Failure: Error, Equatable {
        case notAPicture
        case tooManyPixels(Int)
        case cantDecode
    }

    public static func decode(_ url: URL, side: Int, thumbnailSide: Int?, maxMegapixels: Int = ProjectPictures.maxMegapixels) -> Result<Decoded, Failure> {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, noCache),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }), type.conforms(to: .image),
              CGImageSourceGetCount(source) > 0 else { return .failure(.notAPicture) }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else {
            return .failure(.notAPicture)
        }
        let pixels = w.multipliedReportingOverflow(by: h)
        guard !pixels.overflow, pixels.partialValue <= maxMegapixels * 1_000_000 else {
            return .failure(.tooManyPixels(pixels.overflow ? Int.max : pixels.partialValue / 1_000_000))
        }
        guard let image = scaled(source, side: side) else { return .failure(.cantDecode) }
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard let data = encode(image, jpeg: opaque) else { return .failure(.cantDecode) }
        let thumb = thumbnailSide.flatMap { scaled(source, side: $0) }.flatMap { encode($0, jpeg: false) }
        // The size as shown: orientations 5-8 turn it a quarter.
        let turned = ((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
        return .success(Decoded(width: turned ? h : w, height: turned ? w : h, data: data, isJPEG: opaque, thumbnail: thumb))
    }

    static func scaled(_ source: CGImageSource, side: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// No properties are copied: the encoded picture carries no metadata.
    static func encode(_ image: CGImage, jpeg: Bool) -> Data? {
        let out = NSMutableData()
        let type = (jpeg ? UTType.jpeg : UTType.png).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        let options: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.88] : [:]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
