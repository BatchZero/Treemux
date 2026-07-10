import Foundation
import ImageIO
import CoreGraphics

/// Decoded bitmap handed across the background-decode boundary. CGImage is
/// immutable and thread-safe; the wrapper documents the transfer.
struct DecodedImage: @unchecked Sendable {
    let cgImage: CGImage
    var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
}

/// Decodes image data via ImageIO with forced downsampling: the produced
/// bitmap is capped at `maxPixelSize` on its longest edge and fully decoded
/// up front (no lazy decode on first draw). Safe on any thread.
enum DownsampledImageDecoder {
    /// Longest-edge cap for preview bitmaps. 4096 px covers a full Retina
    /// screen while bounding worst-case memory (~64 MB BGRA).
    static let maxPixelSize = 4096

    static func decode(_ data: Data) -> DecodedImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return DecodedImage(cgImage: cgImage)
    }
}
