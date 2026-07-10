import XCTest
import AppKit
@testable import Treemux

final class DownsampledImageDecoderTests: XCTestCase {

    private func pngData(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testOversizedImageIsDownsampledToMaxPixelSize() {
        // 5000×100: cheap to allocate, longest edge exceeds the 4096 cap.
        let decoded = DownsampledImageDecoder.decode(pngData(width: 5000, height: 100))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.cgImage.width, DownsampledImageDecoder.maxPixelSize)
        XCTAssertTrue((78...84).contains(decoded!.cgImage.height),
                      "aspect ratio must be preserved (4096/5000 * 100 ≈ 82)")
    }

    func testSmallImageIsNotUpscaled() {
        let decoded = DownsampledImageDecoder.decode(pngData(width: 100, height: 50))
        XCTAssertEqual(decoded?.cgImage.width, 100)
        XCTAssertEqual(decoded?.cgImage.height, 50)
    }

    func testGarbageDataReturnsNil() {
        XCTAssertNil(DownsampledImageDecoder.decode(Data([0x00, 0x01, 0x02, 0x03])))
    }
}
