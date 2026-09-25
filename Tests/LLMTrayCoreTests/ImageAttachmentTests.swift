import CoreGraphics
import ImageIO
import XCTest
@testable import LLMTrayCore

final class ImageAttachmentTests: XCTestCase {
    private func image(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func size(_ png: Data?) -> [Int] {
        let source = CGImageSourceCreateWithData(png! as CFData, nil)!
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        return [image.width, image.height]
    }

    func testLargeImageScaledToLongSide() {
        // A 48 MP phone photo: over the server's 16 MP limit.
        XCTAssertEqual(size(ImageAttachment.pngData(image(8000, 6000))), [2048, 1536])
        XCTAssertEqual(size(ImageAttachment.pngData(image(1000, 5000))), [410, 2048])
    }

    func testSmallImageKeptAsIs() {
        XCTAssertEqual(size(ImageAttachment.pngData(image(2048, 100))), [2048, 100])
        XCTAssertEqual(size(ImageAttachment.pngData(image(1, 1))), [1, 1])
    }
}
