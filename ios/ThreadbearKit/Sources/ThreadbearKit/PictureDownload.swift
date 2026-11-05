import Foundation
import ImageIO

/// How much of a picture the phone will take. A picture's address can be any
/// https URL an agent wrote in its Markdown, so whoever runs that server picks
/// what comes back: a response with no end, or a small file that says it's
/// 30000 pixels square, would otherwise be read and decoded whole and run the
/// phone out of memory (Daybreak finding 8, Nov 2026).
public enum PictureLimits {
    /// Bytes read for one picture or video. The runner never sends a file
    /// over 10 MB, so this leaves room for pictures from the web.
    public static let maxBytes = 25 * 1024 * 1024
    /// Pixels (width times height) in the picture's header before anything is
    /// decoded: a 48 MP iPhone photo fits, a decompression bomb doesn't.
    public static let maxSourcePixels = 50_000_000
    /// The longest side decoded for full screen, rather than the whole picture.
    public static let maxFullScreenSide = 4096
}

public enum PictureDownloadError: Error, Equatable {
    /// Over `PictureLimits.maxBytes`, by its Content-Length or as it came in.
    case tooLarge
    /// Over `PictureLimits.maxSourcePixels`, by its own header.
    case tooManyPixels
    case badStatus(Int)
}

public enum CappedDownload {
    /// The body of `url`, refused as soon as it's known to be over `limit`
    /// bytes: from a Content-Length over it before any of the body is read,
    /// or once that many bytes have come in, when the transfer is cancelled.
    /// Nothing over the limit is ever held.
    public static func data(from url: URL, session: URLSession, limit: Int = PictureLimits.maxBytes) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        let task = bytes.task
        do {
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw PictureDownloadError.badStatus(http.statusCode)
            }
            // -1 when the server didn't say.
            if response.expectedContentLength > Int64(limit) { throw PictureDownloadError.tooLarge }
            var buffer: [UInt8] = []
            buffer.reserveCapacity(response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 64 * 1024)
            for try await byte in bytes {
                if buffer.count >= limit { throw PictureDownloadError.tooLarge }
                buffer.append(byte)
            }
            return Data(buffer)
        } catch {
            // Stops the transfer now, rather than whenever `bytes` goes away.
            task.cancel()
            throw error
        }
    }
}

public enum PictureSource {
    /// An image source for `data` once its header says it's a size the phone
    /// can decode, or nil when it isn't an image at all (a video). Reading
    /// the size only parses the header; nothing is decoded.
    public static func open(_ data: Data, maxPixels: Int = PictureLimits.maxSourcePixels) throws -> CGImageSource? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        guard let size = pixelSize(source) else { throw PictureDownloadError.tooManyPixels }
        // Doubles, so a header claiming huge sides can't overflow the product.
        guard Double(size.width) * Double(size.height) <= Double(maxPixels) else { throw PictureDownloadError.tooManyPixels }
        return source
    }

    /// The first frame's pixel size from its header, nil if it doesn't say.
    public static func pixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// The first frame, downsampled by ImageIO to `maxSide` on its longest side.
    public static func thumbnail(_ source: CGImageSource, maxSide: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
