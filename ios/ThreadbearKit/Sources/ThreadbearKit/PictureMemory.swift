import Foundation
import ImageIO

/// What the phone keeps of pictures between looks, held to a byte budget
/// across all of them. Each picture under PictureLimits could still add up:
/// a thread of a hundred big GIFs kept every file's bytes in its rows (Codex
/// review of Daybreak finding 8). So the decoded, downsampled pictures live
/// here, least recently used out first, and a row only holds its picture
/// while it's on screen.
public final class CostLRU<Key: Hashable & Sendable, Value>: @unchecked Sendable {
    public let limit: Int
    private let lock = NSLock()
    private var entries: [Key: (value: Value, cost: Int, used: UInt64)] = [:]
    private var tick: UInt64 = 0
    public private(set) var totalCost = 0

    public init(limit: Int) { self.limit = limit }

    public func value(for key: Key) -> Value? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            tick += 1
            entry.used = tick
            entries[key] = entry
            return entry.value
        }
    }

    /// Keeps `value`, dropping the least recently used until the total fits.
    /// One costing more than the whole budget isn't kept at all.
    public func set(_ value: Value, for key: Key, cost: Int) {
        lock.withLock {
            if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
            guard cost <= limit else { return }
            tick += 1
            entries[key] = (value, cost, tick)
            totalCost += cost
            while totalCost > limit, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
                entries.removeValue(forKey: oldest.key)
                totalCost -= oldest.value.cost
            }
        }
    }

    public var count: Int { lock.withLock { entries.count } }
}

/// At most `limit` bodies running at once; the rest wait their turn.
public actor ConcurrencyLimit {
    public let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(_ limit: Int) { self.limit = limit }

    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if running >= limit {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            running += 1
        }
        defer {
            // The slot passes straight to the next in line.
            if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
        }
        return try await body()
    }
}

/// How a moving picture plays: its frames' times and loop count, decoded a
/// frame at a time and downsampled to the size it's shown at, never the
/// file's own size (ImageIO's CGAnimateImageDataWithBlock decoded every
/// frame whole). Nil plays only the first frame: too many frames, or too
/// many pixels to decode across them all.
public struct AnimationPlan: Sendable, Equatable {
    public static let maxFrames = 600
    /// Pixels decoded for one pass through every frame at the shown size.
    public static let maxTotalPixels = 400_000_000

    public let delays: [Double]
    /// 0 for for ever.
    public let loopCount: Int
    public let maxSide: Int

    public init?(_ source: CGImageSource, maxSide: Int, maxFrames: Int = Self.maxFrames, maxTotalPixels: Int = Self.maxTotalPixels) {
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= maxFrames, let size = PictureSource.pixelSize(source) else { return nil }
        // The shown size, as ImageIO's thumbnail would make it.
        let scale = min(1, Double(maxSide) / Double(max(size.width, size.height)))
        let shown = (Double(size.width) * scale).rounded(.up) * (Double(size.height) * scale).rounded(.up)
        guard shown * Double(count) <= Double(maxTotalPixels) else { return nil }
        delays = (0..<count).map { Self.delay(source, at: $0) }
        loopCount = Self.loopCount(source)
        self.maxSide = maxSide
    }

    /// Frame `index`, downsampled to `maxSide`.
    public func frame(_ source: CGImageSource, at index: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    static var containers: [(CFString, CFString, CFString)] { [
        (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
        (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
    ] }

    static func delay(_ source: CGImageSource, at index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        for (dict, unclamped, clamped) in containers {
            guard let d = props[dict] as? [CFString: Any] else { continue }
            let value = (d[unclamped] as? NSNumber)?.doubleValue ?? (d[clamped] as? NSNumber)?.doubleValue ?? 0
            // As browsers do: a frame time under 11 ms plays at 100 ms.
            return value < 0.011 ? 0.1 : value
        }
        return 0.1
    }

    static func loopCount(_ source: CGImageSource) -> Int {
        let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let keys: [(CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSLoopCount),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
        ]
        for (dict, key) in keys {
            if let d = props[dict] as? [CFString: Any], let n = (d[key] as? NSNumber)?.intValue { return n }
        }
        return 0
    }
}
