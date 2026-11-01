import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Gets a photo ready to send: a JPEG no longer than `maxPixels` on its long
/// edge, the right way up. A 12 MP HEIC is far bigger than a model looks at
/// and would be slow on mobile data. Drawing it afresh also leaves its
/// metadata behind, so a photo's location never goes up to Convex.
public enum PhotoPrep {
    public static let maxPixels = 2048
    /// How many photos one message takes (phone.ts, MAX_COMMAND_IMAGES).
    public static let maxPhotos = 6

    /// The long edge of a composer's thumbnail: its 64 pt tile at 3x, for a
    /// 3:2 photo's short side, and plenty for a chip.
    public static let thumbnailPixels = 320

    /// A photo ready to go in a composer. All of it is decoded here, so
    /// this belongs off the main thread and showing the thumbnail costs it
    /// nothing: a composer never touches the 2048 px picture.
    public struct Prepared: Sendable {
        public let jpeg: Data
        public let thumbnail: CGImage
    }

    public static func prepared(from data: Data) -> Prepared? {
        guard let jpeg = jpeg(from: data), let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
            // Decode now rather than on first draw, which is on the main thread.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Prepared(jpeg: jpeg, thumbnail: thumbnail)
    }

    public static func jpeg(from data: Data, maxPixels: Int = maxPixels, quality: Double = 0.85) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // On white, as JPEG has no transparency and a clear PNG would go black.
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flat = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
