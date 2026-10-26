import Foundation

/// Reads an image's pixel size from its file header (PNG, JPEG, GIF, WebP)
/// without decoding it, so rows can be laid out before thumbnails exist.
public enum ImageSize {
    public static func read(path: String) -> (width: Int, height: Int)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // JPEG SOF markers can sit after large EXIF blocks; 256 KB covers nearly all.
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }
        return read(data: data)
    }

    public static func read(data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(256 * 1024))
        guard bytes.count >= 10 else { return nil }
        func be16(_ i: Int) -> Int { Int(bytes[i]) << 8 | Int(bytes[i + 1]) }
        func be32(_ i: Int) -> Int { be16(i) << 16 | be16(i + 2) }
        func le16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func le24(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 }

        // PNG: 8-byte signature, then the IHDR chunk.
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]), bytes.count >= 24 {
            return (be32(16), be32(20))
        }
        // GIF87a / GIF89a: logical screen size, little endian.
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return (le16(6), le16(8))
        }
        // WebP: RIFF....WEBP then VP8 / VP8L / VP8X.
        if bytes.count >= 30, bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            let chunk = String(decoding: bytes[12..<16], as: UTF8.self)
            switch chunk {
            case "VP8 ":
                return (le16(26) & 0x3FFF, le16(28) & 0x3FFF)
            case "VP8L":
                let b0 = Int(bytes[21]), b1 = Int(bytes[22]), b2 = Int(bytes[23]), b3 = Int(bytes[24])
                let width = 1 + (((b1 & 0x3F) << 8) | b0)
                let height = 1 + (((b3 & 0x0F) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6))
                return (width, height)
            case "VP8X":
                return (1 + le24(24), 1 + le24(27))
            default:
                return nil
            }
        }
        // JPEG: walk the segments to the first start-of-frame marker.
        if bytes[0] == 0xFF, bytes[1] == 0xD8 {
            var i = 2
            while i + 9 < bytes.count {
                guard bytes[i] == 0xFF else { i += 1; continue }
                let marker = bytes[i + 1]
                if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) || marker == 0xFF {
                    i += marker == 0xFF ? 1 : 2
                    continue
                }
                let length = be16(i + 2)
                let isSOF = (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
                if isSOF {
                    return (be16(i + 7), be16(i + 5))
                }
                i += 2 + length
            }
        }
        return nil
    }
}
