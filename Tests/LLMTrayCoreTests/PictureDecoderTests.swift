import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LLMTrayCore

final class PictureDecoderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// A JPEG with GPS metadata, `w`×`h`.
    private func photo(_ w: Int, _ h: Int, name: String = "p.jpg") throws -> URL {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLongitude: 122.0]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testScalesAndStripsMetadata() throws {
        let url = try photo(3000, 2000)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        XCTAssertNotNil((CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyGPSDictionary], "the fixture has GPS")
        guard case .success(let d) = PictureDecoder.decode(url, side: 2400, thumbnailSide: 400) else { return XCTFail() }
        XCTAssertEqual([d.width, d.height], [3000, 2000], "the original's size")
        XCTAssertTrue(d.isJPEG)
        let out = CGImageSourceCreateWithData(d.data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(out, 0, nil) as? [CFString: Any]
        XCTAssertEqual((props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 2400)
        XCTAssertNil(props?[kCGImagePropertyGPSDictionary], "no GPS in the re-encoded copy")
        XCTAssertNotNil(d.thumbnail)
    }

    func testRefusesNonPicturesAndHugeHeaders() throws {
        let text = dir.appendingPathComponent("fake.png")
        try Data("not an image".utf8).write(to: text)
        XCTAssertEqual(PictureDecoder.decode(text, side: 100, thumbnailSide: nil), .failure(.notAPicture))
        let url = try photo(400, 300)
        if case .failure(.tooManyPixels) = PictureDecoder.decode(url, side: 100, thumbnailSide: nil, maxMegapixels: 0) {} else { XCTFail() }
    }
}
